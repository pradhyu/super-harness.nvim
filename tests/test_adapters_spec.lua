local sh = require("super_harness")
local adapters = require("super_harness.adapters")
local sanitizer = require("super_harness.context.sanitizer")

local function assert_true(c, m) if not c then error("FAIL: " .. (m or "")) end end
local function assert_eq(a, b, m) if a ~= b then error(string.format("FAIL: expected %s got %s (%s)", tostring(b), tostring(a), m or "")) end end

sh.setup({ project_config = false, sync = { fs_watch = false } })

local all = adapters.all()
for _, name in ipairs({ "antigravity", "claude", "aider", "goose", "codex", "gemini", "opencode", "amp", "copilot", "kiro", "cursor", "cline", "pi" }) do
  assert_true(all[name] ~= nil, "Missing adapter: " .. name)
end

-- Alias lookup
local agy = adapters.get("agy")
assert_true(agy ~= nil and agy.name == "antigravity", "agy alias resolves to antigravity")

-- Status detector
local claude = adapters.get("claude")
assert_eq(claude.status_detector("Do you want to allow Bash(rm)?"), "awaiting_input", "claude approval detected")
assert_eq(claude.status_detector("Bash(git status)"), "executing", "claude tool exec detected")
assert_eq(agy.status_detector("Thinking about architecture..."), "thinking", "antigravity thinking detected")

-- Build cmd & file refs
local cmd = adapters.build_cmd(claude, { resume = true, model = "opus", extra_args = { "--verbose" } })
assert_eq(table.concat(cmd, " "), "claude --resume --model opus --verbose", "build_cmd matches")
assert_eq(adapters.format_file_ref(claude, "lua/a.lua", 3, 9), "@lua/a.lua:L3-L9", "claude range ref")
assert_eq(adapters.format_file_ref(adapters.get("aider"), "lua/a.lua"), "/add lua/a.lua", "aider file ref")

-- Bracketed paste encoding
local enc = sanitizer.encode_input(claude, "a\nb", { submit = true })
assert_eq(enc.payload, "\27[200~a\nb\27[201~", "multiline bracketed paste")
assert_eq(enc.submit_seq, "\r", "submit_seq set")
assert_eq(enc.submit_delay_ms, 80, "claude submit_delay_ms")

print("🎉 ALL ADAPTERS TESTS PASSED!")
