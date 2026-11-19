local M = {
  name = "claude",
  aliases = { "claude-code" },
  label = "Claude Code",
  icon = "󱜙",
  cmd = { "claude" },
  bin = "claude",
  env = {},
  prompt_arg = "-p",
  resume_args = { "--resume" },
  continue_args = { "--continue" },
  model_flag = "--model",
  file_ref_style = "at",
  bracketed_paste = true,
  submit_seq = "\r",
  submit_delay_ms = 80,
  exit_action = "hide",
  slash_commands = { "/clear", "/compact", "/cost", "/model", "/plan", "/review", "/status", "/doctor" },
}

---@param text string
---@return string|nil
function M.status_detector(text)
  local lower = (text or ""):lower()
  if lower:find("do you want to") or lower:find("allow ") or lower:find("%(y/n%)") or lower:find("approve") then
    return "awaiting_input"
  end
  if lower:find("api error") or lower:find("error:") then
    return "errored"
  end
  if lower:find("bash%(") or lower:find("edit%(") or lower:find("read%(") or lower:find("write%(") then
    return "executing"
  end
  if lower:find("thinking") or lower:find("pondering") or lower:find("clauding") then
    return "thinking"
  end
  return nil
end

return M
