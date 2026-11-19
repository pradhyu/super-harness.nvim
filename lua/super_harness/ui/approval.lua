local config = require("super_harness.config")
local state = require("super_harness.state")
local log = require("super_harness.utils.log")

local M = {}

M._buf = nil
M._win = nil
M._sess = nil
M._prompt = nil
M._cursor = 1
M._checked = {}
M._option_lines = {} -- option index -> 1-based buffer line
M._line_to_option = {} -- 1-based buffer line -> option index
M._ns = vim.api.nvim_create_namespace("super_harness_approval")

local function setup_highlights()
  vim.api.nvim_set_hl(0, "SuperHarnessApprovalTitle", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "SuperHarnessApprovalBadge", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "SuperHarnessApprovalQuestion", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "SuperHarnessApprovalSelected", { link = "PmenuSel", default = true })
  vim.api.nvim_set_hl(0, "SuperHarnessApprovalChecked", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "SuperHarnessApprovalRec", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "SuperHarnessApprovalHint", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "SuperHarnessApprovalSep", { link = "FloatBorder", default = true })
end

local BORDER_PREFIXES = { "│", "┃", "║", "▏", "▕" }
local BORDER_CHARS = {
  "┌", "┐", "└", "┘", "╭", "╮", "╰", "╯",
  "├", "┤", "┬", "┴", "┼", "─", "━", "═",
  "│", "┃", "║", "╌", "╍", "┄", "┅", "┈", "┉",
  "▏", "▕", "-", "_", "=",
}

