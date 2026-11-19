local config = require("super_harness.config")
local state = require("super_harness.state")
local log = require("super_harness.utils.log")

local uv = vim.uv or vim.loop

local M = {}

M._buf = nil
M._win = nil
M._turns = {}
M._turn_state = {} -- key -> { collapsed = bool, pinned = bool }
M._line_to_turn = {} -- 1-based buffer line -> turn index in M._visible_turns
M._turn_header_lines = {} -- visible turn index -> 1-based header line
M._visible_turns = {}
M._filter = nil
M._source_label = ""
M._last_opts = {}

local function turn_key(turn)
  return string.format("%s|%s", tostring(turn.id or ""), (turn.question or ""):sub(1, 80))
end

local function first_line(text)
  local s = vim.trim(tostring(text or "")):gsub("\r\n", "\n")
  local nl = s:find("\n", 1, true)
  return nl and s:sub(1, nl - 1) or s
end

local function split_lines(text)
  if not text or text == "" then
    return {}
  end
  return vim.split(tostring(text):gsub("\r\n", "\n"):gsub("\r", "\n"), "\n", { plain = true })
end

--- Extract clean user prompt(s) from Antigravity USER_INPUT content
---@param raw string
---@return string
local function extract_user_requests(raw)
  if type(raw) ~= "string" then
    return ""
  end
  local parts = {}
  for req in raw:gmatch("<USER_REQUEST>%s*(.-)%s*</USER_REQUEST>") do
    local t = vim.trim(req)
    if t ~= "" then
      table.insert(parts, t)
    end
  end
  if #parts > 0 then
    return table.concat(parts, "\n\n")
  end
  -- Strip trailing metadata blocks if tags weren't matched
  local cleaned = raw:gsub("<ADDITIONAL_METADATA>.-</ADDITIONAL_METADATA>", "")
  cleaned = cleaned:gsub("<USER_SETTINGS_CHANGE>.-</USER_SETTINGS_CHANGE>", "")
  return vim.trim(cleaned)
end

--- Parse an Antigravity transcript.jsonl file into structured Q&A turns
---@param filepath string
---@return table[] turns
function M.parse_antigravity_jsonl(filepath)
  if not filepath or filepath == "" or vim.fn.filereadable(filepath) ~= 1 then
    return {}
  end
  local ok_read, lines = pcall(vim.fn.readfile, filepath)
  if not ok_read or type(lines) ~= "table" then
    return {}
  end

  local turns = {}
  local current = nil

  for _, line in ipairs(lines) do
    if line and line ~= "" then
      local ok, obj = pcall(vim.json.decode, line)
      if ok and type(obj) == "table" then
        if obj.type == "USER_INPUT" then
          local q = extract_user_requests(obj.content or "")
          if q ~= "" then
            current = {
              id = #turns + 1,
              question = q,
              answer = "",
              created_at = obj.created_at or "",
              collapsed = false,
              pinned = false,
            }
            table.insert(turns, current)
          end
        elseif obj.type == "PLANNER_RESPONSE" and type(obj.content) == "string" then
          local ans = vim.trim(obj.content)
          if ans ~= "" then
            if not current then
              current = {
                id = #turns + 1,
                question = "(Session start)",
                answer = ans,
                created_at = obj.created_at or "",
                collapsed = false,
                pinned = false,
              }
              table.insert(turns, current)
            elseif current.answer == "" then
              current.answer = ans
            else
              current.answer = current.answer .. "\n\n" .. ans
            end
          end
        end
      end
    end
  end

  return turns
end

