local M = {}

local SCOPE_NODE_TYPES = {
  function_declaration = true,
  function_definition = true,
  function_item = true,
  local_function = true,
  method_declaration = true,
  method_definition = true,
  arrow_function = true,
  class_declaration = true,
  class_definition = true,
  struct_item = true,
  impl_item = true,
  interface_declaration = true,
}

--- Return enclosing Treesitter AST node line range (1-indexed start, end), with paragraph fallback
---@param bufnr integer
---@param row integer 1-indexed cursor row
---@return integer start_line, integer end_line
function M.get_enclosing_range(bufnr, row)
  local ok_ts, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { math.max(0, row - 1), 0 } })
  if ok_ts and node then
    local curr = node
    while curr do
      local ntype = curr:type()
      if SCOPE_NODE_TYPES[ntype] or ntype:find("function") or ntype:find("method") or ntype:find("class") then
        local sr, _, er, _ = curr:range()
        return sr + 1, er + 1
      end
      curr = curr:parent()
    end
  end

  -- Graceful non-TS fallback: enclosing non-blank paragraph
  local total = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, total, false)
  local s = math.max(1, math.min(row, total))
  local e = s
  while s > 1 and vim.trim(lines[s - 1] or "") ~= "" do
    s = s - 1
  end
  while e < total and vim.trim(lines[e + 1] or "") ~= "" do
    e = e + 1
  end
  return s, e
end

return M
