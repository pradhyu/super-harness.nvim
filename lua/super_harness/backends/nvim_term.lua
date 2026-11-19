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

--- Open the configured attention UI (native Neovim popup or raw terminal modal)
---@param sess SuperHarnessSession
---@return boolean
function M._open_attention_ui(sess)
  local ncfg = config.options.notifications or {}
  local style = ncfg.attention_style or "neovim"
  if style == "neovim" then
    local ok_ap, approval = pcall(require, "super_harness.ui.approval")
    if ok_ap and approval.open then
      local win = approval.open(sess, { auto = true })
      return win ~= nil and vim.api.nvim_win_is_valid(win)
    end
    return false
  end
  return M.open_session(sess, {
    layout = ncfg.attention_layout or "float",
    temporary_layout = true,
    title_prefix = "▲ Attention — ",
    enter_insert = true,
  })
end

--- Send Neovim + optional clickable OS desktop notification with per-session cooldown,
--- and optionally auto-pop a Neovim-style approval popup (or terminal modal) when the agent needs permission/attention.
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

  local attention_style = ncfg.attention_style or "neovim"

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
        if kind == "attention" and attention_style == "neovim" then
          M._open_attention_ui(sess)
        else
          M.open_session(sess, {
            layout = kind == "attention" and ncfg.attention_layout or nil,
            temporary_layout = kind == "attention" and ncfg.attention_layout ~= nil,
            enter_insert = true,
          })
        end
      end
    end
    log.desktop_notify(title, msg, {
      urgency = urgency,
      on_click = on_click,
      action_label = kind == "attention" and "Approve in Neovim" or "Open in Neovim",
    })
  end

  if kind == "attention" and ncfg.auto_open_on_attention ~= false then
    M._open_attention_ui(sess)
  end

  return true
end

--- Read the last N non-empty rendered lines from a session's terminal buffer.
--- Full-screen TUIs (Ink/React/Bubbletea) use cursor-positioning ANSI escapes that split
--- or concatenate raw on_stdout chunks; inspecting the libvterm-rendered buffer gives clean text.
---@param sess SuperHarnessSession
---@param max_lines? integer
---@return string
function M._get_rendered_tail(sess, max_lines)
  if not sess or not sess.bufnr or not vim.api.nvim_buf_is_valid(sess.bufnr) then
    return ""
  end
  local limit = max_lines or 18
  local total = vim.api.nvim_buf_line_count(sess.bufnr)
  if total <= 0 then
    return ""
  end
  local scan_start = math.max(0, total - math.max(limit * 3, 60))
  local lines = vim.api.nvim_buf_get_lines(sess.bufnr, scan_start, total, false)
  local non_empty = {}
  for i = #lines, 1, -1 do
    local line = vim.trim(lines[i] or "")
    if line ~= "" then
      table.insert(non_empty, 1, line)
      if #non_empty >= limit then
        break
      end
    end
  end
  return table.concat(non_empty, "\n")
end

--- Inspect the rendered terminal tail for interactive prompts/questions that may have been
--- split across raw on_stdout chunks or obscured by cursor-positioning ANSI codes.
---@param sess SuperHarnessSession
---@return string|nil
function M._check_rendered_screen(sess)
  if not sess or sess.state == "exited" or type(sess.adapter.status_detector) ~= "function" then
    return nil
  end
  local tail = M._get_rendered_tail(sess, 18)
  if tail == "" then
    return nil
  end
  local screen_state = sess.adapter.status_detector(tail)
  if screen_state == "awaiting_input" then
    if sess.state ~= "awaiting_input" then
      sess.state = "awaiting_input"
      emit("SuperHarnessState", { id = sess.id, adapter = sess.adapter.name, state = "awaiting_input" })
      local msg = string.format("%s %s is waiting for your attention/input", sess.adapter.icon or "󰚩", sess.id)
      M._notify_session(sess, "attention", "SuperHarness: Attention Needed", msg, vim.log.levels.WARN)
    end
  elseif sess.state == "awaiting_input" then
    -- Interactive prompt is no longer visible at the bottom of the terminal
    sess.state = screen_state or "thinking"
    sess._last_prompt_sig = nil
    local ok_ap, approval = pcall(require, "super_harness.ui.approval")
    if ok_ap and approval.is_open() and approval._sess == sess then
      approval.close()
    end
    emit("SuperHarnessState", { id = sess.id, adapter = sess.adapter.name, state = sess.state })
  else
    sess._last_prompt_sig = nil
  end
  return screen_state