--- Find the most recently modified Antigravity transcript.jsonl
---@param brain_dir? string
---@return string|nil
function M.find_latest_antigravity_transcript(brain_dir)
  local base = brain_dir or vim.fn.expand("~/.gemini/antigravity-cli/brain")
  if vim.fn.isdirectory(base) ~= 1 then
    return nil
  end
  local matches = vim.fn.globpath(base, "*/.system_generated/logs/transcript.jsonl", true, true)
  if type(matches) ~= "table" or #matches == 0 then
    return nil
  end

  local best_path = nil
  local best_mtime = -1
  for _, p in ipairs(matches) do
    local st = uv and uv.fs_stat and uv.fs_stat(p)
    local mtime = st and st.mtime and st.mtime.sec or 0
    if mtime > best_mtime then
      best_mtime = mtime
      best_path = p
    end
  end
  return best_path
end

--- Record a new user question on a live session
---@param sess SuperHarnessSession
---@param question string
---@return table|nil
function M.record_question(sess, question)
  if not sess then
    return nil
  end
  local q = vim.trim(tostring(question or ""))
  if q == "" then
    return nil
  end
  sess.turns = sess.turns or {}
  local turn = {
    id = #sess.turns + 1,
    question = q,
    answer = "",
    started_at = os.time(),
    completed_at = nil,
    collapsed = false,
    pinned = false,
  }
  table.insert(sess.turns, turn)
  sess._active_turn = turn
  if M.is_open() then
    vim.schedule(function()
      M.refresh()
    end)
  end
  return turn
end

--- Append stripped agent output chunk to the active turn
---@param sess SuperHarnessSession
---@param chunk string
function M.append_answer(sess, chunk)
  if not sess or not sess._active_turn then
    return
  end
  local clean = vim.trim(tostring(chunk or ""))
  if clean == "" then
    return
  end
  local turn = sess._active_turn
  if turn.answer == "" then
    turn.answer = clean
  else
    turn.answer = turn.answer .. "\n" .. clean
  end
end

--- Mark the active turn as finished and refresh the transcript view if open
---@param sess SuperHarnessSession
function M.finish_turn(sess)
  if not sess or not sess._active_turn then
    return
  end
  sess._active_turn.completed_at = os.time()
  sess._active_turn = nil
  if M.is_open() then
    vim.schedule(function()
      M.refresh()
    end)
  end
end

--- Collect turns from explicit opts, Antigravity transcript.jsonl, or live session turns
---@param opts? table
---@return table[] turns, string source_label
function M.collect_turns(opts)
  opts = opts or {}
  local turns = {}
  local label = "Q&A"

  if type(opts.turns) == "table" then
    turns = vim.deepcopy(opts.turns)
    label = opts.label or "Custom"
  elseif opts.transcript_path then
    turns = M.parse_antigravity_jsonl(opts.transcript_path)
    label = "Antigravity"
  else
    local sess = opts.session or state.get_active()
    local is_agy = (not sess) or (sess.adapter and sess.adapter.name == "antigravity")

    if is_agy then
      local latest = M.find_latest_antigravity_transcript(opts.brain_dir)
      if latest then
        local agy_turns = M.parse_antigravity_jsonl(latest)
        if #agy_turns > 0 then
          turns = agy_turns
          label = sess and sess.id or "Antigravity"
        end
      end
    end

    if #turns == 0 and sess and sess.turns and #sess.turns > 0 then
      turns = vim.deepcopy(sess.turns)
      label = sess.id
    elseif #turns == 0 and sess then
      label = sess.id
    end
  end

  local default_collapsed = (config.options.ui and config.options.ui.transcript_default_collapsed) or false
  for i, t in ipairs(turns) do
    t.id = t.id or i
    local key = turn_key(t)
    local saved = M._turn_state[key]
    if saved then
      t.collapsed = saved.collapsed
      t.pinned = saved.pinned
    else
      if t.collapsed == nil then
        t.collapsed = default_collapsed
      end
      if t.pinned == nil then
        t.pinned = false
      end
      M._turn_state[key] = { collapsed = t.collapsed, pinned = t.pinned }
    end
  end

  return turns, label
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
  M._line_to_turn = {}
  M._turn_header_lines = {}
end

