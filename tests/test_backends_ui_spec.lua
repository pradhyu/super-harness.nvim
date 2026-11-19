local sh = require("super_harness")
local backends = require("super_harness.backends")
local state = require("super_harness.state")
local window = require("super_harness.ui.window")
local input = require("super_harness.ui.input")
local hud = require("super_harness.ui.hud")
local diffsplit = require("super_harness.review.diffsplit")
local health = require("super_harness.health")
local adapters = require("super_harness.adapters")

local function assert_true(c, m) if not c then error("FAIL: " .. (m or "")) end end
local function assert_eq(a, b, m) if a ~= b then error(string.format("FAIL: expected %s got %s (%s)", tostring(b), tostring(a), m or "")) end end

local hist_file = vim.fn.tempname() .. "_ui_hist.json"
sh.setup({
  project_config = false,
  ui = { auto_insert = false },
  sync = { fs_watch = false },
  notifications = { enabled = false },
  prompts = { history_file = hist_file },
  adapters = {
    mock_cli = {
      label = "Mock Cat Agent",
      cmd = { "cat" },
      submit_delay_ms = 0,
    },
  },
})

-- Spawn, hide, show, zoom, send, broadcast, kill
local s1, err1 = backends.spawn("mock_cli", { layout = "float", name = "builder" })
assert_true(s1 ~= nil, "spawned mock_cli: " .. tostring(err1))
assert_eq(s1.id, "builder", "named session ID preserved")
assert_true(window.is_visible(s1), "window visible")
assert_true(sh.statusline():find("builder", 1, true) ~= nil, "statusline shows session")

backends.hide(s1.id)
assert_true(not window.is_visible(s1), "hidden")
backends.show(s1.id, "float")
assert_true(window.is_visible(s1), "shown")
backends.zoom(s1.id)
assert_true(s1.zoomed, "zoomed")
backends.zoom(s1.id)
assert_true(not s1.zoomed, "unzoomed")

local ok_send = backends.send("ping", { id = s1.id, focus = false })
assert_true(ok_send, "send succeeded")

local s2 = backends.spawn("mock_cli", { layout = "background", name = "reviewer" })
assert_true(s2 ~= nil and s2.winid == nil, "background worker spawned without window")
assert_eq(backends.broadcast("arena test"), 2, "broadcast hit both sessions")
backends.kill_all()
assert_eq(#state.list(), 0, "all sessions killed")

-- Terminal gf/click ref parser
local tmp = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "return 1" }, tmp)
local sample = "Check `" .. tmp .. ":12:4` and @" .. tmp .. ":L5-L8"
local p1, l1, c1 = window.parse_file_ref_at(sample, 10, "/tmp")
assert_eq(p1, tmp, "parsed path:line:col")
assert_eq(l1, 12, "parsed line 12")
assert_eq(c1, 4, "parsed col 4")

local p2, l2 = window.parse_file_ref_token("**" .. tmp .. ":37-44**", "/tmp")
assert_eq(p2, tmp, "parsed markdown bold path:start-end")
assert_eq(l2, 37, "parsed start line 37 from range")

local p3, l3 = window.parse_file_ref_token("[setup](file://" .. tmp .. "#L10-L20)", "/tmp")
assert_eq(p3, tmp, "parsed markdown file://#L10-L20 link")
assert_eq(l3, 10, "parsed line 10 from #L10-L20")

local p4, l4 = window.parse_file_ref_in_line("  • Window #1000 — " .. tmp .. ":5 (buf #39):", "/tmp")
assert_eq(p4, tmp, "line scan found embedded file:line ref")
assert_eq(l4, 5, "line scan parsed line 5")

