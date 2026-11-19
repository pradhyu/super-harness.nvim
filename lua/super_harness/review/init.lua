local log = require("super_harness.utils.log")
local git = require("super_harness.context.git")
local adapters = require("super_harness.adapters")

local M = {}

---@type table<string, string[]> Snapshot of file contents before agent turn (abs_path -> lines)
M.snapshots = {}
---@type table<string, boolean>
M.accepted = {}
---@type table[]
M.comments = {}
M._comment_seq = 0
M._baseline_time = nil

--- Capture pre-turn snapshots for open file buffers
---@param cwd? string
function M.mark_baseline(cwd)
  M._baseline_time = os.time()
  M.accepted = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and log.is_code_buffer(buf) then
      local path = vim.api.nvim_buf_get_name(buf)
      if path ~= "" and vim.fn.filereadable(path) == 1 and not M.snapshots[path] then
        M.snapshots[path] = vim.fn.readfile(path)
      end
    end
  end
end

--- List all changed files (git status + diff numstat, or snapshot fallback)
---@param cwd? string
---@return table[]
function M.get_changed_files(cwd)
  local root = git.git_root(cwd)
  local files = {}

  if root then
    local status_out, code = log.system({ "git", "-C", root, "status", "--porcelain" })
    if code ~= 0 then
      return {}
    end

    local stats = {}
    local num_out, ncode = log.system({ "git", "-C", root, "diff", "--numstat" })
    if ncode == 0 then
      for line in num_out:gmatch("[^\r\n]+") do
        local added, deleted, fpath = line:match("^(%d+)%s+(%d+)%s+(.+)$")
        if fpath then
          stats[fpath] = { added = tonumber(added) or 0, deleted = tonumber(deleted) or 0 }
        end
      end
    end

    for line in status_out:gmatch("[^\r\n]+") do
      local xy = line:sub(1, 2)
      local rel = vim.trim(line:sub(4))
      local renamed = rel:match("->%s+(.+)$")
      if renamed then
        rel = renamed
      end
      if rel ~= "" then
        local abs = root .. "/" .. rel
        local st = stats[rel] or { added = 0, deleted = 0 }
        table.insert(files, {
          status = vim.trim(xy) ~= "" and vim.trim(xy) or "M",
          rel_path = rel,
          abs_path = abs,
          added = st.added,
          deleted = st.deleted,
          accepted = M.accepted[rel] == true or M.accepted[abs] == true,
        })
      end
    end
    return files
  end

  -- Snapshot fallback for non-git workspaces
  for abs, old_lines in pairs(M.snapshots) do
    if vim.fn.filereadable(abs) == 1 then
      local cur = vim.fn.readfile(abs)
      if table.concat(cur, "\n") ~= table.concat(old_lines, "\n") then
        local rel = git.rel_path(abs)
        table.insert(files, {
          status = "M",
          rel_path = rel,
          abs_path = abs,
          added = math.max(0, #cur - #old_lines),
          deleted = math.max(0, #old_lines - #cur),
          accepted = M.accepted[rel] == true or M.accepted[abs] == true,
        })
      end
    end
  end
  table.sort(files, function(a, b)
    return a.rel_path < b.rel_path
  end)
  return files
end

--- Get baseline lines for a file (git HEAD, else snapshot)
---@param abs_path string
---@param cwd? string
---@return string[]
function M.get_baseline_lines(abs_path, cwd)
  local root = git.git_root(cwd or abs_path)
  if root then
    local rel = git.rel_path(abs_path, root)
    local out, code = log.system({ "git", "-C", root, "show", "HEAD:" .. rel })
    if code == 0 then
      return vim.split(out, "\n", { plain = true })
    end
  end
  if M.snapshots[abs_path] then
    return vim.deepcopy(M.snapshots[abs_path])
  end
  return {}
end

--- Accept/stage a changed file
---@param path string
---@param stage_git? boolean
function M.accept_file(path, stage_git)
  M.accepted[path] = true
  if stage_git then
    local root = git.git_root(path)
    if root then
      log.system({ "git", "-C", root, "add", "--", git.rel_path(path, root) })
    end
  end
end

--- Accept all changed files in current turn
---@param cwd? string
---@param stage_git? boolean
---@return integer count
function M.accept_all(cwd, stage_git)
  local files = M.get_changed_files(cwd)
  for _, f in ipairs(files) do
    M.accept_file(f.rel_path, stage_git)
  end
  return #files
end

--- Revert a changed file to git HEAD or snapshot
---@param abs_path string
---@param cwd? string
---@return boolean, string|nil
function M.revert_file(abs_path, cwd)
  local root = git.git_root(cwd or abs_path)
  if root then
    local rel = git.rel_path(abs_path, root)
    local _, code = log.system({ "git", "-C", root, "checkout", "--", rel })
    if code == 0 then
      M.accepted[rel] = nil
      M.accepted[abs_path] = nil
      pcall(vim.cmd, "silent! checktime")
      return true, nil
    end
  end

  if M.snapshots[abs_path] then
    local ok = pcall(vim.fn.writefile, M.snapshots[abs_path], abs_path)
    if ok then
      M.accepted[abs_path] = nil
      pcall(vim.cmd, "silent! checktime")
      return true, nil
    end
  end

  return false, "No baseline or snapshot available for " .. tostring(abs_path)
end

--- Revert all changed files from current turn
---@param cwd? string
---@return integer reverted_count
function M.revert_all(cwd)
  local files = M.get_changed_files(cwd)
  local count = 0
  for _, f in ipairs(files) do
    if M.revert_file(f.abs_path, cwd) then
      count = count + 1
    end
  end
  return count
end

-- =============================================================================
-- PR-Style Inline Review Comments Queue
-- =============================================================================

function M.add_comment(bufnr, start_line, end_line, comment_text)
  if not comment_text or vim.trim(comment_text) == "" then
    return nil
  end
  local abs = vim.api.nvim_buf_get_name(bufnr)
  local rel = abs ~= "" and git.rel_path(abs) or ("[Buffer #" .. bufnr .. "]")
  local total = vim.api.nvim_buf_line_count(bufnr)
  start_line = math.max(1, math.min(start_line or 1, total))
  end_line = math.max(start_line, math.min(end_line or start_line, total))
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

  M._comment_seq = M._comment_seq + 1
  local entry = {
    id = M._comment_seq,
    rel_path = rel,
    abs_path = abs,
    start_line = start_line,
    end_line = end_line,
    snippet = table.concat(lines, "\n"),
    comment = vim.trim(comment_text),
    created_at = os.time(),
  }
  table.insert(M.comments, entry)
  return entry
end

function M.list_comments()
  return M.comments
end

function M.remove_comment(idx)
  if M.comments[idx] then
    table.remove(M.comments, idx)
    return true
  end
  return false
end

function M.clear_comments()
  M.comments = {}
end

function M.format_comments_payload(adapter)
  if #M.comments == 0 then
    return ""
  end
  adapter = adapter or adapters.resolve_default()
  local blocks = { "Please address the following code review comments:" }
  for i, c in ipairs(M.comments) do
    local ref = adapters.format_file_ref(adapter, c.rel_path, c.start_line, c.end_line)
    local block = string.format("%d. %s\n   Comment: %s", i, ref, c.comment)
    if c.snippet and vim.trim(c.snippet) ~= "" then
      block = block .. "\n   ```\n" .. c.snippet .. "\n   ```"
    end
    table.insert(blocks, block)
  end
  return table.concat(blocks, "\n\n")
end

return M