local function save_turn_state(turn)
  M._turn_state[turn_key(turn)] = {
    collapsed = turn.collapsed == true,
    pinned = turn.pinned == true,
  }
end

local function current_visible_idx()
  if not M.is_open() then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(M._win)[1]
  return M._line_to_turn[lnum]
end

local function set_cursor_to_turn(vis_idx)
  if not M.is_open() or not vis_idx then
    return
  end
  local target_line = M._turn_header_lines[vis_idx]
  if target_line then
    local total = vim.api.nvim_buf_line_count(M._buf)
    pcall(vim.api.nvim_win_set_cursor, M._win, { math.min(target_line, total), 2 })
  end
end

--- Toggle collapse state of a turn (1-based index into visible turns)
---@param vis_idx? integer
---@param force_collapsed? boolean
function M.set_collapsed(vis_idx, force_collapsed)
  local idx = vis_idx or current_visible_idx()
  if not idx or not M._visible_turns[idx] then
    return false
  end
  local turn = M._visible_turns[idx]
  if force_collapsed == nil then
    turn.collapsed = not turn.collapsed
  else
    turn.collapsed = force_collapsed
  end
  save_turn_state(turn)
  M.render()
  set_cursor_to_turn(idx)
  return true
end

--- Collapse all turns (keeps pinned turns open unless all unpinned are already collapsed)
function M.collapse_all()
  local idx = current_visible_idx()
  local any_unpinned_open = false
  for _, t in ipairs(M._turns) do
    if not t.pinned and not t.collapsed then
      any_unpinned_open = true
      break
    end
  end
  for _, t in ipairs(M._turns) do
    if any_unpinned_open then
      if not t.pinned then
        t.collapsed = true
      end
    else
      t.collapsed = true
    end
    save_turn_state(t)
  end
  M.render()
  set_cursor_to_turn(idx)
end

--- Expand all turns
function M.expand_all()
  local idx = current_visible_idx()
  for _, t in ipairs(M._turns) do
    t.collapsed = false
    save_turn_state(t)
  end
  M.render()
  set_cursor_to_turn(idx)
end

--- Focus mode: expand ONLY the current turn (plus pinned turns) and collapse all others
---@param vis_idx? integer
function M.focus_turn(vis_idx)
  local idx = vis_idx or current_visible_idx()
  if not idx or not M._visible_turns[idx] then
    return false
  end
  local target = M._visible_turns[idx]
  for _, t in ipairs(M._turns) do
    t.collapsed = not (t == target or t.pinned)
    save_turn_state(t)
  end
  M.render()
  set_cursor_to_turn(idx)
  return true
end

--- Pin or unpin the current turn so it stays highlighted / preserved when collapsing
---@param vis_idx? integer
function M.toggle_pin(vis_idx)
  local idx = vis_idx or current_visible_idx()
  if not idx or not M._visible_turns[idx] then
    return false
  end
  local turn = M._visible_turns[idx]
  turn.pinned = not turn.pinned
  if turn.pinned then
    turn.collapsed = false
  end
  save_turn_state(turn)
  M.render()
  set_cursor_to_turn(idx)
  return true
end

--- Filter visible turns by a case-insensitive substring (nil or "" clears filter)
---@param query? string
function M.set_filter(query)
  if query and vim.trim(query) ~= "" then
    M._filter = vim.trim(query):lower()
  else
    M._filter = nil
  end
  M.render()
  if #M._visible_turns > 0 then
    set_cursor_to_turn(1)
  end
end

