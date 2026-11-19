local config = require("super_harness.config")
local log = require("super_harness.utils.log")
local review = require("super_harness.review")
local sync = require("super_harness.sync")

local M = {}

M._buf = nil
M._win = nil
M._line_map = {}

--- Open a side-by-side diffsplit comparing pre-turn baseline (HEAD/snapshot) vs agent's disk file
---@param file_entry table
function M.open_file_diff(file_entry)
  local baseline = review.get_baseline_lines(file_entry.abs_path)
  local current = vim.fn.filereadable(file_entry.abs_path) == 1 and vim.fn.readfile(file_entry.abs_path) or {}

  vim.cmd("tabnew")
  local left = vim.api.nvim_get_current_buf()
  vim.bo[left].buftype = "nofile"
  vim.bo[left].bufhidden = "wipe"
  vim.bo[left].swapfile = false
  vim.api.nvim_buf_set_lines(left, 0, -1, false, baseline)
  pcall(vim.api.nvim_buf_set_name, left, "super_harness://baseline/" .. file_entry.rel_path)

  vim.cmd("vsplit")
  local right = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, right)
  vim.bo[right].buftype = "nofile"
  vim.bo[right].bufhidden = "wipe"
  vim.bo[right].swapfile = false
  vim.api.nvim_buf_set_lines(right, 0, -1, false, current)
  pcall(vim.api.nvim_buf_set_name, right, "super_harness://agent/" .. file_entry.rel_path)

  vim.cmd("windo diffthis")

  -- One-key review actions inside diff tab
  for _, b in ipairs({ left, right }) do
    local opts = { buffer = b, silent = true }
    vim.keymap.set("n", "q", "<cmd>tabclose<cr>", opts)
    vim.keymap.set("n", "a", function()
      review.accept_file(file_entry.rel_path, false)
      log.info("Accepted " .. file_entry.rel_path)
      pcall(vim.cmd, "tabclose")
    end, opts)
    vim.keymap.set("n", "r", function()
      local ok, err = review.revert_file(file_entry.abs_path)
      if ok then
        log.info("Reverted " .. file_entry.rel_path)
        pcall(vim.cmd, "tabclose")
      else
        log.warn(err or "Revert failed")
      end
    end, opts)
    vim.keymap.set("n", "e", function()
      pcall(vim.cmd, "tabclose")
      sync.open_file(file_entry.abs_path)
    end, opts)
  end
end

function M.close()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    pcall(vim.api.nvim_win_close, M._win, true)
  end
  M._win = nil
  if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
    pcall(vim.api.nvim_buf_delete, M._buf, { force = true })
  end
  M._buf = nil
  M._line_map = {}
end

function M.render()
  if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) then
    return
  end

  local files = review.get_changed_files()
  local comments = review.list_comments()
  local lines = {}
  M._line_map = {}

  table.insert(lines, "    SuperHarness Review & Diff Inspector")
  table.insert(lines, "  " .. string.rep("─", 70))
  table.insert(lines, "")
  table.insert(lines, string.format("  Modified Files (%d):", #files))

  if #files == 0 then
    table.insert(lines, "    (no modified files detected in workspace)")
  else
    for _, f in ipairs(files) do
      local check = f.accepted and "✓" or " "
      local stats = string.format("+%d -%d", f.added or 0, f.deleted or 0)
      table.insert(lines, string.format("  [%s] %-2s  %-48s  %s", check, f.status, log.truncate(f.rel_path, 48), stats))
      M._line_map[#lines] = { kind = "file", data = f }
    end
  end

  table.insert(lines, "")
  table.insert(lines, string.format("  Queued Review Comments (%d):", #comments))
  if #comments == 0 then
    table.insert(lines, "    (no review comments queued — press <leader>ac on code to add)")
  else
    for i, c in ipairs(comments) do
      local loc = string.format("%s:L%d-L%d", c.rel_path, c.start_line, c.end_line)
      table.insert(lines, string.format("  #%d  %-32s  %s", i, log.truncate(loc, 32), log.truncate(c.comment, 34)))
      M._line_map[#lines] = { kind = "comment", idx = i, data = c }
    end
  end

  table.insert(lines, "")
  table.insert(lines, "  " .. string.rep("─", 70))
  table.insert(lines, "  <CR>/e Edit | d Diff | a Accept | r Revert | A AcceptAll | R RevertAll | Q Quickfix | q Close")

  vim.bo[M._buf].modifiable = true
  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, lines)
  vim.bo[M._buf].modifiable = false
end

function M.open(on_dispatch_comments)
  M.close()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "super_harness_review"
  vim.b[buf].super_harness_buf = true
  M._buf = buf

  local cols = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = math.min(96, math.max(76, math.floor(cols * 0.74)))
  local height = math.min(34, math.max(16, math.floor(lines * 0.65)))

  M._win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((lines - height) / 2),
    col = math.floor((cols - width) / 2),
    style = "minimal",
    border = config.options.ui.float.border or "rounded",
    title = "  SuperHarness Review ",
    title_pos = "center",
  })
  vim.wo[M._win].cursorline = true
  M.render()

  local function current_entry()
    local row = vim.api.nvim_win_get_cursor(M._win)[1]
    return M._line_map[row]
  end

  local opts = { buffer = buf, silent = true }
  vim.keymap.set("n", "q", M.close, opts)
  vim.keymap.set("n", "<Esc>", M.close, opts)
  vim.keymap.set("n", "<CR>", function()
    local e = current_entry()
    if not e then return end
    M.close()
    if e.kind == "file" then
      sync.open_file(e.data.abs_path)
    elseif e.kind == "comment" and e.data.abs_path ~= "" then
      sync.open_file(e.data.abs_path, e.data.start_line, 1)
    end
  end, opts)
  vim.keymap.set("n", "e", function()
    local e = current_entry()
    if e and e.kind == "file" then
      M.close()
      sync.open_file(e.data.abs_path)
    end
  end, opts)
  vim.keymap.set("n", "d", function()
    local e = current_entry()
    if e and e.kind == "file" then
      M.close()
      M.open_file_diff(e.data)
    end
  end, opts)
  vim.keymap.set("n", "a", function()
    local e = current_entry()
    if e and e.kind == "file" then
      review.accept_file(e.data.rel_path)
      M.render()
    end
  end, opts)
  vim.keymap.set("n", "A", function()
    local n = review.accept_all()
    log.info("Accepted " .. n .. " changed file(s)")
    M.render()
  end, opts)
  vim.keymap.set("n", "r", function()
    local e = current_entry()
    if e and e.kind == "file" then
      local ok, err = review.revert_file(e.data.abs_path)
      if ok then log.info("Reverted " .. e.data.rel_path) else log.warn(err or "Revert failed") end
      M.render()
    end
  end, opts)
  vim.keymap.set("n", "R", function()
    local n = review.revert_all()
    log.info("Reverted " .. n .. " file(s)")
    M.render()
  end, opts)
  vim.keymap.set("n", "x", function()
    local e = current_entry()
    if e and e.kind == "comment" then
      review.remove_comment(e.idx)
      M.render()
    end
  end, opts)
  vim.keymap.set("n", "Q", function()
    M.close()
    require("super_harness.review.quickfix").populate(true)
  end, opts)
  vim.keymap.set("n", "S", function()
    if on_dispatch_comments then
      M.close()
      on_dispatch_comments()
    end
  end, opts)
end

return M
