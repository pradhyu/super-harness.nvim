local config = require("super_harness.config")
local state = require("super_harness.state")
local log = require("super_harness.utils.log")
local adapters = require("super_harness.adapters")
local sanitizer = require("super_harness.context.sanitizer")
local sync = require("super_harness.sync")
local window = require("super_harness.ui.window")

local M = {}

local uv = vim.uv or vim.loop

M._nvim_focused = true

local focus_group = vim.api.nvim_create_augroup("SuperHarnessFocusTrack", { clear = true })
vim.api.nvim_create_autocmd("FocusLost", {
  group = focus_group,
  callback = function()
    M._nvim_focused = false
  end,
})
vim.api.nvim_create_autocmd("FocusGained", {
  group = focus_group,
  callback = function()
    M._nvim_focused = true
  end,
})

local function emit(pattern, data)
  vim.schedule(function()
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data or {} })
  end)
end

--- Determine whether a session is currently "in the background" per notification policy
---@param sess SuperHarnessSession
---@return boolean
function M.is_in_background(sess)
  local ncfg = config.options.notifications or {}
  local when = ncfg.when or "unfocused"
  if when == "always" then
    return true
  end
  if not M._nvim_focused then
    return true
  end
  if not window.is_visible(sess) then
    return true
  end
  if when == "unfocused" then
    local cur_win = vim.api.nvim_get_current_win()
    return cur_win ~= sess.winid
  end
  return false
end

--- Open or focus a PTY session window (optionally as a temporary modal layout)
---@param sess SuperHarnessSession
---@param opts? { layout?: string, temporary_layout?: boolean, title_prefix?: string, enter_insert?: boolean }
---@return boolean
function M.open_session(sess, opts)
  opts = opts or {}
  if not sess or not sess.bufnr or not vim.api.nvim_buf_is_valid(sess.bufnr) then
    return false
  end
  state.set_active(sess.id)

  local cur_win = vim.api.nvim_get_current_win()
  if log.is_code_buffer(vim.api.nvim_win_get_buf(cur_win)) then
    state.last_code_win = cur_win
  end

  if window.is_visible(sess) then
    pcall(vim.api.nvim_set_current_win, sess.winid)
  else
    local target_layout = opts.layout or (sess.layout ~= "background" and sess.layout) or config.options.ui.layout
    if not opts.temporary_layout then
      sess.layout = target_layout
    end
    local prefix = opts.title_prefix or ""
    local title = string.format("%s%s %s (%s)", prefix, sess.adapter.icon or "󰚩", sess.adapter.label, sess.id)
    sess.winid = window.open(sess.bufnr, target_layout, title)
  end

  if sess.winid and vim.api.nvim_win_is_valid(sess.winid) and sess.state ~= "exited" then
    if opts.enter_insert or config.options.ui.auto_insert then
      pcall(vim.cmd, "startinsert")
    end
  end
  return sess.winid ~= nil and vim.api.nvim_win_is_valid(sess.winid)
end

--- Send Neovim + optional clickable OS desktop notification with per-session cooldown,
--- and optionally auto-pop a modal window when the agent needs permission/attention.
---@param sess SuperHarnessSession
---@param kind "complete"|"attention"|"error"
---@param title string
---@param msg string
---@param level integer
function M._notify_session(sess, kind, title, msg, level)
  local ncfg = config.options.notifications or {}
  if not ncfg.enabled then
    return false
  end
  if kind == "complete" and ncfg.notify_on_complete == false then
    return false
  end
  if kind == "attention" and ncfg.notify_on_attention == false then
    return false
  end
  if not M.is_in_background(sess) then
    return false
  end

  local now_ms = (uv and uv.now and uv.now()) or (os.time() * 1000)
  local cooldown = ncfg.cooldown_ms or 3000
  sess._last_notify = sess._last_notify or {}
  if sess._last_notify[kind] and (now_ms - sess._last_notify[kind]) < cooldown then
    return false
  end
  sess._last_notify[kind] = now_ms

  log.notify(msg, level)

  if ncfg.desktop ~= false then
    local urgency = (kind == "attention" or kind == "error") and "critical" or "normal"
    local on_click = nil
    if ncfg.click_action ~= false then
      on_click = function()
        if ncfg.focus_terminal_on_click ~= false then
          log.focus_host_window()
        end
        M.open_session(sess, {
          layout = kind == "attention" and ncfg.attention_layout or nil,
          temporary_layout = kind == "attention" and ncfg.attention_layout ~= nil,
          enter_insert = true,
        })
      end
    end
    log.desktop_notify(title, msg, {
      urgency = urgency,
      on_click = on_click,
      action_label = kind == "attention" and "Approve in Neovim" or "Open in Neovim",
    })
  end

  if kind == "attention" and ncfg.auto_open_on_attention ~= false then
    M.open_session(sess, {
      layout = ncfg.attention_layout or "float",
      temporary_layout = true,
      title_prefix = "▲ Permission — ",
      enter_insert = true,
    })
  end

  return true
