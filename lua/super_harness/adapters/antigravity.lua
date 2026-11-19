local M = {
  name = "antigravity",
  aliases = { "agy" },
  label = "Google Antigravity",
  icon = "󰚩",
  cmd = { "agy" },
  bin = "agy",
  env = {},
  prompt_arg = nil,
  file_ref_style = "at",
  bracketed_paste = true,
  submit_seq = "\r",
  submit_delay_ms = 50,
  exit_action = "hide",
  slash_commands = { "/goal", "/plan", "/compact", "/teamwork", "/boost", "/grill-me", "/schedule", "/learn" },
}

--- Pattern-based agent state detector from stripped terminal output
---@param text string
---@return string|nil
function M.status_detector(text)
  local lower = (text or ""):lower()
  local has_nav_hint = lower:find("enter to select", 1, true) ~= nil
    or lower:find("enter to submit", 1, true) ~= nil
    or lower:find("enter to confirm", 1, true) ~= nil
    or lower:find("enter to continue", 1, true) ~= nil
    or lower:find("space to toggle", 1, true) ~= nil
    or lower:find("space to select", 1, true) ~= nil
    or lower:find("esc to cancel", 1, true) ~= nil
    or lower:find("esc to dismiss", 1, true) ~= nil
    or lower:find("esc to skip", 1, true) ~= nil
    or (
      (lower:find("↑", 1, true) or lower:find("↓", 1, true) or lower:find("j/k", 1, true))
      and (
        lower:find("enter", 1, true)
        or lower:find("select", 1, true)
        or lower:find("navigate", 1, true)
        or lower:find("submit", 1, true)
        or lower:find("cancel", 1, true)
      )
    )

  local has_explicit_confirm = lower:find("%[y/n%]") ~= nil
    or lower:find("%(y/n%)") ~= nil
    or lower:find("press enter to", 1, true) ~= nil
    or lower:find("press any key", 1, true) ~= nil
    or (lower:find("always allow", 1, true) ~= nil and (lower:find("deny", 1, true) ~= nil or lower:find("allow once", 1, true) ~= nil))
    or (lower:find("allow once", 1, true) ~= nil and lower:find("deny", 1, true) ~= nil)
    or (lower:find("bypass sandbox", 1, true) ~= nil and (lower:find("allow", 1, true) ~= nil or lower:find("deny", 1, true) ~= nil))

  local has_question_ui = (
      lower:find("question %d+/%d+") ~= nil
      or lower:find("question %d+ of %d+") ~= nil
      or lower:find("select all that apply", 1, true) ~= nil
      or lower:find("select an option", 1, true) ~= nil
      or lower:find("choose an option", 1, true) ~= nil
    )
    and (
      has_nav_hint
      or lower:find("❯", 1, true) ~= nil
      or lower:find("%[ %]") ~= nil
      or lower:find("1%.") ~= nil
    )

  if has_nav_hint or has_explicit_confirm or has_question_ui then
    return "awaiting_input"
  end
  if lower:find("error:", 1, true) or lower:find("fatal:", 1, true) or lower:find("traceback", 1, true) then
    return "errored"
  end
  if lower:find("running ", 1, true) or lower:find("executing ", 1, true) or lower:find("editing ", 1, true) or lower:find("tool:", 1, true) then
    return "executing"
  end
  if lower:find("thinking", 1, true) or lower:find("analyzing", 1, true) or lower:find("planning", 1, true) then
    return "thinking"
  end
  return nil
end

return M
