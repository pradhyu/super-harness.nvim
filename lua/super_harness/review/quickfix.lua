local review = require("super_harness.review")
local log = require("super_harness.utils.log")

local M = {}

--- Populate Neovim quickfix list with all agent-modified files
---@param open_qf? boolean
---@param cwd? string
---@return integer count
function M.populate(open_qf, cwd)
  local files = review.get_changed_files(cwd)
  local items = {}
  for _, f in ipairs(files) do
    table.insert(items, {
      filename = f.abs_path,
      lnum = 1,
      col = 1,
      text = string.format("[%s] %s (+%d -%d)", f.status, f.rel_path, f.added or 0, f.deleted or 0),
    })
  end
  vim.fn.setqflist(items, "r")
  if open_qf and #items > 0 then
    vim.cmd("copen")
  elseif #items == 0 then
    log.info("No agent-modified files to populate in quickfix.")
  end
  return #items
end

function M.next_file()
  local ok = pcall(vim.cmd, "cnext")
  if not ok then
    pcall(vim.cmd, "cfirst")
  end
end

function M.prev_file()
  local ok = pcall(vim.cmd, "cprev")
  if not ok then
    pcall(vim.cmd, "clast")
  end
end

return M