end

local function update_activity(sess, raw_lines)
  if sess.state == "exited" then
    return
  end

  local joined = ""
  if raw_lines and #raw_lines > 0 then
    joined = sanitizer.strip_ansi(table.concat(raw_lines, "\n"))
  end
  local trimmed = vim.trim(joined)

  -- Ignore pure ANSI/whitespace redraws while already idle to prevent false completion notifications
  if trimmed == "" and sess.state == "idle" then
    return
  end

  sess.last_activity = os.time()

  -- Run adapter status_detector on stripped output chunk
  local detected = nil
  if trimmed ~= "" and type(sess.adapter.status_detector) == "function" then
    detected = sess.adapter.status_detector(joined)
  end

  local next_state = detected or (sess.state == "idle" and "thinking" or sess.state)
  if next_state == "starting" then
    next_state = "thinking"
  end
  if next_state ~= sess.state then
    sess.state = next_state
    emit("SuperHarnessState", { id = sess.id, adapter = sess.adapter.name, state = next_state })
    if next_state == "awaiting_input" then
      local msg = string.format("%s %s is waiting for your attention/approval", sess.adapter.icon or "󰚩", sess.id)
      vim.schedule(function()
        M._notify_session(sess, "attention", "SuperHarness: Attention Needed", msg, vim.log.levels.WARN)
      end)
    elseif next_state == "errored" then
      local msg = string.format("%s %s encountered an error", sess.adapter.icon or "󰚩", sess.id)
      vim.schedule(function()
        M._notify_session(sess, "error", "SuperHarness: Agent Error", msg, vim.log.levels.ERROR)
      end)
    end
  end

  -- Debounced transition back to idle
  if sess.idle_timer then
    pcall(function()
      sess.idle_timer:stop()
      sess.idle_timer:close()
    end)
    sess.idle_timer = nil
  end
  local threshold = config.options.session.idle_threshold_ms or 2500
  local timer = uv and uv.new_timer and uv.new_timer()
  if timer then
    sess.idle_timer = timer
    timer:start(threshold, 0, vim.schedule_wrap(function()
      pcall(function()
        timer:stop()
        timer:close()
      end)
      sess.idle_timer = nil
      if sess.state ~= "exited" and sess.state ~= "awaiting_input" and sess.state ~= "idle" then
        sess.state = "idle"
        emit("SuperHarnessIdle", { id = sess.id, adapter = sess.adapter.name })
        local msg = string.format("%s %s finished its turn", sess.adapter.icon or "󰚩", sess.id)
        M._notify_session(sess, "complete", "SuperHarness: Agent Done", msg, vim.log.levels.INFO)
      end
    end))
  end
end

