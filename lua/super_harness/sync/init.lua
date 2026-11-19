local config = require("super_harness.config")
local state = require("super_harness.state")
local log = require("super_harness.utils.log")
local git = require("super_harness.context.git")
local watcher = require("super_harness.sync.watcher")
local reloader = require("super_harness.sync.reloader")

local M = {}

M.live_context_path = vim.fn.stdpath("state") .. "/super_harness/live_context.json"

--- Get active Neovim RPC socket ($NVIM / vim.v.servername)
---@return string
function M.get_socket()
  if vim.v.servername and vim.v.servername ~= "" then
    return vim.v.servername
  end
  return vim.env.NVIM or ""
end

--- Environment variables injected into spawned CLI agents (synergy with harness-use-neovim & MCP)
---@param meta { id: string, adapter: string, cwd: string }
---@return table<string, string>
function M.env_for_session(meta)
  local env = {
    SUPER_HARNESS_ID = tostring(meta.id or ""),
    SUPER_HARNESS_ADAPTER = tostring(meta.adapter or ""),
    SUPER_HARNESS_CWD = tostring(meta.cwd or vim.fn.getcwd()),
    SUPER_HARNESS_CONTEXT_FILE = M.live_context_path,
  }
  if config.options.rpc.inject_nvim_socket then
    local sock = M.get_socket()
    if sock ~= "" then
      env.NVIM = sock
      env.NVIM_LISTEN_ADDRESS = sock
      env.SUPER_HARNESS_SOCKET = sock
    end
  end
  return env
end

--- Find a valid code window (preferring state.last_code_win)
---@return integer|nil
function M.get_code_win()
  if state.last_code_win and vim.api.nvim_win_is_valid(state.last_code_win) then
    if log.is_code_buffer(vim.api.nvim_win_get_buf(state.last_code_win)) then
      return state.last_code_win
    end
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if log.is_code_buffer(vim.api.nvim_win_get_buf(win)) then
      return win
    end
  end
  return nil
end

--- Open a file at line/col inside the user's code window (RPC-safe)
---@param path string
---@param line? integer
---@param col? integer
---@return boolean
function M.open_file(path, line, col)
  if not path or path == "" then
    return false
  end
  local win = M.get_code_win()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  if line and tonumber(line) then
    local target_line = math.max(1, math.min(tonumber(line), vim.api.nvim_buf_line_count(0)))
    local target_col = math.max(0, (tonumber(col) or 1) - 1)
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line, target_col })
  end
  return true
end

--- Build JSON-serializable editor context snapshot for external harnesses/MCP
---@return table
function M.get_context_snapshot()
  local win = M.get_code_win() or vim.api.nvim_get_current_win()
  local buf = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_buf(win) or vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  local root = git.project_root(file ~= "" and file or nil)
  local cursor = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_cursor(win) or { 1, 0 }

  local open_buffers = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted and log.is_code_buffer(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        table.insert(open_buffers, {
          bufnr = b,
          path = name,
          rel_path = git.rel_path(name, root),
          modified = vim.bo[b].modified,
          filetype = vim.bo[b].filetype,
        })
      end
    end
  end

  local diags = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    table.insert(diags, {
      lnum = d.lnum + 1,
      col = d.col + 1,
      severity = d.severity,
      source = d.source or "",
      message = d.message or "",
    })
  end

  return {
    timestamp = os.time(),
    socket = M.get_socket(),
    project_root = root,
    git_branch = git.git_branch(root),
    active_file = file ~= "" and file or nil,
    active_rel_path = file ~= "" and git.rel_path(file, root) or nil,
    filetype = vim.bo[buf].filetype,
    cursor = { line = cursor[1], col = cursor[2] + 1 },
    diagnostics_count = #diags,
    diagnostics = diags,
    open_buffers = open_buffers,
  }
end

function M.write_live_context()
  if not config.options.rpc.enabled or not config.options.rpc.write_live_context then
    return false
  end
  return log.write_json(M.live_context_path, M.get_context_snapshot())
end

function M.flush_modified()
  return reloader.flush_modified()
end

function M.check_and_reload()
  return reloader.check_and_reload()
end

function M.watch_project(dir)
  if not config.options.sync.fs_watch then
    return false
  end
  return watcher.watch(dir or git.project_root(), function()
    reloader.check_and_reload()
  end)
end

function M.teardown()
  watcher.stop_all()
  pcall(vim.api.nvim_del_augroup_by_name, "SuperHarnessSyncShield")
end

--- Setup Buffer Sync Shield autocmds, libuv watcher, and _G.SuperHarnessBridge RPC facade
function M.setup()
  if config.options.sync.silent_autoread then
    vim.o.autoread = true
  end

  _G.SuperHarnessBridge = {
    get_context = M.get_context_snapshot,
    open_file = M.open_file,
    notify = function(msg, level)
      log.notify(msg, level)
      return true
    end,
    reload_buffers = function()
      reloader.check_and_reload()
      return true
    end,
  }

  local group = vim.api.nvim_create_augroup("SuperHarnessSyncShield", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if log.is_code_buffer(vim.api.nvim_win_get_buf(win)) then
        state.last_code_win = win
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "TermLeave" }, {
    group = group,
    callback = function()
      reloader.check_and_reload()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "SuperHarnessIdle",
    callback = function()
      reloader.check_and_reload()
    end,
  })

  if config.options.rpc.enabled and config.options.rpc.write_live_context then
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "CursorHold" }, {
      group = group,
      callback = function()
        if log.is_code_buffer(vim.api.nvim_get_current_buf()) then
          M.write_live_context()
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      watcher.stop_all()
    end,
  })
end

return M
