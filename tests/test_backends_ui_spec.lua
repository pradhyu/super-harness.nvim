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

assert_true(pcall(health.check), "health.check passes")
assert_eq(vim.fn.exists(":SuperHarness"), 2, ":SuperHarness command exists")
assert_eq(vim.fn.exists(":SuperHarnessReload"), 2, ":SuperHarnessReload command exists")

-- Hot-reload test
local reloaded = sh.reload()
assert_true(reloaded._initialized == true, ":SuperHarnessReload re-initialized cleanly")

vim.fn.delete(tmp)
vim.fn.delete(hist_file)
print("🎉 ALL BACKENDS & UI TESTS PASSED!")
