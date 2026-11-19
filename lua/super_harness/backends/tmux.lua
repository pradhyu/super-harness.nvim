local state = require("super_harness.state")
local log = require("super_harness.utils.log")
local adapters = require("super_harness.adapters")
local sync = require("super_harness.sync")

local M = {}

function M.is_available()
  return vim.fn.executable("tmux") == 1
end

--- Spawn a detached/external agent inside a Tmux window
---@param adapter table
---@param opts table
---@return SuperHarnessSession|nil, string|nil
function M.spawn(adapter, opts)
  if not M.is_available() then
    return nil, "tmux executable not found on $PATH"
  end
  local cwd = opts.cwd or vim.fn.getcwd()
  local id = state.next_id(adapter.name, opts.name)
  local cmd = adapters.build_cmd(adapter, opts)
  local env = sync.env_for_session({ id = id, adapter = adapter.name, cwd = cwd })

  local env_prefix = {}
  for k, v in pairs(env) do
    table.insert(env_prefix, string.format("%s=%s", k, vim.fn.shellescape(v)))
  end
  local shell_cmd = table.concat(env_prefix, " ") .. " " .. table.concat(vim.tbl_map(vim.fn.shellescape, cmd), " ")

  local tmux_cmd
  if vim.env.TMUX and vim.env.TMUX ~= "" then
    tmux_cmd = { "tmux", "new-window", "-P", "-F", "#{pane_id}", "-n", id, "-c", cwd, shell_cmd }
  else
    tmux_cmd = { "tmux", "new-session", "-d", "-P", "-F", "#{pane_id}", "-s", "sh_" .. id:gsub("[^%w_]", "_"), "-c", cwd, shell_cmd }
  end

  local out, code = log.system(tmux_cmd)
  if code ~= 0 then
    return nil, "tmux spawn failed: " .. vim.trim(out)
  end

  local pane_id = vim.trim(out)
  local sess = {
    id = id,
    name = opts.name or id,
    adapter = adapter,
    backend = "tmux",
    external_id = pane_id,
    cwd = cwd,
    layout = "detached",
    state = "idle",
    started_at = os.time(),
    last_activity = os.time(),
    last_prompt = "",
    zoomed = false,
  }
  state.add(sess)
  sync.watch_project(cwd)
  return sess, nil
end

function M.send(sess, text, opts)
  if not sess.external_id then
    return false, "Missing tmux pane_id"
  end
  local _, code = log.system({ "tmux", "send-keys", "-t", sess.external_id, "-l", text })
  if code ~= 0 then
    return false, "tmux send-keys failed"
  end
  if opts == nil or opts.submit ~= false then
    log.system({ "tmux", "send-keys", "-t", sess.external_id, "Enter" })
  end
  sess.last_activity = os.time()
  return true, nil
end

function M.kill(sess)
  if sess.external_id then
    log.system({ "tmux", "kill-pane", "-t", sess.external_id })
  end
  state.remove(sess.id)
end

return M
