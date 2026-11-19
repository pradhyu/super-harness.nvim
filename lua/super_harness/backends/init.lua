local config = require("super_harness.config")
local state = require("super_harness.state")
local log = require("super_harness.utils.log")
local adapters = require("super_harness.adapters")
local git = require("super_harness.context.git")
local context = require("super_harness.context")
local sync = require("super_harness.sync")
local review = require("super_harness.review")
local window = require("super_harness.ui.window")

local nvim_term = require("super_harness.backends.nvim_term")
local tmux = require("super_harness.backends.tmux")
local zellij = require("super_harness.backends.zellij")

local M = {}

local BACKENDS = {
  nvim_term = nvim_term,
  tmux = tmux,
  zellij = zellij,
}

local function get_backend(name)
  return BACKENDS[name or config.options.backend or "nvim_term"] or nvim_term
end

--- Spawn a new agent session
---@param adapter_name? string
---@param opts? table
---@return SuperHarnessSession|nil, string|nil
function M.spawn(adapter_name, opts)
  opts = opts or {}
  local adapter = adapter_name and adapters.get(adapter_name, true) or adapters.resolve_default()
  if not adapter then
    return nil, "No agent adapter resolved"
  end
  if not adapters.is_installed(adapter) then
    local err = string.format("Agent binary '%s' (%s) is not installed on $PATH", adapter.bin, adapter.label)
    log.error(err)
    return nil, err
  end

  -- Track current code window before opening harness
  local cur_win = vim.api.nvim_get_current_win()
  if log.is_code_buffer(vim.api.nvim_win_get_buf(cur_win)) then
    state.last_code_win = cur_win
  end

  local cwd = opts.cwd
  if not cwd or cwd == "" then
    cwd = config.options.session.start_in_project_root and git.project_root() or vim.fn.getcwd()
  end
  opts.cwd = cwd

  local backend_name = opts.backend or (opts.layout == "detached" and "tmux" or config.options.backend)
  local backend = get_backend(backend_name)
  return backend.spawn(adapter, opts)
end

--- Show an existing session
---@param id? string
---@param layout? string
---@return boolean
function M.show(id, layout)
  local sess = id and state.get(id) or state.get_active()
  if not sess then
    return false
  end
  state.set_active(sess.id)
  if sess.backend ~= "nvim_term" or not sess.bufnr or not vim.api.nvim_buf_is_valid(sess.bufnr) then
    return true
  end

  local cur_win = vim.api.nvim_get_current_win()
  if log.is_code_buffer(vim.api.nvim_win_get_buf(cur_win)) then
    state.last_code_win = cur_win
  end

  if window.is_visible(sess) then
    vim.api.nvim_set_current_win(sess.winid)
  else
    local target_layout = layout or (sess.layout ~= "background" and sess.layout) or config.options.ui.layout
    sess.layout = target_layout
    local title = string.format("%s %s (%s)", sess.adapter.icon or "󰚩", sess.adapter.label, sess.id)
    sess.winid = window.open(sess.bufnr, target_layout, title)
  end

  if config.options.ui.auto_insert and sess.state ~= "exited" then
    vim.cmd("startinsert")
  end
  return true
end

function M.hide(id)
  local sess = id and state.get(id) or state.get_active()
  return window.hide(sess)
end

function M.zoom(id)
  local sess = id and state.get(id) or state.get_active()
  if not sess then
    return false
  end
  if not window.is_visible(sess) then
    M.show(sess.id)
  end
  return window.zoom(sess)
end

--- Toggle active session (or a specific adapter / layout)
---@param adapter_name? string
---@param opts? table
---@return SuperHarnessSession|nil
function M.toggle(adapter_name, opts)
  opts = opts or {}
  if adapter_name and adapter_name ~= "" then
    local resolved = adapters.get(adapter_name, true)
    local target_name = resolved and resolved.name or adapter_name
    for i = #state.order, 1, -1 do
      local s = state.get(state.order[i])
      if s and s.adapter.name == target_name and s.state ~= "exited" then
        if window.is_visible(s) then
          M.hide(s.id)
        else
          M.show(s.id, opts.layout)
        end
        return s
      end
    end
    local s = M.spawn(adapter_name, opts)
    return s
  end

  local active = state.get_active()
  if active and active.state ~= "exited" then
    if window.is_visible(active) then
      if opts.layout and opts.layout ~= active.layout then
        M.hide(active.id)
        M.show(active.id, opts.layout)
      else
        M.hide(active.id)
      end
    else
      M.show(active.id, opts.layout)
    end
    return active
  end

  local s = M.spawn(nil, opts)
  return s
end

--- Send prompt / context items to active or target session (with pre-prompt flush & baseline)
---@param text? string
---@param opts? { id?: string, context_items?: table[], submit?: boolean, focus?: boolean, record_history?: boolean }
---@return boolean, string|nil
function M.send(text, opts)
  opts = opts or {}
  local sess = opts.id and state.get(opts.id) or state.get_active()
  if not sess or sess.state == "exited" then
    local err
    sess, err = M.spawn()
    if not sess then
      return false, err or "No active session"
    end
  end

  local final_text = text or ""
  if opts.context_items and #opts.context_items > 0 then
    final_text = adapters.format_payload(sess.adapter, text, opts.context_items)
  end
  if vim.trim(final_text) == "" then
    return false, "Empty payload"
  end

  -- Buffer Sync Shield: pre-prompt auto-flush & review baseline
  sync.flush_modified()
  review.mark_baseline(sess.cwd)

  local backend = get_backend(sess.backend)
  local ok, err = backend.send(sess, final_text, { submit = opts.submit })
  if not ok then
    return false, err
  end

  sess.last_prompt = log.truncate(final_text:gsub("\n", " "), 120)
  local ok_tr, transcript = pcall(require, "super_harness.ui.transcript")
  if ok_tr and transcript.record_question then
    transcript.record_question(sess, final_text)
  end
  if opts.record_history ~= false then
    context.record_history(final_text, sess.adapter.name)
  end

  if opts.focus then
    M.show(sess.id)
  end
  return true, nil
end

--- Broadcast prompt to multiple live sessions (Arena / Swarm Mode)
---@param text string
---@param session_ids? string[]
---@param opts? table
---@return integer sent_count
function M.broadcast(text, session_ids, opts)
  opts = opts or {}
  local targets = {}
  if session_ids and #session_ids > 0 then
    for _, id in ipairs(session_ids) do
      local s = state.get(id)
      if s and s.state ~= "exited" then
        table.insert(targets, id)
      end
    end
  else
    for _, s in ipairs(state.list()) do
      if s.state ~= "exited" then
        table.insert(targets, s.id)
      end
    end
  end

  local count = 0
  for i, id in ipairs(targets) do
    local ok = M.send(text, {
      id = id,
      context_items = opts.context_items,
      submit = opts.submit,
      focus = false,
      record_history = (i == 1),
    })
    if ok then
      count = count + 1
    end
  end
  return count
end

function M.kill(id)
  local sess = id and state.get(id) or state.get_active()
  if not sess then
    return false
  end
  get_backend(sess.backend).kill(sess)
  return true
end

function M.kill_all()
  for _, id in ipairs(vim.deepcopy(state.order)) do
    M.kill(id)
  end
end

return M