end

local function stop_timer(timer)
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
  end
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

  if trimmed ~= "" and sess._active_turn then
    local ok_tr, transcript = pcall(require, "super_harness.ui.transcript")
    if ok_tr and transcript.append_answer then
      transcript.append_answer(sess, trimmed)
    end
  end

  -- Run adapter status_detector on stripped output chunk (non-attention states only;
  -- interactive attention prompts are detected cleanly from the debounced rendered screen)
  local detected = nil
  if trimmed ~= "" and type(sess.adapter.status_detector) == "function" then
    detected = sess.adapter.status_detector(joined)
    if detected == "awaiting_input" then
      detected = nil
    end
  end

  local next_state = detected or (sess.state == "idle" and "thinking" or sess.state)
  if next_state == "starting" then
    next_state = "thinking"
  end
  if next_state ~= sess.state then
    sess.state = next_state
    emit("SuperHarnessState", { id = sess.id, adapter = sess.adapter.name, state = next_state })
    if next_state == "errored" then
      local msg = string.format("%s %s encountered an error", sess.adapter.icon or "󰚩", sess.id)
      vim.schedule(function()
        M._notify_session(sess, "error", "SuperHarness: Agent Error", msg, vim.log.levels.ERROR)
      end)
    end
  end

  -- Debounced rendered-screen inspection for full-screen TUIs (handles split chunks & cursor-move ANSI)
  stop_timer(sess.screen_check_timer)
  sess.screen_check_timer = nil
  local screen_timer = uv and uv.new_timer and uv.new_timer()
  if screen_timer then
    sess.screen_check_timer = screen_timer
    screen_timer:start(250, 0, vim.schedule_wrap(function()
      stop_timer(screen_timer)
      if sess.screen_check_timer == screen_timer then
        sess.screen_check_timer = nil
      end
      M._check_rendered_screen(sess)
    end))
  end

  -- Debounced transition back to idle
  stop_timer(sess.idle_timer)
  sess.idle_timer = nil
  local threshold = config.options.session.idle_threshold_ms or 2500
  local timer = uv and uv.new_timer and uv.new_timer()
  if timer then
    sess.idle_timer = timer
    timer:start(threshold, 0, vim.schedule_wrap(function()
      stop_timer(timer)
      if sess.idle_timer == timer then
        sess.idle_timer = nil
      end
      if sess.state == "exited" or sess.state == "idle" then
        return
      end
      if sess.state == "awaiting_input" then
        -- Only remain awaiting_input if the rendered bottom viewport still displays a prompt
        local tail = M._get_rendered_tail(sess, 18)
        local still_waiting = tail ~= ""
          and type(sess.adapter.status_detector) == "function"
          and sess.adapter.status_detector(tail) == "awaiting_input"
        if not still_waiting then
          sess.state = "idle"
          emit("SuperHarnessIdle", { id = sess.id, adapter = sess.adapter.name })
        end
        return
      end
      sess.state = "idle"
      local ok_tr, transcript = pcall(require, "super_harness.ui.transcript")
      if ok_tr and transcript.finish_turn then
        transcript.finish_turn(sess)
      end
      emit("SuperHarnessIdle", { id = sess.id, adapter = sess.adapter.name })
      local msg = string.format("%s %s finished its turn", sess.adapter.icon or "󰚩", sess.id)
      M._notify_session(sess, "complete", "SuperHarness: Agent Done", msg, vim.log.levels.INFO)
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
    turns = {},
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
      stop_timer(sess.screen_check_timer)
      sess.screen_check_timer = nil
      stop_timer(sess.idle_timer)
      sess.idle_timer = nil
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
  stop_timer(sess.screen_check_timer)
  sess.screen_check_timer = nil
  stop_timer(sess.idle_timer)
  sess.idle_timer = nil
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
