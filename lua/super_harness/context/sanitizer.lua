local config = require("super_harness.config")

local M = {}

--- Strip ANSI CSI/OSC escape sequences from terminal output
---@param text string
---@return string
function M.strip_ansi(text)
  if type(text) ~= "string" then
    return ""
  end
  local cleaned = text:gsub("\27%[[%d;?]*[ -/]*[@-~]", "")
  cleaned = cleaned:gsub("\27%][^\7\27]*[\7]", "")
  cleaned = cleaned:gsub("\27%][^\27]*\27\\", "")
  return cleaned
end

--- Wrap text in ANSI bracketed paste sequences
---@param text string
---@return string
function M.bracketed_paste(text)
  return "\27[200~" .. text .. "\27[201~"
end

--- Sanitize and encode text for safe PTY transmission
---@param adapter table
---@param text string
---@param opts? { submit?: boolean }
---@return { payload: string, submit_seq: string|nil, submit_delay_ms: integer }
function M.encode_input(adapter, text, opts)
  opts = opts or {}
  local normalized = (text or ""):gsub("\r\n", "\n")
  local is_multiline = normalized:find("\n", 1, true) ~= nil

  local use_bp = adapter.bracketed_paste
  if use_bp == nil then
    use_bp = config.options.context.bracketed_paste ~= false
  end

  local payload = normalized
  if is_multiline and use_bp then
    payload = M.bracketed_paste(normalized)
  end

  local should_submit = opts.submit
  if should_submit == nil then
    should_submit = config.options.session.auto_submit ~= false
  end

  return {
    payload = payload,
    submit_seq = should_submit and (adapter.submit_seq or "\r") or nil,
    submit_delay_ms = adapter.submit_delay_ms or 50,
  }
end

return M