-- Background notifications & attention detection
local nvim_term = require("super_harness.backends.nvim_term")
local agy_adapter = adapters.get("antigravity")
assert_eq(agy_adapter.status_detector("Bypass Sandbox Mode: Always Allow / Deny"), "awaiting_input", "detects approval prompt")
assert_eq(agy_adapter.status_detector("Waiting for your confirmation"), "awaiting_input", "detects waiting for attention")
assert_eq(
  agy_adapter.status_detector("1. Option A\n2. Option B\n3. Other\n↑/↓ to navigate · Enter to select · Esc to cancel"),
  "awaiting_input",
  "detects interactive ask_question selector prompt"
)
assert_eq(
  agy_adapter.status_detector("Question 1/2\nSelect all that apply\nSpace to toggle · Enter to submit"),
  "awaiting_input",
  "detects multi-select ask_question prompt"
)

local bg_sess = { id = "antigravity#bg", winid = nil, bufnr = nil, adapter = agy_adapter }
assert_true(nvim_term.is_in_background(bg_sess), "hidden session is in background")
assert_true(
  not nvim_term._notify_session(bg_sess, "attention", "SuperHarness", "Needs approval", vim.log.levels.WARN),
  "respects notifications.enabled = false"
)
sh.config.options.notifications.enabled = true
assert_true(
  nvim_term._notify_session(bg_sess, "attention", "SuperHarness", "Needs approval", vim.log.levels.WARN),
  "fires attention notification when hidden"
)
assert_true(
  not nvim_term._notify_session(bg_sess, "attention", "SuperHarness", "Needs approval", vim.log.levels.WARN),
  "respects per-kind cooldown to prevent spam"
)
assert_true(
  nvim_term._notify_session(bg_sess, "complete", "SuperHarness", "Done", vim.log.levels.INFO),
  "fires complete notification independently of attention cooldown"
)

-- Auto-open modal float on attention (terminal style) while preserving original session layout
local modal_sess = backends.spawn("mock_cli", { layout = "drawer", name = "modal_test" })
assert_true(modal_sess ~= nil, "spawned modal_test")
backends.hide(modal_sess.id)
assert_true(not window.is_visible(modal_sess), "modal_test hidden before attention")
sh.config.options.notifications.auto_open_on_attention = true
sh.config.options.notifications.attention_style = "terminal"
sh.config.options.notifications.attention_layout = "float"
assert_true(
  nvim_term._notify_session(modal_sess, "attention", "SuperHarness", "Approve?", vim.log.levels.WARN),
  "fires attention notification for real session"
)
assert_true(window.is_visible(modal_sess), "auto-opened modal window on attention (terminal style)")
assert_eq(modal_sess.layout, "drawer", "preserved original session layout after temporary modal")
local win_cfg = vim.api.nvim_win_get_config(modal_sess.winid)
assert_eq(win_cfg.relative, "editor", "attention modal opened as floating window")
backends.kill(modal_sess.id)

-- Default Neovim-style native approval popup (not inside raw harness terminal)
local approval = require("super_harness.ui.approval")
sh.config.options.notifications.attention_style = "neovim"

