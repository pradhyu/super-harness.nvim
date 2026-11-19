local sh = require("super_harness")
local sync = require("super_harness.sync")
local watcher = require("super_harness.sync.watcher")
local review = require("super_harness.review")
local quickfix = require("super_harness.review.quickfix")
local adapters = require("super_harness.adapters")

local function assert_true(c, m) if not c then error("FAIL: " .. (m or "")) end end
local function assert_eq(a, b, m) if a ~= b then error(string.format("FAIL: expected %s got %s (%s)", tostring(b), tostring(a), m or "")) end end

sh.setup({ project_config = false })

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local tmpfile = tmpdir .. "/app.lua"
vim.fn.writefile({ "local v = 1", "return v" }, tmpfile)
vim.cmd("edit " .. vim.fn.fnameescape(tmpfile))
local buf = vim.api.nvim_get_current_buf()

-- libuv watcher start & stop
assert_true(sync.watch_project(tmpdir), "uv.fs_event watcher started")
assert_true(#watcher.list() >= 1, "watcher registered")
watcher.stop_all()
assert_eq(#watcher.list(), 0, "watcher stopped cleanly")

-- Pre-prompt flush
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "local v = 2" })
assert_true(vim.bo[buf].modified, "buffer marked modified")
local saved = sync.flush_modified()
assert_eq(saved, 1, "pre-prompt auto-flush saved 1 buffer")
assert_true(not vim.bo[buf].modified, "buffer no longer modified after flush")

-- Review baseline, change detection, quickfix, revert
review.snapshots = {}
review.accepted = {}
review.mark_baseline(tmpdir)
vim.fn.writefile({ "local v = 999", "return v" }, tmpfile)

local changed = review.get_changed_files(tmpdir)
assert_eq(#changed, 1, "1 changed file detected")
assert_eq(quickfix.populate(false, tmpdir), 1, "quickfix populated with 1 file")

review.accept_file(changed[1].rel_path)
assert_true(review.get_changed_files(tmpdir)[1].accepted == true, "file marked accepted")

assert_true(review.revert_file(tmpfile, tmpdir), "revert restored baseline")
assert_eq(vim.fn.readfile(tmpfile)[1], "local v = 2", "line 1 restored to pre-turn flushed state")

-- PR-style inline review comments
review.clear_comments()
review.add_comment(buf, 1, 2, "Rename v to count")
local payload = review.format_comments_payload(adapters.get("claude"))
assert_true(payload:find("Rename v to count", 1, true) ~= nil, "comment formatted")
review.clear_comments()

-- RPC bridge env, bundled nvim-cli PATH injection & harness_neovim integration
assert_true(type(_G.SuperHarnessBridge) == "table", "_G.SuperHarnessBridge exists")
assert_true(sh.cli ~= nil and type(sh.cli.api) == "table", "bundled harness_neovim API exposed on sh.cli")
assert_eq(vim.fn.exists(":NvimCLI"), 2, ":NvimCLI command registered by bundled RPC layer")
local bin_dir = sync.get_bin_dir()
assert_true(bin_dir ~= nil and vim.fn.executable(bin_dir .. "/nvim-cli") == 1, "bundled bin/nvim-cli is executable")
local orig_path = vim.env.PATH
vim.env.PATH = "/usr/bin:/bin"
local env = sync.env_for_session({ id = "antigravity#1", adapter = "antigravity", cwd = tmpdir })
vim.env.PATH = orig_path
assert_eq(env.SUPER_HARNESS_ID, "antigravity#1", "env SUPER_HARNESS_ID set")
assert_eq(env.NVIM_LISTEN_ADDRESS, nil, "NVIM_LISTEN_ADDRESS not injected (avoids nvim -l socket collision)")
assert_true(env.PATH ~= nil and env.PATH:find(bin_dir, 1, true) ~= nil, "bundled bin/ prepended to session PATH")

vim.fn.delete(tmpdir, "rf")
print("🎉 ALL SYNC & REVIEW TESTS PASSED!")