--- Jump to next or previous Q&A turn header
---@param delta integer (+1 or -1)
function M.jump_turn(delta)
  if not M.is_open() or #M._visible_turns == 0 then
    return
  end
  local idx = current_visible_idx() or (delta > 0 and 0 or (#M._visible_turns + 1))
  local next_idx = idx + delta
  if next_idx < 1 then
    next_idx = #M._visible_turns
  elseif next_idx > #M._visible_turns then
    next_idx = 1
  end
  set_cursor_to_turn(next_idx)
end

--- Render collapsible Q&A lines into the transcript buffer
function M.render()
  if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) then
    return
  end

  -- Apply keyword filter
  M._visible_turns = {}
  for _, t in ipairs(M._turns) do
    if not M._filter then
      table.insert(M._visible_turns, t)
    else
      local hay = ((t.question or "") .. "\n" .. (t.answer or "")):lower()
      if hay:find(M._filter, 1, true) then
        table.insert(M._visible_turns, t)
      end
    end
  end

  local collapsed_count = 0
  for _, t in ipairs(M._visible_turns) do
    if t.collapsed then
      collapsed_count = collapsed_count + 1
    end
  end

  local lines = {}
  M._line_to_turn = {}
  M._turn_header_lines = {}

  local filter_badge = M._filter and ("  |  filter: \"" .. M._filter .. "\"") or ""
  table.insert(
    lines,
    string.format(
      "  󰚩 SuperHarness Q&A (%s) — %d/%d turn(s), %d collapsed%s",
      M._source_label ~= "" and M._source_label or "Session",
      #M._visible_turns,
      #M._turns,
      collapsed_count,
      filter_badge
    )
  )
  table.insert(lines, "  " .. string.rep("═", 76))
  table.insert(lines, "")

  if #M._visible_turns == 0 then
    if M._filter then
      table.insert(lines, "  No Q&A turns match filter \"" .. M._filter .. "\". Press `F` to clear filter.")
    else
      table.insert(lines, "  No Q&A turns recorded yet. Ask a question (`a`) or press `r` to refresh.")
    end
  else
    for vis_idx, turn in ipairs(M._visible_turns) do
      local arrow = turn.collapsed and "▸" or "▾"
      local pin = turn.pinned and "★ " or ""
      local q_preview = log.truncate(first_line(turn.question), 58)
      local ans_lines = split_lines(turn.answer)
      local meta = #ans_lines > 0 and string.format("(%d lines)", #ans_lines) or "(pending...)"

      local header = string.format("  %s [Q%d] %s%s  %s", arrow, turn.id, pin, q_preview, meta)
      table.insert(lines, header)
      local header_line = #lines
      M._turn_header_lines[vis_idx] = header_line
      M._line_to_turn[header_line] = vis_idx

      if not turn.collapsed then
        -- Question block
        table.insert(lines, "    ┌─ Question")
        M._line_to_turn[#lines] = vis_idx
        for _, ql in ipairs(split_lines(turn.question)) do
          table.insert(lines, "    │ " .. ql)
          M._line_to_turn[#lines] = vis_idx
        end

        -- Answer block
        table.insert(lines, "    ├─ Answer")
        M._line_to_turn[#lines] = vis_idx
        if #ans_lines == 0 then
          table.insert(lines, "    │ (waiting for response...)")
          M._line_to_turn[#lines] = vis_idx
        else
          for _, al in ipairs(ans_lines) do
            table.insert(lines, "    │ " .. al)
            M._line_to_turn[#lines] = vis_idx
          end
        end

        table.insert(lines, "    └" .. string.rep("─", 72))
        M._line_to_turn[#lines] = vis_idx
      end

      table.insert(lines, "")
      M._line_to_turn[#lines] = vis_idx
    end
  end

  table.insert(lines, "  " .. string.rep("─", 76))
  table.insert(lines, "  <CR>/<Tab>/za Toggle | o Focus | p Pin | zM Collapse All | zR Expand All | f Filter | F Clear | ]q/[q Jump | y Yank | r Refresh | q Close")

  vim.bo[M._buf].modifiable = true
  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, lines)
  vim.bo[M._buf].modifiable = false
end

--- Reload turns from source and re-render
function M.refresh()
  M._turns, M._source_label = M.collect_turns(M._last_opts)
  M.render()
end

--- Open the Collapsible Q&A Transcript window
---@param opts? table
---@return integer|nil winid, integer|nil bufnr
function M.open(opts)
  M.close()
  M._last_opts = opts or {}
  if M._last_opts.filter and vim.trim(M._last_opts.filter) ~= "" then
    M._filter = vim.trim(M._last_opts.filter):lower()
  end
  M._turns, M._source_label = M.collect_turns(M._last_opts)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  M._buf = buf

  local cols = vim.o.columns
  local rows = vim.o.lines - vim.o.cmdheight
  local width = math.min(math.max(math.floor(cols * 0.84), 60), cols - 4)
  local height = math.min(math.max(math.floor(rows * 0.82), 16), rows - 4)
  local row = math.max(1, math.floor((rows - height) / 2))
  local col = math.max(1, math.floor((cols - width) / 2))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = (config.options.ui and config.options.ui.float and config.options.ui.float.border) or "rounded",
    title = " 󰚩 Collapsible Q&A Transcript ",
    title_pos = "center",
  })
  M._win = win
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  M.render()

  -- Start cursor on the most recent turn header for quick inspection
  if #M._visible_turns > 0 then
    set_cursor_to_turn(#M._visible_turns)
  end

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  map("q", M.close, "Close Q&A Transcript")
  map("<Esc>", M.close, "Close Q&A Transcript")
  map("<CR>", function() M.set_collapsed(nil, nil) end, "Toggle Collapse Turn")
  map("<Tab>", function() M.set_collapsed(nil, nil) end, "Toggle Collapse Turn")
  map("za", function() M.set_collapsed(nil, nil) end, "Toggle Collapse Turn")
  map("zc", function() M.set_collapsed(nil, true) end, "Collapse Turn")
  map("h", function() M.set_collapsed(nil, true) end, "Collapse Turn")
  map("zo", function() M.set_collapsed(nil, false) end, "Expand Turn")
  map("l", function() M.set_collapsed(nil, false) end, "Expand Turn")
  map("zM", M.collapse_all, "Collapse All Turns")
  map("M", M.collapse_all, "Collapse All Turns")
  map("zR", M.expand_all, "Expand All Turns")
  map("R", M.expand_all, "Expand All Turns")
  map("o", function() M.focus_turn() end, "Focus Current Turn (Collapse Others)")
  map("p", function() M.toggle_pin() end, "Pin / Unpin Turn")
  map("]q", function() M.jump_turn(1) end, "Next Q&A Turn")
  map("J", function() M.jump_turn(1) end, "Next Q&A Turn")
  map("[q", function() M.jump_turn(-1) end, "Previous Q&A Turn")
  map("K", function() M.jump_turn(-1) end, "Previous Q&A Turn")
  map("r", function()
    M.refresh()
    log.info("Q&A transcript refreshed.")
  end, "Refresh Q&A Transcript")

  map("f", function()
    vim.ui.input({ prompt = "Filter Q&A turns: ", default = M._filter or "" }, function(query)
      if query ~= nil then
        M.set_filter(query)
      end
    end)
  end, "Filter Q&A Turns")

  map("F", function()
    M.set_filter(nil)
  end, "Clear Q&A Filter")

  map("y", function()
    local idx = current_visible_idx()
    if idx and M._visible_turns[idx] then
      local ans = M._visible_turns[idx].answer or ""
      pcall(vim.fn.setreg, '"', ans)
      pcall(vim.fn.setreg, "+", ans)
      log.info("Yanked Q" .. tostring(M._visible_turns[idx].id) .. " answer.")
    end
  end, "Yank Current Answer")

  map("a", function()
    M.close()
    local ok_inp, inp = pcall(require, "super_harness.ui.input")
    if ok_inp and inp.open then
      inp.open()
    end
  end, "Ask Follow-Up Question")

  return win, buf
end

--- Toggle the Collapsible Q&A Transcript window
---@param opts? table
function M.toggle(opts)
  if M.is_open() then
    M.close()
  else
    M.open(opts)
  end
end

return M