local parsed_single = approval.parse_prompt(table.concat({
  "Approval test harness: would you like to approve this test action?",
  "  ❯ 1. (Recommended) Approve test action",
  "    2. Deny test action",
  "    3. Other",
  "  ↑/↓ navigate · Enter to select · Esc to cancel",
}, "\n"))
assert_eq(parsed_single.kind, "select", "parsed single-select prompt")
assert_eq(#parsed_single.options, 3, "parsed 3 single-select options")
assert_eq(parsed_single.initial_idx, 1, "detected initial cursor on option 1")
assert_true(parsed_single.options[3].is_other == true, "detected Other option")
local single_steps = approval.build_keystrokes(parsed_single, { type = "select", idx = 2 })
assert_eq(#single_steps, 2, "single-select option 2 sends Down + Enter")
assert_eq(single_steps[1].seq, "\27[B", "first keystroke is Down arrow")
assert_eq(single_steps[2].seq, "\r", "second keystroke is Enter")

local parsed_multi = approval.parse_prompt(table.concat({
  "Question 1/2",
  "Multi-select test (1/2): which checks should be included?",
  "Select all that apply",
  "  ❯ [ ] 1. Option A",
  "    [ ] 2. Option B",
  "    [ ] 3. Option C",
  "  Space to toggle · Enter to submit · Esc to cancel",
}, "\n"))
assert_eq(parsed_multi.kind, "multi_select", "parsed multi-select prompt")
assert_eq(parsed_multi.progress, "1/2", "parsed Question 1/2 progress badge")
assert_eq(#parsed_multi.options, 3, "parsed 3 multi-select options")
local multi_steps = approval.build_keystrokes(parsed_multi, { type = "multi_select", checked = { [1] = true, [3] = true } })
assert_eq(multi_steps[1].seq, " ", "toggles option 1 with Space")
assert_eq(multi_steps[2].seq, "\27[B", "moves down to option 2")
assert_eq(multi_steps[3].seq, "\27[B", "moves down to option 3")
assert_eq(multi_steps[4].seq, " ", "toggles option 3 with Space")
assert_eq(multi_steps[5].seq, "\r", "submits multi-select with Enter")

-- Rendered-screen TUI attention detection opens Neovim-style approval popup & auto-closes when cleared
local tui_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(tui_buf, 0, -1, false, {
  "Test popup question for super-harness.nvim:",
  "  ❯ 1. (Recommended) Popup appeared in Neovim style",
  "    2. Other",
  "  ↑/↓ navigate · Enter to select · Esc to cancel",
  "",
  "",
})
local tui_sess = {
  id = "antigravity#tui",
  bufnr = tui_buf,
  winid = nil,
  layout = "drawer",
  state = "thinking",
  adapter = agy_adapter,
}
assert_eq(nvim_term._check_rendered_screen(tui_sess), "awaiting_input", "detects ask_question from rendered buffer tail")
assert_eq(tui_sess.state, "awaiting_input", "transitions session state to awaiting_input")
assert_true(approval.is_open(), "auto-opened Neovim-style approval popup from rendered ask_question")
assert_true(not window.is_visible(tui_sess), "did not open raw harness terminal when attention_style == neovim")
approval.move(1)
assert_eq(approval._cursor, 2, "j/k move updates Neovim popup cursor")
-- Once user answers and prompt disappears from screen, state recovers & Neovim popup auto-closes
vim.api.nvim_buf_set_lines(tui_buf, 0, -1, false, { "Received your answer.", "Ready for next prompt." })
assert_eq(nvim_term._check_rendered_screen(tui_sess), nil, "clears awaiting_input when prompt leaves screen")
assert_eq(tui_sess.state, "thinking", "recovers state so future prompts can notify again")
assert_true(not approval.is_open(), "auto-closed Neovim approval popup when prompt left screen")
pcall(vim.api.nvim_buf_delete, tui_buf, { force = true })

sh.config.options.notifications.enabled = false

-- Composer @-token expansion, HUD, Review Drawer, Health
vim.cmd("edit " .. vim.fn.fnameescape(tmp))
local exp = input.expand_tokens("Fix @file and keep @mention", { adapter = adapters.get("claude"), bufnr = 0 })
assert_true(exp:find("@mention", 1, true) ~= nil, "unknown @mention preserved")

hud.open("sessions")
assert_true(hud._win ~= nil and vim.api.nvim_win_is_valid(hud._win), "HUD opened")
hud._tab = "tray"; hud.render()
hud._tab = "review"; hud.render()
hud.close()

diffsplit.open()
assert_true(diffsplit._win ~= nil and vim.api.nvim_win_is_valid(diffsplit._win), "Review drawer opened")
diffsplit.close()

-- Collapsible Q&A Transcript tests
local transcript = require("super_harness.ui.transcript")
local tmp_jsonl = vim.fn.tempname() .. ".jsonl"
vim.fn.writefile({
  vim.json.encode({
    type = "USER_INPUT",
    content = "<USER_REQUEST>\nHow do I fold Q&A turns?\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\ntime\n</ADDITIONAL_METADATA>",
    created_at = "2026-11-19T06:00:00Z",
  }),
  vim.json.encode({
    type = "PLANNER_RESPONSE",
    content = "Press <CR> or za to collapse and expand turns.",
    created_at = "2026-11-19T06:00:02Z",
  }),
  vim.json.encode({
    type = "USER_INPUT",
    content = "<USER_REQUEST>\nHow do I filter by topic?\n</USER_REQUEST>",
    created_at = "2026-11-19T06:01:00Z",
  }),
  vim.json.encode({
    type = "PLANNER_RESPONSE",
    content = "Press f and type a keyword to focus on related turns.",
    created_at = "2026-11-19T06:01:03Z",
  }),
}, tmp_jsonl)

local parsed_turns = transcript.parse_antigravity_jsonl(tmp_jsonl)
assert_eq(#parsed_turns, 2, "parsed 2 turns from Antigravity transcript.jsonl")
assert_eq(parsed_turns[1].question, "How do I fold Q&A turns?", "extracted clean USER_REQUEST 1")
assert_true(parsed_turns[1].answer:find("za", 1, true) ~= nil, "extracted PLANNER_RESPONSE 1")

transcript.open({ transcript_path = tmp_jsonl })
assert_true(transcript.is_open(), "Collapsible Q&A transcript window opened")
assert_eq(#transcript._visible_turns, 2, "2 visible turns rendered")

-- Collapse single turn
transcript.set_collapsed(1, true)
assert_true(transcript._visible_turns[1].collapsed == true, "turn 1 collapsed")
assert_true(transcript._visible_turns[2].collapsed == false, "turn 2 remains expanded")
local lines_after_collapse = vim.api.nvim_buf_get_lines(transcript._buf, 0, -1, false)
local joined_collapsed = table.concat(lines_after_collapse, "\n")
assert_true(joined_collapsed:find("▸ %[Q1%]") ~= nil, "collapsed turn 1 renders ▸ icon")
assert_true(joined_collapsed:find("▾ %[Q2%]") ~= nil, "expanded turn 2 renders ▾ icon")

-- Focus mode + pin
transcript.toggle_pin(1)
assert_true(transcript._visible_turns[1].pinned == true, "turn 1 pinned")
transcript.focus_turn(2)
assert_true(transcript._visible_turns[2].collapsed == false, "focused turn 2 expanded")
assert_true(transcript._visible_turns[1].collapsed == false, "pinned turn 1 stays expanded during focus")

-- Collapse all & expand all
transcript.collapse_all()
assert_true(transcript._visible_turns[2].collapsed == true, "unpinned turn 2 collapsed on collapse_all")
transcript.expand_all()
assert_true(transcript._visible_turns[1].collapsed == false and transcript._visible_turns[2].collapsed == false, "all turns expanded")

-- Keyword filter
transcript.set_filter("keyword")
assert_eq(#transcript._visible_turns, 1, "filter narrows to 1 matching turn")
assert_eq(transcript._visible_turns[1].id, 2, "matching turn is Q2")
transcript.set_filter(nil)
assert_eq(#transcript._visible_turns, 2, "clearing filter restores all turns")

transcript.close()
assert_true(not transcript.is_open(), "transcript closed cleanly")
vim.fn.delete(tmp_jsonl)

assert_true(pcall(health.check), "health.check passes")
assert_eq(vim.fn.exists(":SuperHarness"), 2, ":SuperHarness command exists")
assert_eq(vim.fn.exists(":SuperHarnessReload"), 2, ":SuperHarnessReload command exists")

-- Hot-reload test
local reloaded = sh.reload()
assert_true(reloaded._initialized == true, ":SuperHarnessReload re-initialized cleanly")

vim.fn.delete(tmp)
vim.fn.delete(hist_file)
print("🎉 ALL BACKENDS & UI TESTS PASSED!")
