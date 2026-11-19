local M = {}

--- Additional built-in CLI agent presets beyond the core 4 adapters
M.presets = {
  codex = {
    name = "codex",
    label = "Codex CLI",
    icon = "󰧑",
    cmd = { "codex" },
    bin = "codex",
    resume_args = { "resume" },
    model_flag = "--model",
    file_ref_style = "at",
    bracketed_paste = true,
    submit_seq = "\r",
    submit_delay_ms = 60,
    exit_action = "hide",
    slash_commands = { "/model", "/approvals", "/compact", "/diff", "/status" },
  },
  gemini = {
    name = "gemini",
    label = "Gemini CLI",
    icon = "✦",
    cmd = { "gemini" },
    bin = "gemini",
    model_flag = "--model",
    file_ref_style = "at",
    bracketed_paste = true,
    submit_seq = "\r",
    submit_delay_ms = 50,
    exit_action = "hide",
    slash_commands = { "/clear", "/compress", "/memory", "/stats", "/tools" },
  },
  opencode = {
    name = "opencode",
    label = "OpenCode",
    icon = "󰅩",
    cmd = { "opencode" },
    bin = "opencode",
    continue_args = { "--continue" },
    model_flag = "--model",
    file_ref_style = "at",
    bracketed_paste = true,
    submit_seq = "\r",
    submit_delay_ms = 60,
    exit_action = "hide",
    slash_commands = { "/compact", "/models", "/new", "/sessions", "/share" },
  },
  amp = {
    name = "amp",
    label = "Sourcegraph Amp",
    icon = "⚡",
    cmd = { "amp" },
    bin = "amp",
    file_ref_style = "at",
    bracketed_paste = true,
    submit_seq = "\r",
    submit_delay_ms = 50,
    exit_action = "hide",
  },
  copilot = {
    name = "copilot",
    label = "GitHub Copilot CLI",
    icon = "",
    cmd = { "copilot" },
    bin = "copilot",
    file_ref_style = "at",
    bracketed_paste = true,
    submit_seq = "\r",
    submit_delay_ms = 50,
    exit_action = "hide",
  },
  kiro = {
    name = "kiro",
    label = "Kiro CLI",
    icon = "󱙺",
    cmd = { "kiro-cli", "chat" },
    bin = "kiro-cli",
    file_ref_style = "at",
    bracketed_paste = true,
    submit_seq = "\r",
    submit_delay_ms = 50,
    exit_action = "hide",
  },
  cursor = {
    name = "cursor",
    label = "Cursor Agent",
    icon = "󰇀",
    cmd = { "cursor-agent" },
    bin = "cursor-agent",
    file_ref_style = "at",
    bracketed_paste = true,
    submit_seq = "\r",
    submit_delay_ms = 50,
    exit_action = "hide",
  },
  cline = {
    name = "cline",
    label = "Cline CLI",
    icon = "󰘦",
    cmd = { "cline" },
    bin = "cline",
    file_ref_style = "at",
    bracketed_paste = true,
    submit_seq = "\r",
    submit_delay_ms = 50,
    exit_action = "hide",
  },
  pi = {
    name = "pi",
    label = "Pi Coding Agent",
    icon = "π",
    cmd = { "pi" },
    bin = "pi",
    file_ref_style = "at",
    bracketed_paste = true,
    submit_seq = "\r",
    submit_delay_ms = 50,
    exit_action = "hide",
  },
}

--- Generic fallback status detector
---@param text string
---@return string|nil
function M.default_status_detector(text)
  local lower = (text or ""):lower()
  if lower:find("%[y/n%]") or lower:find("%(y/n%)") or lower:find("approve") or lower:find("permission") then
    return "awaiting_input"
  end
  if lower:find("fatal:") or lower:find("unhandled exception") then
    return "errored"
  end
  return nil
end

--- Synthesize an ad-hoc adapter from any arbitrary command string or table
---@param name_or_cmd string|string[]
---@return table
function M.from_cmd(name_or_cmd)
  local parts
  if type(name_or_cmd) == "table" then
    parts = vim.deepcopy(name_or_cmd)
  else
    parts = vim.split(tostring(name_or_cmd), "%s+", { trimempty = true })
  end
  local bin = parts[1] or "sh"
  return {
    name = bin,
    label = bin,
    icon = "󰚩",
    cmd = parts,
    bin = bin,
    env = {},
    file_ref_style = "at",
    bracketed_paste = true,
    submit_seq = "\r",
    submit_delay_ms = 50,
    exit_action = "hide",
    status_detector = M.default_status_detector,
  }
end

return M
