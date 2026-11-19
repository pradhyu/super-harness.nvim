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
  if
    lower:find("approve")
    or lower:find("permission")
    or lower:find("always allow")
    or lower:find("allow once")
    or lower:find("bypass sandbox")
    or lower:find("waiting for")
    or lower:find("press enter")
    or lower:find("confirm")
    or lower:find("%[y/n%]")
    or lower:find("proceed%?")
  then
    return "awaiting_input"
  end
  if lower:find("error:") or lower:find("fatal:") or lower:find("traceback") then
    return "errored"
  end
  if lower:find("running ") or lower:find("executing ") or lower:find("editing ") or lower:find("tool:") then
    return "executing"
  end
  if lower:find("thinking") or lower:find("analyzing") or lower:find("planning") then
    return "thinking"
  end
  return nil
end

return M
