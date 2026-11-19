local log = require("super_harness.utils.log")
local git = require("super_harness.context.git")

local M = {}

local SEVERITY_NAMES = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

--- Collect LSP diagnostics for a buffer or entire workspace
---@param bufnr? integer
---@param opts? { workspace?: boolean, min_severity?: integer }
---@return table|nil
function M.collect_diagnostics(bufnr, opts)
  opts = opts or {}
  local target_buf = opts.workspace and nil or bufnr
  local diags = vim.diagnostic.get(target_buf)
  if opts.min_severity then
    diags = vim.tbl_filter(function(d)
      return d.severity <= opts.min_severity
    end, diags)
  end
  if #diags == 0 then
    return nil
  end

  local lines = { opts.workspace and "Workspace Diagnostics:" or "Diagnostics:" }
  for _, d in ipairs(diags) do
    local name = vim.api.nvim_buf_get_name(d.bufnr)
    local rel = name ~= "" and git.rel_path(name) or ("[Buffer #" .. d.bufnr .. "]")
    local sev = SEVERITY_NAMES[d.severity] or "DIAG"
    local src = d.source and (" [" .. d.source .. "]") or ""
    local code = d.code and (" (" .. tostring(d.code) .. ")") or ""
    local msg = (d.message or ""):gsub("\n", " ")
    table.insert(lines, string.format("- %s:%d:%d %s%s%s: %s", rel, d.lnum + 1, d.col + 1, sev, src, code, msg))
  end

  local text = table.concat(lines, "\n")
  return {
    key = "diagnostics:" .. (opts.workspace and "workspace" or tostring(target_buf)),
    kind = "diagnostics",
    label = string.format("Diagnostics (%s): %d", opts.workspace and "workspace" or "buffer", #diags),
    text = text,
    tokens = log.estimate_tokens(text),
  }
end

--- Collect current quickfix list items
---@return table|nil
function M.collect_quickfix()
  local qf = vim.fn.getqflist()
  if not qf or #qf == 0 then
    return nil
  end
  local lines = { "Quickfix List:" }
  for _, item in ipairs(qf) do
    local fname = item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_get_name(item.bufnr) or ""
    local rel = fname ~= "" and git.rel_path(fname) or ""
    local loc = rel ~= "" and string.format("%s:%d:%d ", rel, item.lnum or 0, item.col or 0) or ""
    table.insert(lines, "- " .. loc .. vim.trim(item.text or ""))
  end
  local text = table.concat(lines, "\n")
  return {
    key = "quickfix:all",
    kind = "quickfix",
    label = string.format("Quickfix (%d items)", #qf),
    text = text,
    tokens = log.estimate_tokens(text),
  }
end

return M
