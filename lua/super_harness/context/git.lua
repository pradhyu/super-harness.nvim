local log = require("super_harness.utils.log")

local M = {}

--- Find git repository root for a given path or cwd
---@param path? string
---@return string|nil
function M.git_root(path)
  local dir = path
  if dir and dir ~= "" then
    if vim.fn.filereadable(dir) == 1 then
      dir = vim.fn.fnamemodify(dir, ":h")
    end
  else
    dir = vim.fn.getcwd()
  end

  local stdout, code = log.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if code == 0 then
    local root = vim.trim(stdout)
    if root ~= "" then
      return root
    end
  end
  return nil
end

--- Return active git branch name
---@param cwd? string
---@return string|nil
function M.git_branch(cwd)
  local dir = cwd or vim.fn.getcwd()
  local stdout, code = log.system({ "git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD" })
  if code == 0 then
    local b = vim.trim(stdout)
    if b ~= "" then
      return b
    end
  end
  return nil
end

--- Resolve project root (git root else cwd)
---@param path? string
---@return string
function M.project_root(path)
  return M.git_root(path) or vim.fn.getcwd()
end

--- Convert absolute path to clean relative path from project root
---@param filepath string
---@param root? string
---@return string
function M.rel_path(filepath, root)
  if not filepath or filepath == "" then
    return ""
  end
  local abs = vim.fn.fnamemodify(filepath, ":p")
  local base = vim.fn.fnamemodify(root or M.project_root(abs), ":p")
  if not base:match("/$") then
    base = base .. "/"
  end
  if abs:sub(1, #base) == base then
    return abs:sub(#base + 1)
  end
  return vim.fn.fnamemodify(abs, ":~:.")
end

--- Collect git diff (unstaged or staged)
---@param opts? { staged?: boolean, cwd?: string }
---@return table|nil
function M.collect_diff(opts)
  opts = opts or {}
  local root = M.git_root(opts.cwd)
  if not root then
    return nil
  end
  local cmd = { "git", "-C", root, "diff" }
  if opts.staged then
    table.insert(cmd, "--cached")
  end
  local stdout, code = log.system(cmd)
  if code ~= 0 or vim.trim(stdout) == "" then
    return nil
  end
  local label = opts.staged and "Staged Git Diff" or "Unstaged Git Diff"
  local text = string.format("%s:\n```diff\n%s\n```", label, vim.trim(stdout))
  return {
    key = opts.staged and "git:staged" or "git:unstaged",
    kind = "git_diff",
    label = label,
    text = text,
    tokens = log.estimate_tokens(text),
  }
end

return M
