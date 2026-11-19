local config = require("super_harness.config")
local state = require("super_harness.state")
local log = require("super_harness.utils.log")
local adapters = require("super_harness.adapters")
local backends = require("super_harness.backends")
local context = require("super_harness.context")
local review = require("super_harness.review")
local diffsplit = require("super_harness.review.diffsplit")
local sync = require("super_harness.sync")
local window = require("super_harness.ui.window")
local picker = require("super_harness.ui.picker")
local input = require("super_harness.ui.input")

local M = {}

M._buf = nil
M._win = nil
M._tab = "sessions"
M._line_map = {}

function M.close()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    pcall(vim.api.nvim_win_close, M._win, true)
  end
  M._win = nil
  if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
    pcall(vim.api.nvim_buf_delete, M._buf, { force = true })
  end
  M._buf = nil
  M._line_map = {}
end

function M.render()
  if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) then
    return
  end

  local icons = config.options.ui.icons or {}
  local sess_list = state.list()
  local tray_list = context.tray_list()
  local changed = review.get_changed_files()
  local comments = review.list_comments()

  local function tab_lbl(key, num, name, count)
    local txt = string.format("[%d] %s (%d)", num, name, count)
    return M._tab == key and ("▶ " .. txt .. " ◀") or ("  " .. txt .. "  ")
  end

  local lines = {}
  M._line_map = {}

  table.insert(
    lines,
    string.format(
      "  %s SuperHarness Control Center   %s   %s   %s",
      icons.harness or "󰚩",
      tab_lbl("sessions", 1, "Sessions", #sess_list),
      tab_lbl("tray", 2, "Context Tray", #tray_list),
      tab_lbl("review", 3, "Review", #changed + #comments)
    )
  )
  table.insert(lines, "  " .. string.rep("═", 76))
  table.insert(lines, "")

  if M._tab == "sessions" then
    local installed = vim.tbl_map(function(a) return a.name end, adapters.detect_installed())
    table.insert(lines, "  Installed Agents: " .. (#installed > 0 and table.concat(installed, ", ") or "(none on $PATH)"))
    table.insert(lines, "")
    if #sess_list == 0 then
      table.insert(lines, "  No active agent sessions. Press `n` to pick & launch one.")
    else
      for _, s in ipairs(sess_list) do
        local star = (s.id == state.active_id) and "*" or " "
        local st = icons[s.state] or "●"
        local vis = window.is_visible(s) and "visible" or s.backend
        local age = log.format_duration(os.time() - (s.started_at or os.time()))
        local last = s.last_prompt ~= "" and ("  " .. log.truncate(s.last_prompt, 32)) or ""
        table.insert(lines, string.format("  %s %s %-15s %-9s %-8s %6s%s", star, st, s.id, s.layout, vis, age, last))
        M._line_map[#lines] = { kind = "session", data = s }
      end
    end
    table.insert(lines, "")
    table.insert(lines, "  " .. string.rep("─", 76))
    table.insert(lines, "  <CR> Focus | n New | s Active | z Zoom | x Kill | b Broadcast | 1/2/3 Tabs | q Close")
  elseif M._tab == "tray" then
    local tok = context.tray_tokens()
    local warn = tok > (config.options.context.token_budget_warn or 32000) and "  ⚠ OVER BUDGET" or ""
    table.insert(lines, string.format("  Staged Context Tray: %d item(s)  |  ~%s tokens%s", #tray_list, log.format_tokens(tok), warn))
    table.insert(lines, "")
    if #tray_list == 0 then
      table.insert(lines, "  Context Tray is empty. Stage with: `f` file, `d` diagnostics, `g` diff, `B` buffers.")
    else
      for i, item in ipairs(tray_list) do
        table.insert(lines, string.format("  %2d. %-54s  ~%s tok", i, log.truncate(item.label, 54), log.format_tokens(item.tokens)))
        M._line_map[#lines] = { kind = "tray", idx = i, data = item }
      end
    end
    table.insert(lines, "")
    table.insert(lines, "  " .. string.rep("─", 76))
    table.insert(lines, "  f +File | d +Diags | g +Diff | B +Buffers | x Remove | C Clear | S Send | q Close")
  else
    table.insert(lines, string.format("  Modified Files (%d) & Queued Review Comments (%d):", #changed, #comments))
    table.insert(lines, "")
    if #changed == 0 then
      table.insert(lines, "  No modified files detected.")
    else
      for _, f in ipairs(changed) do
        local chk = f.accepted and "✓" or " "
        table.insert(lines, string.format("  [%s] %-2s  %-48s  +%d -%d", chk, f.status, log.truncate(f.rel_path, 48), f.added, f.deleted))
        M._line_map[#lines] = { kind = "file", data = f }
      end
    end
    if #comments > 0 then
      table.insert(lines, "")
      table.insert(lines, "  Review Comments:")
      for i, c in ipairs(comments) do
        table.insert(lines, string.format("  #%d  %s:L%d-L%d — %s", i, c.rel_path, c.start_line, c.end_line, log.truncate(c.comment, 38)))
        M._line_map[#lines] = { kind = "comment", idx = i, data = c }
      end
    end
    table.insert(lines, "")
    table.insert(lines, "  " .. string.rep("─", 76))
    table.insert(lines, "  <CR> Open | D Diff | a Accept | r Revert | S Send Comments | R Refresh | q Close")
  end

  vim.bo[M._buf].modifiable = true
  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, lines)
  vim.bo[M._buf].modifiable = false
end

function M.open(tab)
  M.close()
  if tab == "sessions" or tab == "tray" or tab == "review" then
    M._tab = tab
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "super_harness_hud"
  vim.b[buf].super_harness_buf = true
  M._buf = buf

  local cols = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = math.min(96, math.max(80, math.floor(cols * 0.78)))
  local height = math.min(32, math.max(16, math.floor(lines * 0.65)))

  M._win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((lines - height) / 2),
    col = math.floor((cols - width) / 2),
    style = "minimal",
    border = (config.options.ui.float or {}).border or "rounded",
    title = " 󰚩 SuperHarness HUD ",
    title_pos = "center",
  })
  vim.wo[M._win].cursorline = true
  M.render()

  local function entry()
    return M._line_map[vim.api.nvim_win_get_cursor(M._win)[1]]
  end

  local opts = { buffer = buf, silent = true }
  vim.keymap.set("n", "q", M.close, opts)
  vim.keymap.set("n", "<Esc>", M.close, opts)
  vim.keymap.set("n", "R", M.render, opts)
  vim.keymap.set("n", "1", function() M._tab = "sessions"; M.render() end, opts)
  vim.keymap.set("n", "2", function() M._tab = "tray"; M.render() end, opts)
  vim.keymap.set("n", "3", function() M._tab = "review"; M.render() end, opts)

  vim.keymap.set("n", "n", function() M.close(); picker.pick_adapter() end, opts)
  vim.keymap.set("n", "b", function() M.close(); input.open({ broadcast = true }) end, opts)
  vim.keymap.set("n", "s", function()
    local e = entry()
    if e and e.kind == "session" then state.set_active(e.data.id); M.render() end
  end, opts)
  vim.keymap.set("n", "z", function()
    local e = entry()
    if e and e.kind == "session" then M.close(); backends.zoom(e.data.id) end
  end, opts)

  vim.keymap.set("n", "f", function() context.tray_add(context.collect_file()); M._tab = "tray"; M.render() end, opts)
  vim.keymap.set("n", "d", function()
    local item = context.collect_diagnostics()
    if item then context.tray_add(item) else log.info("No diagnostics in buffer.") end
    M._tab = "tray"; M.render()
  end, opts)
  vim.keymap.set("n", "g", function()
    local item = context.collect_git_diff()
    if item then context.tray_add(item) else log.info("No unstaged git diff.") end
    M._tab = "tray"; M.render()
  end, opts)
  vim.keymap.set("n", "B", function() context.tray_add(context.collect_buffers()); M._tab = "tray"; M.render() end, opts)
  vim.keymap.set("n", "C", function() context.tray_clear(); M.render() end, opts)

  vim.keymap.set("n", "<CR>", function()
    local e = entry()
    if not e then return end
    M.close()
    if e.kind == "session" then backends.show(e.data.id)
    elseif e.kind == "file" then sync.open_file(e.data.abs_path)
    elseif e.kind == "comment" and e.data.abs_path ~= "" then sync.open_file(e.data.abs_path, e.data.start_line, 1)
    end
  end, opts)
  vim.keymap.set("n", "x", function()
    local e = entry()
    if not e then return end
    if e.kind == "session" then backends.kill(e.data.id)
    elseif e.kind == "tray" then context.tray_remove(e.idx)
    elseif e.kind == "comment" then review.remove_comment(e.idx)
    end
    M.render()
  end, opts)
  vim.keymap.set("n", "D", function()
    local e = entry()
    if e and e.kind == "file" then M.close(); diffsplit.open_file_diff(e.data) end
  end, opts)
  vim.keymap.set("n", "a", function()
    local e = entry()
    if e and e.kind == "file" then review.accept_file(e.data.rel_path); M.render() end
  end, opts)
  vim.keymap.set("n", "r", function()
    local e = entry()
    if e and e.kind == "file" then review.revert_file(e.data.abs_path); M.render() end
  end, opts)
  vim.keymap.set("n", "S", function()
    if M._tab == "tray" then
      M.close()
      input.open({ include_tray = true })
    elseif M._tab == "review" then
      local active = state.get_active()
      local payload = review.format_comments_payload(active and active.adapter or nil)
      if payload ~= "" then
        M.close()
        if backends.send(payload, { focus = true }) then review.clear_comments() end
      else
        log.info("No review comments queued.")
      end
    end
  end, opts)
end

return M