--- Strip box-drawing borders from a rendered TUI line (UTF-8 safe for LuaJIT)
---@param line string
---@return string
local function clean_tui_line(line)
  local s = vim.trim(tostring(line or ""))
  local changed = true
  while changed and s ~= "" do
    changed = false
    for _, ch in ipairs(BORDER_PREFIXES) do
      if s:sub(1, #ch) == ch then
        s = vim.trim(s:sub(#ch + 1))
        changed = true
      end
      if #s >= #ch and s:sub(-#ch) == ch then
        s = vim.trim(s:sub(1, #s - #ch))
        changed = true
      end
    end
  end
  return s
end

--- Check if a line is purely box-drawing border or divider characters (UTF-8 safe for LuaJIT)
---@param line string
---@return boolean
local function is_border_only(line)
  local s = vim.trim(tostring(line or ""))
  if s == "" then
    return true
  end
  for _, ch in ipairs(BORDER_CHARS) do
    s = s:gsub(vim.pesc(ch), "")
  end
  return vim.trim(s) == ""
end

--- Check if a line is a TUI navigation/footer hint rather than a question or option
---@param lower string
---@return boolean
local function is_hint_line(lower)
  return lower:find("enter to select", 1, true) ~= nil
    or lower:find("enter to submit", 1, true) ~= nil
    or lower:find("enter to confirm", 1, true) ~= nil
    or lower:find("enter to continue", 1, true) ~= nil
    or lower:find("space to toggle", 1, true) ~= nil
    or lower:find("space to select", 1, true) ~= nil
    or lower:find("esc to cancel", 1, true) ~= nil
    or lower:find("esc to dismiss", 1, true) ~= nil
    or lower:find("esc to skip", 1, true) ~= nil
    or lower:find("↑/↓", 1, true) ~= nil
    or lower:find("select all that apply", 1, true) ~= nil
    or lower:find("select an option", 1, true) ~= nil
    or lower:find("choose an option", 1, true) ~= nil
    or (
      (lower:find("↑", 1, true) or lower:find("↓", 1, true) or lower:find("j/k", 1, true))
      and (lower:find("navigate", 1, true) or lower:find("select", 1, true) or lower:find("cancel", 1, true) or lower:find("submit", 1, true))
    )
end

--- Try to parse a single line as an interactive option row
---@param line string
---@return table|nil
local function parse_option_line(line)
  local s = line
  local is_selected = false
  local has_checkbox = false
  local checked = false
  local num = nil

  -- Leading cursor indicator: ❯, >, ▶, ▸, ●
  local after_cursor = s:match("^❯%s*(.+)$")
    or s:match("^▶%s*(.+)$")
    or s:match("^▸%s*(.+)$")
    or s:match("^>%s+(.+)$")
  if after_cursor then
    is_selected = true
    s = vim.trim(after_cursor)
  end

  -- Checkbox indicator: [ ], [x], [X], [✓], [✔], ☐, ☑, ◉, ◯ (UTF-8 safe)
  local box, after_box = s:match("^%[([^%]]*)%]%s+(.+)$")
  if box ~= nil and after_box and #box <= 4 then
    local b = vim.trim(box)
    if b == "" or b == "x" or b == "X" or b == "*" or b == "✓" or b == "✔" then
      has_checkbox = true
      checked = b ~= ""
      s = vim.trim(after_box)
    end
  else
    local ubox_rest = s:match("^☐%s*(.+)$") or s:match("^◯%s*(.+)$")
    if ubox_rest then
      has_checkbox = true
      checked = false
      s = vim.trim(ubox_rest)
    else
      local uchk_rest = s:match("^☑%s*(.+)$") or s:match("^◉%s*(.+)$") or s:match("^✓%s*(.+)$") or s:match("^✔%s*(.+)$")
      if uchk_rest then
        has_checkbox = true
        checked = true
        s = vim.trim(uchk_rest)
      end
    end
  end

  -- Numbered option: 1. Label, 1) Label, (1) Label
  local n_str, after_num = s:match("^(%d+)[%.%)]%s+(.+)$")
  if n_str and after_num then
    num = tonumber(n_str)
    s = vim.trim(after_num)
  end

  -- Checkbox AFTER number (e.g. "1. [ ] Option A")
  if not has_checkbox then
    local box2, after_box2 = s:match("^%[([^%]]*)%]%s+(.+)$")
    if box2 ~= nil and after_box2 and #box2 <= 4 then
      local b2 = vim.trim(box2)
      if b2 == "" or b2 == "x" or b2 == "X" or b2 == "*" or b2 == "✓" or b2 == "✔" then
        has_checkbox = true
        checked = b2 ~= ""
        s = vim.trim(after_box2)
      end
    end
  end

  if s == "" then
    return nil
  end

  if not num and not has_checkbox and not is_selected then
    return nil
  end

  local lower = s:lower()
  local is_other = lower:match("^other") ~= nil
    or lower:find("type your own", 1, true) ~= nil
    or lower:find("type your answer", 1, true) ~= nil
    or lower:find("type something", 1, true) ~= nil
    or lower:find("custom answer", 1, true) ~= nil

  return {
    label = s,
    num = num,
    selected = is_selected,
    has_checkbox = has_checkbox,
    checked = checked,
    is_other = is_other,
    is_recommended = lower:find("(recommended)", 1, true) ~= nil,
  }
end

--- Build a plain unnumbered option table from a line (used for cursor-based menus like `❯ Allow once` / `Deny`)
---@param line string
---@return table
local function make_plain_option(line)
  local lower = line:lower()
  local is_other = lower:match("^other") ~= nil
    or lower:find("type your own", 1, true) ~= nil
    or lower:find("type your answer", 1, true) ~= nil
    or lower:find("type something", 1, true) ~= nil
    or lower:find("custom answer", 1, true) ~= nil
  return {
    label = line,
    num = nil,
    selected = false,
    has_checkbox = false,
    checked = false,
    is_other = is_other,
    is_recommended = lower:find("(recommended)", 1, true) ~= nil,
  }
end

--- Compute a stable fingerprint for a parsed prompt to prevent re-opening on the same screen
---@param prompt table
---@return string
local function prompt_signature(prompt)
  local parts = { prompt.kind or "", prompt.progress or "", prompt.question or "" }
  for _, opt in ipairs(prompt.options or {}) do
    table.insert(parts, opt.label or "")
  end
  return table.concat(parts, "\0")
end

--- Parse rendered terminal text into a structured Neovim popup prompt
---@param text string
---@return table prompt
function M.parse_prompt(text)
  local raw_lines = vim.split(tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n"), "\n", { plain = true })
  local cleaned = {}
  for _, l in ipairs(raw_lines) do
    if not is_border_only(l) then
      local c = clean_tui_line(l)
      if c ~= "" then
        table.insert(cleaned, c)
      end
    end
  end

  local progress = nil
  local multi_hint = false
  local has_nav_hint = false
  local hints = {}
  local is_hint = {}

  for idx, line in ipairs(cleaned) do
    local lower = line:lower()
    local q_cur, q_tot = lower:match("question%s+(%d+)%s*/%s*(%d+)")
    if not q_cur then
      q_cur, q_tot = lower:match("question%s+(%d+)%s+of%s+(%d+)")
    end
    if q_cur and q_tot then
      progress = q_cur .. "/" .. q_tot
    end

    if lower:find("space to toggle", 1, true)
      or lower:find("space to select", 1, true)
      or lower:find("select all that apply", 1, true)
    then
      multi_hint = true
    end

    if is_hint_line(lower) then
      is_hint[idx] = true
      table.insert(hints, line)
      if lower:find("enter to select", 1, true)
        or lower:find("enter to submit", 1, true)
        or lower:find("enter to confirm", 1, true)
        or lower:find("enter to continue", 1, true)
        or lower:find("space to toggle", 1, true)
        or lower:find("space to select", 1, true)
        or lower:find("esc to cancel", 1, true)
        or lower:find("esc to dismiss", 1, true)
        or lower:find("↑/↓", 1, true)
        or ((lower:find("↑", 1, true) or lower:find("↓", 1, true) or lower:find("j/k", 1, true))
          and (lower:find("navigate", 1, true) or lower:find("select", 1, true) or lower:find("submit", 1, true) or lower:find("cancel", 1, true)))
      then
        has_nav_hint = true
      end
    end
  end

  -- Anchor search to the bottom-most interactive block so earlier scrollback lists are never mixed in.
  local bottom_limit = #cleaned
  while bottom_limit >= 1 and is_hint[bottom_limit] do
    bottom_limit = bottom_limit - 1
  end

  -- First pass: collect contiguous structured option rows (cursor / checkbox / numbered) from bottom_limit upwards
  local options = {}
  local first_opt_idx = nil
  local i = bottom_limit
  while i >= 1 do
    if is_hint[i] then
      break
    end
    local opt = parse_option_line(cleaned[i])
    if opt then
      table.insert(options, 1, opt)
      first_opt_idx = i
      i = i - 1
    else
      break
    end
  end

  -- Second pass: handle unnumbered cursor-based menus (e.g. `❯ Allow once` / `Always allow ...` / `Deny`)
  -- where only the active row has `❯`/`▶`/`▸` and unselected rows below it are plain text above the nav hint.
  if #options < 2 and has_nav_hint and bottom_limit >= 2 then
    local cursor_idx = nil
    local search_top = math.max(1, bottom_limit - 8)
    for k = bottom_limit, search_top, -1 do
      if not is_hint[k] then
        local opt = parse_option_line(cleaned[k])
        if opt and opt.selected then
          cursor_idx = k
          break
        end
      end
    end
    if cursor_idx then
      local menu_opts = {}
      local menu_top = cursor_idx
      -- Include unselected short option rows above cursor_idx only if they look like sibling choices (not a question ending in `?` or `:`)
      local k = cursor_idx - 1
      while k >= search_top and not is_hint[k] do
        local line = cleaned[k]
        local ends_q = line:sub(-1) == "?" or line:sub(-1) == ":"
        local is_prog = line:lower():match("^question%s+%d+") ~= nil
        if ends_q or is_prog or #line > 72 then
          break
        end
        local parsed_k = parse_option_line(line)
        table.insert(menu_opts, 1, parsed_k or make_plain_option(line))
        menu_top = k
        k = k - 1
      end
      -- Add the cursor row itself and all non-hint rows down to bottom_limit
      for m = cursor_idx, bottom_limit do
        if not is_hint[m] then
          local parsed_m = parse_option_line(cleaned[m])
          table.insert(menu_opts, parsed_m or make_plain_option(cleaned[m]))
        end
      end
      if #menu_opts >= 2 then
        options = menu_opts
        first_opt_idx = menu_top
      end
    end
  end

  local initial_idx = 1
  local any_checkbox = false
  local any_selected = false
  for idx, opt in ipairs(options) do
    if opt.selected then
      initial_idx = idx
      any_selected = true
    end
    if opt.has_checkbox then
      any_checkbox = true
    end
  end

  -- Plain numbered lists in prose (no cursor, no checkboxes, no nav hint) are NOT interactive menus
  if #options >= 2 and not any_selected and not any_checkbox and not has_nav_hint then
    options = {}
    first_opt_idx = nil
  end

  -- Collect up to 4 question lines immediately above the option block (or at the bottom for confirm prompts)
  local question_lines = {}
  local q_end = first_opt_idx and (first_opt_idx - 1) or bottom_limit
  for k = math.max(1, q_end - 6), q_end do
    local line = cleaned[k]
    if line and not is_hint[k] then
      local lower = line:lower()
      if not lower:match("^question%s+%d+") then
        table.insert(question_lines, line)
      end
    end
  end
  if #question_lines > 4 then
    local trimmed_q = {}
    for k = #question_lines - 3, #question_lines do
      table.insert(trimmed_q, question_lines[k])
    end
    question_lines = trimmed_q
  end

  local full_lower = tostring(text or ""):lower()
  local has_yn = full_lower:find("%[y/n%]") ~= nil
    or full_lower:find("%(y/n%)") ~= nil
    or full_lower:find("yes/no", 1, true) ~= nil
  local has_press_enter = full_lower:find("press enter", 1, true) ~= nil
    or full_lower:find("press any key", 1, true) ~= nil

  local kind
  local is_interactive = false
  if #options >= 2 then
    kind = (any_checkbox or multi_hint) and "multi_select" or "select"
    is_interactive = true
  else
    -- Synthesize clean Neovim options for yes/no / press-enter prompts
    options = {}
    initial_idx = 1
    if has_press_enter and not has_yn then
      kind = "confirm"
      is_interactive = true
      options = {
        { label = "Continue (Enter)", send = "\r", is_recommended = true },
        { label = "Cancel (Esc)", send = "\27" },
      }
    else
      kind = "confirm"
      is_interactive = has_yn
      options = {
        { label = "Approve / Yes", send = "y\r", is_recommended = true },
        { label = "Deny / No", send = "n\r" },
      }
    end
  end

  local question = table.concat(question_lines, "\n")
  if question == "" then
    question = "Agent is waiting for your input:"
  end

  local prompt = {
    kind = kind,
    is_interactive = is_interactive,
    question = question,
    progress = progress,
    options = options,
    initial_idx = initial_idx,
    hints = hints,
    raw = text or "",
  }
  prompt.sig = prompt_signature(prompt)
  return prompt
end

--- Build the PTY keystroke sequence for a user action in the Neovim popup
---@param prompt table
---@param action table { type = "select"|"multi_select"|"confirm"|"custom"|"cancel", idx?: integer, checked?: table<integer, boolean>, text?: string, send?: string }
---@return table[] steps { { seq = string, delay_ms = integer }, ... }
function M.build_keystrokes(prompt, action)
  local steps = {}
  local function push(seq, delay_ms)
    table.insert(steps, { seq = seq, delay_ms = delay_ms or 0 })
  end

  local function move(from_idx, to_idx)
    local delta = to_idx - from_idx
    local key = delta > 0 and "\27[B" or "\27[A"
    for _ = 1, math.abs(delta) do
      push(key, 25)
    end
  end

  if action.type == "cancel" then
    push("\27", 0)
    return steps
  end

  if action.type == "confirm" then
    push(action.send or "y\r", 0)
    return steps
  end

  if action.type == "select" then
    local target = action.idx or 1
    local opt = prompt.options[target]
    if opt and opt.send then
      push(opt.send, 0)
      return steps
    end
    move(prompt.initial_idx or 1, target)
    push("\r", 35)
    return steps
  end

  if action.type == "multi_select" then
    local cur = prompt.initial_idx or 1
    local desired = action.checked or {}
    for i, opt in ipairs(prompt.options) do
      local was = opt.checked == true
      local want = desired[i] == true
      if was ~= want then
        move(cur, i)
        push(" ", 30)
        cur = i
      end
    end
    push("\r", 40)
    return steps
  end

  if action.type == "custom" then
    local text = tostring(action.text or "")
    local other_idx = nil
    for i, opt in ipairs(prompt.options or {}) do
      if opt.is_other then
        other_idx = i
        break
      end
    end
    if other_idx then
      move(prompt.initial_idx or 1, other_idx)
      push("\r", 40)
      push(text, 70)
      push("\r", 40)
    else
      push(text, 0)
      push("\r", 35)
    end
    return steps
  end

  return steps
end

--- Send a timed sequence of keystrokes to a session's PTY job
---@param sess SuperHarnessSession|nil
---@param steps table[]
---@param on_done? fun()
function M._send_steps(sess, steps, on_done)
  if not sess or not sess.job_id or sess.state == "exited" then
    if on_done then
      on_done()
    end
    return false
  end

  local cumulative = 0
  for _, step in ipairs(steps) do
    cumulative = cumulative + (step.delay_ms or 0)
    local seq = step.seq
    if cumulative == 0 then
      pcall(vim.api.nvim_chan_send, sess.job_id, seq)
    else
      vim.defer_fn(function()
        if sess.job_id and sess.state ~= "exited" then
          pcall(vim.api.nvim_chan_send, sess.job_id, seq)
        end
      end, cumulative)
    end
  end

  if on_done then
    vim.defer_fn(on_done, cumulative + 50)
  end
  return true
end

function M.is_open()
  return M._win ~= nil and vim.api.nvim_win_is_valid(M._win) and M._buf ~= nil and vim.api.nvim_buf_is_valid(M._buf)
end

function M.close()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    pcall(vim.api.nvim_win_close, M._win, true)
  end
  M._win = nil
  if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
    pcall(vim.api.nvim_buf_delete, M._buf, { force = true })
  end
  M._buf = nil
  M._sess = nil
  M._prompt = nil
  M._option_lines = {}
  M._line_to_option = {}
end

local function wrap_text(text, max_width)
  local out = {}
  for _, para in ipairs(vim.split(tostring(text or ""), "\n", { plain = true })) do
    if #para <= max_width then
      table.insert(out, para)
    else
      local cur = ""
      for word in para:gmatch("%S+") do
        if cur == "" then
          cur = word
        elseif (#cur + 1 + #word) <= max_width then
          cur = cur .. " " .. word
        else
          table.insert(out, cur)
          cur = word
        end
      end
      if cur ~= "" then
        table.insert(out, cur)
      end
    end
  end
  return out
end

--- Render the Neovim-style approval popup contents and highlights
function M.render()
  if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) or not M._prompt then
    return
  end
  setup_highlights()

  local prompt = M._prompt
  local width = (M._win and vim.api.nvim_win_is_valid(M._win)) and vim.api.nvim_win_get_width(M._win) or 68
  local inner_w = math.max(36, width - 4)

  local lines = {}
  local hl_spans = {} -- { line0, col_start, col_end, hl_group }
  M._option_lines = {}
  M._line_to_option = {}

  -- Header badge
  local sess_label = (M._sess and M._sess.adapter and M._sess.adapter.label) or "Agent"
  local icon = (M._sess and M._sess.adapter and M._sess.adapter.icon) or "󰚩"
  local mode_badge = prompt.kind == "multi_select" and "MULTI-SELECT"
    or (prompt.kind == "confirm" and "CONFIRM")
    or "SELECT"
  local prog_badge = prompt.progress and ("  Question " .. prompt.progress) or ""
  local header = string.format("  %s %s  •  %s%s", icon, sess_label, mode_badge, prog_badge)
  table.insert(lines, header)
  table.insert(hl_spans, { #lines - 1, 0, -1, "SuperHarnessApprovalBadge" })

  table.insert(lines, "  " .. string.rep("─", inner_w))
  table.insert(hl_spans, { #lines - 1, 0, -1, "SuperHarnessApprovalSep" })

  -- Question text
  for _, ql in ipairs(wrap_text(prompt.question, inner_w)) do
    table.insert(lines, "  " .. ql)
    table.insert(hl_spans, { #lines - 1, 0, -1, "SuperHarnessApprovalQuestion" })
  end
  table.insert(lines, "")

  -- Option rows
  for i, opt in ipairs(prompt.options) do
    local is_cur = (i == M._cursor)
    local pointer = is_cur and "▶" or " "
    local row_text
    if prompt.kind == "multi_select" then
      local box = M._checked[i] and "[✓]" or "[ ]"
      row_text = string.format("  %s %s %d. %s", pointer, box, i, opt.label)
    else
      row_text = string.format("  %s %d. %s", pointer, i, opt.label)
    end
    table.insert(lines, row_text)
    local lnum = #lines
    M._option_lines[i] = lnum
    M._line_to_option[lnum] = i

    if is_cur then
      table.insert(hl_spans, { lnum - 1, 0, -1, "SuperHarnessApprovalSelected" })
    elseif prompt.kind == "multi_select" and M._checked[i] then
      table.insert(hl_spans, { lnum - 1, 0, -1, "SuperHarnessApprovalChecked" })
    elseif opt.is_recommended then
      table.insert(hl_spans, { lnum - 1, 0, -1, "SuperHarnessApprovalRec" })
    end
  end

  table.insert(lines, "")
  table.insert(lines, "  " .. string.rep("─", inner_w))
  table.insert(hl_spans, { #lines - 1, 0, -1, "SuperHarnessApprovalSep" })

  local footer
  if prompt.kind == "multi_select" then
    footer = "  j/k/↑↓ Move │ <Space>/1-9 Toggle │ <CR> Submit │ i Custom │ t Terminal │ <Esc> Cancel │ q Hide"
  elseif prompt.kind == "confirm" then
    footer = "  y/1 Approve │ n/2 Deny │ j/k/↑↓ Move │ <CR> Select │ i Custom │ t Terminal │ <Esc> Cancel"
  else
    footer = "  j/k/↑↓ Move │ <CR>/1-9 Select │ i Custom │ t Terminal │ <Esc> Cancel │ q Hide"
  end
  table.insert(lines, footer)
  table.insert(hl_spans, { #lines - 1, 0, -1, "SuperHarnessApprovalHint" })

  vim.bo[M._buf].modifiable = true
  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, lines)
  vim.bo[M._buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(M._buf, M._ns, 0, -1)
  for _, sp in ipairs(hl_spans) do
    pcall(vim.api.nvim_buf_add_highlight, M._buf, M._ns, sp[4], sp[1], sp[2], sp[3])
  end

  -- Keep window cursor aligned with selected option
  if M._win and vim.api.nvim_win_is_valid(M._win) and M._option_lines[M._cursor] then
    pcall(vim.api.nvim_win_set_cursor, M._win, { M._option_lines[M._cursor], 2 })
  end
end

local function finish_and_dispatch(action)
  local sess = M._sess
  local prompt = M._prompt
  local on_submit = M._on_submit
  M.close()

  if sess then
    -- Remember this prompt signature so we never re-open on the exact same rendered screen,
    -- while allowing genuinely different follow-up questions (e.g. 1/2 -> 2/2) to open cleanly.
    if prompt and prompt.sig then
      sess._last_prompt_sig = prompt.sig
    end
    if sess.state == "awaiting_input" then
      sess.state = "thinking"
    end
    if sess._last_notify then
      sess._last_notify["attention"] = nil
    end
  end

  local steps = M.build_keystrokes(prompt, action)
  if on_submit then
    on_submit(action, steps)
  else
    M._send_steps(sess, steps)
  end
end

function M.move(delta)
  if not M._prompt or #M._prompt.options == 0 then
    return
  end
  local n = #M._prompt.options
  M._cursor = ((M._cursor - 1 + delta) % n) + 1
  M.render()
end

function M.toggle_current(idx)
  if not M._prompt or M._prompt.kind ~= "multi_select" then
    return false
  end
  local target = idx or M._cursor
  if not M._prompt.options[target] then
    return false
  end
  M._checked[target] = not M._checked[target]
  M._cursor = target
  M.render()
  return true
end

function M.confirm_current(idx)
  if not M._prompt or #M._prompt.options == 0 then
    return false
  end
  local target = idx or M._cursor
  local opt = M._prompt.options[target]
  if not opt then
    return false
  end

  if M._prompt.kind == "multi_select" then
    local any_checked = false
    for i = 1, #M._prompt.options do
      if M._checked[i] then
        any_checked = true
        break
      end
    end
    -- If user hits <CR> without toggling anything, select the highlighted option
    if not any_checked then
      M._checked[target] = true
    end
    finish_and_dispatch({ type = "multi_select", checked = vim.deepcopy(M._checked) })
    return true
  end

  if opt.is_other then
    M.prompt_custom()
    return true
  end

  if M._prompt.kind == "confirm" then
    finish_and_dispatch({ type = "confirm", idx = target, send = opt.send })
    return true
  end

  finish_and_dispatch({ type = "select", idx = target })
  return true
end

function M.prompt_custom()
  local sess = M._sess
  local prompt = M._prompt
  local on_submit = M._on_submit
  M.close()
  vim.ui.input({ prompt = "Custom response: " }, function(answer)
    if answer and vim.trim(answer) ~= "" then
      M._sess = sess
      M._prompt = prompt
      M._on_submit = on_submit
      finish_and_dispatch({ type = "custom", text = answer })
    end
  end)
end

function M.cancel()
  finish_and_dispatch({ type = "cancel" })
end

--- Open the Neovim-native floating approval/question popup for a session
---@param sess? SuperHarnessSession
---@param opts? { text?: string, prompt?: table, auto?: boolean, on_submit?: fun(action:table, steps:table[]) }
---@return integer|nil winid, integer|nil bufnr
function M.open(sess, opts)
  opts = opts or {}
  sess = sess or state.get_active()

  local prompt = opts.prompt
  if not prompt then
    local text = opts.text
    if (not text or text == "") and sess then
      local ok_term, nvim_term = pcall(require, "super_harness.backends.nvim_term")
      if ok_term and nvim_term._get_rendered_tail then
        text = nvim_term._get_rendered_tail(sess, 28)
      end
    end
    prompt = M.parse_prompt(text or "")
  end

  if opts.auto then
    if not prompt.is_interactive then
      return nil, nil
    end
    if sess and prompt.sig and sess._last_prompt_sig == prompt.sig then
      return nil, nil
    end
  end

  -- Leave terminal/insert/replace mode so Normal-mode popup keymaps (j/k/arrows/1-9/<CR>) work immediately
  local mode = vim.api.nvim_get_mode().mode
  local m1 = mode and mode:sub(1, 1) or ""
  if m1 == "t" or m1 == "i" or m1 == "R" then
    pcall(vim.cmd, "stopinsert")
  end

  M.close()
  M._sess = sess
  M._prompt = prompt
  M._on_submit = opts.on_submit
  M._cursor = math.max(1, math.min(prompt.initial_idx or 1, math.max(1, #prompt.options)))
  M._checked = {}
  for i, opt in ipairs(prompt.options) do
    M._checked[i] = opt.checked == true
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "super_harness_approval"
  M._buf = buf

  local cols = vim.o.columns
  local rows = vim.o.lines - vim.o.cmdheight
  local width = math.min(math.max(math.floor(cols * 0.56), 54), cols - 6)
  local q_lines = wrap_text(prompt.question, math.max(36, width - 4))
  local content_height = 2 + #q_lines + 1 + #prompt.options + 3
  local height = math.min(math.max(content_height, 9), math.max(10, rows - 6))
  local row = math.max(1, math.floor((rows - height) / 2))
  local col = math.max(1, math.floor((cols - width) / 2))

  local title_text = " ▲ SuperHarness Approval "
  if prompt.progress then
    title_text = string.format(" ▲ SuperHarness Approval (%s) ", prompt.progress)
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = (config.options.ui and config.options.ui.float and config.options.ui.float.border) or "rounded",
    title = title_text,
    title_pos = "center",
    zindex = 60,
  })
  M._win = win
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  M.render()

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  map("j", function() M.move(1) end, "Next Option")
  map("<Down>", function() M.move(1) end, "Next Option")
  map("k", function() M.move(-1) end, "Previous Option")
  map("<Up>", function() M.move(-1) end, "Previous Option")
  map("<Space>", function() M.toggle_current() end, "Toggle Option")
  map("<Tab>", function()
    if M._prompt and M._prompt.kind == "multi_select" then
      M.toggle_current()
    else
      M.move(1)
    end
  end, "Toggle / Next Option")
  map("<CR>", function() M.confirm_current() end, "Confirm / Submit")
  map("<kEnter>", function() M.confirm_current() end, "Confirm / Submit")
  map("i", function() M.prompt_custom() end, "Type Custom Response")
  map("o", function() M.prompt_custom() end, "Type Custom Response")
  map("<Esc>", function() M.cancel() end, "Cancel Prompt in Agent")
  map("q", function()
    if M._sess and M._prompt and M._prompt.sig then
      M._sess._last_prompt_sig = M._prompt.sig
    end
    M.close()
  end, "Dismiss Popup")

  map("t", function()
    local target = M._sess
    if target and M._prompt and M._prompt.sig then
      target._last_prompt_sig = M._prompt.sig
    end
    M.close()
    if target then
      local ok_term, nvim_term = pcall(require, "super_harness.backends.nvim_term")
      if ok_term and nvim_term.open_session then
        nvim_term.open_session(target, {
          layout = (config.options.notifications or {}).attention_layout or "float",
          temporary_layout = true,
          title_prefix = "▲ Attention — ",
          enter_insert = true,
        })
      end
    end
  end, "Switch to Raw Harness Terminal")

  if prompt.kind == "confirm" then
    map("y", function() M.confirm_current(1) end, "Approve / Yes")
    map("n", function() M.confirm_current(2) end, "Deny / No")
  end

  for n = 1, math.min(9, #prompt.options) do
    map(tostring(n), function()
      if M._prompt and M._prompt.kind == "multi_select" then
        M.toggle_current(n)
      else
        M.confirm_current(n)
      end
    end, "Select Option " .. n)
  end

  return win, buf
end

return M