--- Spawn a Neovim built-in PTY session
---@param adapter table
---@param opts table
---@return SuperHarnessSession|nil, string|nil
function M.spawn(adapter, opts)
  local cwd = opts.cwd or vim.fn.getcwd()
  local id = state.next_id(adapter.name, opts.name)
  local layout = opts.layout or config.options.ui.layout or "drawer"

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.b[bufnr].super_harness_buf = true
  vim.b[bufnr].super_harness_id = id

  local title = string.format("%s %s (%s)", adapter.icon or "󰚩", adapter.label, id)
  local winid = window.open(bufnr, layout, title)

  local cmd = adapters.build_cmd(adapter, opts)
  local env = vim.tbl_extend("force", adapter.env or {}, sync.env_for_session({
    id = id,
    adapter = adapter.name,
    cwd = cwd,
  }))

  local sess = {
    id = id,
    name = opts.name or id,
    adapter = adapter,
    backend = "nvim_term",
    bufnr = bufnr,
    winid = winid,
    job_id = nil,
    cwd = cwd,
    layout = layout,
    state = "starting",
    started_at = os.time(),
    last_activity = os.time(),
    last_prompt = "",
    zoomed = false,
  }

  local job_opts = {
    cwd = cwd,
    env = env,
    on_stdout = function(_, data)
      update_activity(sess, data)
    end,
    on_exit = function(_, code)
      sess.state = "exited"
      if sess.idle_timer then
        pcall(function()
          sess.idle_timer:stop()
          sess.idle_timer:close()
        end)
        sess.idle_timer = nil
      end
      emit("SuperHarnessExited", { id = sess.id, adapter = sess.adapter.name, code = code })
      if adapter.exit_action == "close" then
        vim.schedule(function()
          window.hide(sess)
        end)
      end
    end,
  }

  local job_id
  local function start_term()
    if vim.fn.has("nvim-0.11") == 1 then
      job_opts.term = true
      return vim.fn.jobstart(cmd, job_opts)
    end
    return vim.fn.termopen(cmd, job_opts)
  end

  if winid then
    job_id = start_term()
  else
    -- Background headless PTY: call inside buffer context
    job_id = vim.api.nvim_buf_call(bufnr, start_term)
  end

  if not job_id or job_id <= 0 then
    if winid and vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return nil, "Failed to start PTY command: " .. table.concat(cmd, " ")
  end

  sess.job_id = job_id
  sess.state = "idle"
  state.add(sess)
  window.attach_term_keymaps(sess)
  sync.watch_project(cwd)
  emit("SuperHarnessStarted", { id = id, adapter = adapter.name, cwd = cwd })

  if winid and config.options.ui.auto_insert then
    vim.cmd("startinsert")
  end
  return sess, nil
end

--- Send encoded text to a Neovim PTY session
---@param sess SuperHarnessSession
---@param text string
---@param opts? { submit?: boolean }
---@return boolean, string|nil
function M.send(sess, text, opts)
  local encoded = sanitizer.encode_input(sess.adapter, text, opts)
  local ok, err = pcall(vim.api.nvim_chan_send, sess.job_id, encoded.payload)
  if not ok then
    return false, tostring(err)
  end
  if encoded.submit_seq then
    local delay = encoded.submit_delay_ms or 50
    if delay > 0 then
      vim.defer_fn(function()
        if sess.job_id and sess.state ~= "exited" then
          pcall(vim.api.nvim_chan_send, sess.job_id, encoded.submit_seq)
        end
      end, delay)
    else
      pcall(vim.api.nvim_chan_send, sess.job_id, encoded.submit_seq)
    end
  end
  update_activity(sess, nil)
  return true, nil
end

--- Kill a Neovim PTY session cleanly
---@param sess SuperHarnessSession
function M.kill(sess)
  if sess.idle_timer then
    pcall(function()
      sess.idle_timer:stop()
      sess.idle_timer:close()
    end)
    sess.idle_timer = nil
  end
  if sess.job_id and sess.state ~= "exited" then
    pcall(vim.fn.jobstop, sess.job_id)
  end
  window.hide(sess)
  if sess.bufnr and vim.api.nvim_buf_is_valid(sess.bufnr) then
    pcall(vim.api.nvim_buf_delete, sess.bufnr, { force = true })
  end
  state.remove(sess.id)
end

return M
