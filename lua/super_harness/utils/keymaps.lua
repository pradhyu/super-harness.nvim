local config = require("super_harness.config")

local M = {}

local function visual_range()
  local s = vim.fn.line("v")
  local e = vim.fn.line(".")
  return { start_line = math.min(s, e), end_line = math.max(s, e) }
end

local function visual_wrapper(fn)
  return function()
    local r = visual_range()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    vim.schedule(function()
      fn(r)
    end)
  end
end

--- Register ergonomic default keymaps from config.options.keymaps
---@param sh table Public super_harness API module
function M.setup(sh)
  if not config.options.default_keymaps then
    return
  end
  local km = config.options.keymaps or {}
  local function bind(modes, lhs, rhs, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set(modes, lhs, rhs, { silent = true, desc = "SuperHarness: " .. desc })
    end
  end

  bind({ "n", "t" }, km.toggle, function() sh.toggle() end, "Toggle Active Agent")
  bind({ "n", "t" }, km.toggle_float, function() sh.toggle(nil, { layout = "float" }) end, "Toggle Floating Agent")
  bind("n", km.new_session, function() sh.new_session() end, "New Named Agent Session")
  bind("n", km.select_session, function() sh.pick_session() end, "Select / Switch Session")
  bind("n", km.hud, function() sh.hud() end, "Control Center HUD")
  bind("n", km.qa_transcript, function() sh.transcript() end, "Collapsible Q&A Transcript")

  bind("n", km.compose, function() sh.compose() end, "Prompt Composer")
  bind("v", km.compose, visual_wrapper(function(r) sh.compose(r) end), "Compose with Selection")

  bind("n", km.send_selection, function() sh.send_context("scope") end, "Send Enclosing Scope / File")
  bind("v", km.send_selection, visual_wrapper(function(r) sh.send_context("selection", r) end), "Send Visual Selection")
  bind("n", km.send_file, function() sh.send_context("file") end, "Send Current File")
  bind("n", km.send_diagnostics, function() sh.send_context("diagnostics") end, "Send LSP Diagnostics")
  bind("n", km.send_diff, function() sh.send_context("diff") end, "Send Git Diff")

  bind("n", km.tray_stage, function() sh.tray_add_current() end, "Stage File to Context Tray")
  bind("v", km.tray_stage, visual_wrapper(function(r) sh.tray_add_current(r) end), "Stage Selection to Context Tray")
  bind("n", km.tray_open, function() sh.hud("tray") end, "Open Context Tray")

  bind("n", km.prompt_library, function() sh.pick_prompt() end, "Prompt Library")
  bind("v", km.prompt_library, visual_wrapper(function(r) sh.pick_prompt(r) end), "Prompt Library (Selection)")
  bind("n", km.prompt_history, function() sh.pick_history() end, "Prompt History (Frecency)")

  bind("n", km.broadcast, function() sh.broadcast() end, "Broadcast to All Sessions")
  bind("v", km.broadcast, visual_wrapper(function(r) sh.broadcast(r) end), "Broadcast Selection")

  bind("n", km.review_changes, function() sh.review() end, "Review Agent Changes")
  bind("n", km.add_comment, function() sh.add_comment() end, "Add Inline Review Comment")
  bind("v", km.add_comment, visual_wrapper(function(r) sh.add_comment(r) end), "Add Comment on Selection")
  bind("n", km.dispatch_comments, function() sh.dispatch_comments() end, "Dispatch Review Comments")

  bind("n", km.slash_commands, function() sh.pick_slash() end, "Agent Slash Commands")
  bind("n", km.resume, function() sh.resume() end, "Resume Previous Session")
  bind({ "n", "t" }, km.zoom, function() sh.zoom() end, "Toggle Fullscreen Zoom")
  bind("n", km.kill, function() sh.kill() end, "Kill Active Session")

  -- Quickfix changed-file navigation
  bind("n", "]f", function() sh.next_changed_file() end, "Next Changed File")
  bind("n", "[f", function() sh.prev_changed_file() end, "Prev Changed File")
end

return M
