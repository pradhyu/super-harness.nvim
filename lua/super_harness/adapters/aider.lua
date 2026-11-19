local M = {
  name = "aider",
  label = "Aider",
  icon = "󰒋",
  cmd = { "aider" },
  bin = "aider",
  env = {},
  prompt_arg = "--message",
  continue_args = { "--restore-chat-history" },
  model_flag = "--model",
  file_ref_style = "aider",
  bracketed_paste = false,
  submit_seq = "\r",
  submit_delay_ms = 30,
  exit_action = "hide",
  slash_commands = { "/add", "/drop", "/ask", "/architect", "/diff", "/undo", "/clear", "/tokens", "/map" },
}

---@param text string
---@return string|nil
function M.status_detector(text)
  local lower = (text or ""):lower()
  if lower:find("%(y%)es/%(n%)o") or lower:find("add .* to the chat%?") then
    return "awaiting_input"
  end
  if lower:find("traceback") or lower:find("error:") then
    return "errored"
  end
  if lower:find("applied edit to") or lower:find("running ") then
    return "executing"
  end
  return nil
end

return M
