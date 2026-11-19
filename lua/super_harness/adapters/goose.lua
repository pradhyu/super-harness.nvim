local M = {
  name = "goose",
  label = "Block Goose",
  icon = "󰇥",
  cmd = { "goose", "session" },
  bin = "goose",
  env = {},
  resume_args = { "-r" },
  file_ref_style = "at",
  bracketed_paste = true,
  submit_seq = "\r",
  submit_delay_ms = 50,
  exit_action = "hide",
  slash_commands = { "/exit", "/help", "/clear", "/mode" },
}

---@param text string
---@return string|nil
function M.status_detector(text)
  local lower = (text or ""):lower()
  if lower:find("confirm") or lower:find("%[y/n%]") then
    return "awaiting_input"
  end
  if lower:find("error:") then
    return "errored"
  end
  return nil
end

return M
