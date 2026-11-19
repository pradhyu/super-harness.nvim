local config = require("super_harness.config")
local state = require("super_harness.state")
local context = require("super_harness.context")
local review = require("super_harness.review")

local M = {}

local STATE_LABELS = {
  starting = "starting",
  idle = "idle",
  thinking = "thinking",
  executing = "exec",
  awaiting_input = "APPROVE",
  errored = "err",
  exited = "exited",
}

--- Return a compact statusline string for Lualine / Heirline / Mini.statusline
---@return string
function M.get()
  local active = state.get_active()
  if not active then
    return ""
  end

  local icons = config.options.ui.icons or {}
  local st_icon = icons[active.state] or "●"
  local st_text = STATE_LABELS[active.state] or active.state
  local parts = {
    string.format("%s %s %s %s", active.adapter.icon or icons.harness or "󰚩", active.id, st_icon, st_text),
  }

  local tray_n = #context.tray_list()
  if tray_n > 0 then
    table.insert(parts, string.format("%s%d", icons.tray or "T:", tray_n))
  end

  local comment_n = #review.list_comments()
  if comment_n > 0 then
    table.insert(parts, string.format("%s%d", icons.comment or "C:", comment_n))
  end

  return table.concat(parts, " ")
end

return M
