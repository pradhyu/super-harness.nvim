local config = require("super_harness.config")
local log = require("super_harness.utils.log")
local git = require("super_harness.context.git")

local M = {}

M._last_flush_time = nil

--- Pre-prompt auto-flush: safely save modified file-backed buffers before agent runs
---@return integer saved_count
function M.flush_modified()
  if not config.options.sync.auto_save_on_send then
    return 0
  end
  local saved = 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and log.is_code_buffer(buf) and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.bo[buf].modifiable and not vim.bo[buf].readonly then
        local ok = pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd("silent! update")
        end)
        if ok then
          saved = saved + 1
        end
      end
    end
  end
  M._last_flush_time = os.time()
  return saved
end

--- Open a side-by-side conflict resolution diff (unsaved buffer vs new disk file)
---@param bufnr integer
function M.open_conflict_diff(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" or vim.fn.filereadable(path) ~= 1 then
    return
  end
  local disk_lines = vim.fn.readfile(path)
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ft = vim.bo[bufnr].filetype

  vim.cmd("tabnew")
  local left = vim.api.nvim_get_current_buf()
  vim.bo[left].buftype = "nofile"
  vim.bo[left].bufhidden = "wipe"
  vim.bo[left].filetype = ft
  vim.api.nvim_buf_set_lines(left, 0, -1, false, buf_lines)
  pcall(vim.api.nvim_buf_set_name, left, "super_harness://unsaved/" .. git.rel_path(path))

  vim.cmd("vsplit")
  local right = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, right)
  vim.bo[right].buftype = "nofile"
  vim.bo[right].bufhidden = "wipe"
  vim.bo[right].filetype = ft
  vim.api.nvim_buf_set_lines(right, 0, -1, false, disk_lines)
  pcall(vim.api.nvim_buf_set_name, right, "super_harness://disk/" .. git.rel_path(path))

  vim.cmd("windo diffthis")
end

--- Safely reload unmodified buffers while preserving cursor/view/folds, and guard unsaved conflicts
function M.check_and_reload()
  if not config.options.sync.silent_autoread then
    return
  end

  -- Save views of visible code windows so reload preserves cursor & folds
  local saved_views = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(win)
    if log.is_code_buffer(b) then
      local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
      if ok and view then
        saved_views[win] = view
      end
    end
  end

  -- Check for unsaved conflicts before checktime
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and log.is_code_buffer(buf) and vim.bo[buf].modified then
      local path = vim.api.nvim_buf_get_name(buf)
      if path ~= "" and vim.fn.filereadable(path) == 1 then
        local mtime = vim.fn.getftime(path)
        if M._last_flush_time and mtime > M._last_flush_time then
          local rel = git.rel_path(path)
          local action = config.options.sync.conflict_action or "diff"
          log.warn("Buffer Sync Shield: '" .. rel .. "' changed on disk while buffer has unsaved edits.")
          if action == "diff" then
            M.open_conflict_diff(buf)
          end
        end
      end
    end
  end

  pcall(vim.cmd, "silent! checktime")

  -- Restore cursor & fold views
  for win, view in pairs(saved_views) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_call, win, function()
        vim.fn.winrestview(view)
      end)
    end
  end
end

return M
