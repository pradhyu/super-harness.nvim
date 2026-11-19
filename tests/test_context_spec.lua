local sh = require("super_harness")
local context = require("super_harness.context")
local adapters = require("super_harness.adapters")

local function assert_true(c, m) if not c then error("FAIL: " .. (m or "")) end end
local function assert_eq(a, b, m) if a ~= b then error(string.format("FAIL: expected %s got %s (%s)", tostring(b), tostring(a), m or "")) end end

local hist_file = vim.fn.tempname() .. "_hist.json"
sh.setup({ project_config = false, sync = { fs_watch = false }, prompts = { history_file = hist_file } })

local tmp = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "local function sum(a, b)", "  return a + b", "end", "", "return sum" }, tmp)
vim.cmd("edit " .. vim.fn.fnameescape(tmp))
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = "lua"

local f = context.collect_file(buf, { ref_only = true })
assert_true(f ~= nil and f.ref_only == true, "collect_file ref_only")
local sel = context.collect_selection(buf, 1, 3)
assert_true(sel ~= nil and sel.content:find("a + b", 1, true) ~= nil, "collect_selection")
local sc = context.collect_scope(buf, 2)
assert_true(sc ~= nil and sc.kind == "scope", "collect_scope")

local ns = vim.api.nvim_create_namespace("sh_test_diag")
vim.diagnostic.set(ns, buf, { { lnum = 1, col = 0, severity = vim.diagnostic.severity.ERROR, message = "bad var" } })
local diag = context.collect_diagnostics(buf)
assert_true(diag ~= nil and diag.text:find("bad var", 1, true) ~= nil, "collect_diagnostics")
vim.diagnostic.reset(ns, buf)

-- Context Tray
context.tray_clear()
context.tray_add(f)
context.tray_add(f)
assert_eq(#context.tray_list(), 1, "tray deduplicates")
context.tray_add(sel)
assert_eq(#context.tray_list(), 2, "tray has 2 items")
assert_true(context.tray_tokens() > 0, "tray tokens > 0")
local fmt = context.tray_format(adapters.get("claude"), "Review")
assert_true(fmt:find("Review", 1, true) ~= nil, "tray_format includes prompt")
context.tray_clear()

-- Prompt templates & frecency history
local rendered = context.render_template("Explain {file}", { bufnr = buf })
assert_true(rendered:find("Explain @", 1, true) ~= nil, "template rendered")
context.record_history("First prompt", "claude")
context.record_history("Hot prompt", "antigravity")
context.record_history("Hot prompt", "antigravity")
context.history = {}
context._history_loaded = false
local h = context.get_history()
assert_eq(h[1].prompt, "Hot prompt", "frecency ranks top prompt #1")

vim.fn.delete(tmp)
vim.fn.delete(hist_file)
print("🎉 ALL CONTEXT TESTS PASSED!")
