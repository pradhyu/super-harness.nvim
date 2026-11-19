local config = require("super_harness.config")
local state = require("super_harness.state")
local log = require("super_harness.utils.log")
local sync = require("super_harness.sync")

local M = {}

--- Compute floating window geometry
---@param fullscreen? boolean
---@return table
function M.float_config(fullscreen)
  local cols = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  if fullscreen then
    return {
      relative = "editor",
      width = math.max(20, cols),
      height = math.max(5, lines - 1),
      row = 0,
      col = 0,
      style = "minimal",
      border = "none",
    }
  end
  local fc = config.options.ui.float or {}
  local w = math.max(30, math.floor(cols * (fc.width or 0.85)))
  local h = math.max(10, math.floor(lines * (fc.height or 0.85)))
  return {
    relative = "editor",
    width = w,
    height = h,
    row = math.floor((lines - h) / 2),
    col = math.floor((cols - w) / 2),
    style = "minimal",
    border = fc.border or "rounded",
  }
end

--- Open a window for a harness buffer according to layout ("drawer"|"bottom"|"float"|"tab"|"background")
---@param bufnr integer
---@param layout string
---@param title? string
---@return integer|nil winid
function M.open(bufnr, layout, title)
  layout = layout or config.options.ui.layout or "drawer"
  if layout == "background" or layout == "detached" then
    return nil
  end

  local winid
  if layout == "float" then
    local cfg = M.float_config(false)
    if title and title ~= "" then
      cfg.title = " " .. title .. " "
      cfg.title_pos = "center"
    end
    winid = vim.api.nvim_open_win(bufnr, true, cfg)
    if config.options.ui.winblend and config.options.ui.winblend > 0 then
      vim.wo[winid].winblend = config.options.ui.winblend
    end
  elseif layout == "bottom" or layout == "horizontal" then
    local h = math.max(8, math.floor(vim.o.lines * ((config.options.ui.bottom or {}).height or 0.35)))
    vim.cmd("botright " .. h .. "split")
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
  elseif layout == "tab" then
    vim.cmd("tabnew")
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
  else
    -- "drawer" (or "vertical")
    local dc = config.options.ui.drawer or {}
    local w = math.max(35, math.floor(vim.o.columns * (dc.width or 0.40)))
    local side = dc.position == "left" and "topleft" or "botright"
    vim.cmd(side .. " " .. w .. "vsplit")
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
  end

  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  pcall(function()
    vim.wo[winid].winfixbuf = true
  end)
  return winid
end

--- Check if a session's window is currently visible
---@param sess SuperHarnessSession
---@return boolean
function M.is_visible(sess)
  if not sess or not sess.winid or not vim.api.nvim_win_is_valid(sess.winid) then
    return false
  end
  return vim.api.nvim_win_get_buf(sess.winid) == sess.bufnr
end

--- Hide a session window without killing its background PTY
---@param sess SuperHarnessSession
---@return boolean
function M.hide(sess)
  if not sess then
    return false
  end
  if sess.winid and vim.api.nvim_win_is_valid(sess.winid) then
    if #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, sess.winid, false)
    else
      vim.cmd("enew")
    end
  end
  sess.winid = nil
  sess.zoomed = false
  return true
end

--- Toggle fullscreen zoom on a session window
---@param sess SuperHarnessSession
---@return boolean
function M.zoom(sess)
  if not sess or not sess.winid or not vim.api.nvim_win_is_valid(sess.winid) then
    return false
  end

  if sess.layout == "float" then
    sess.zoomed = not sess.zoomed
    local cfg = M.float_config(sess.zoomed)
    if not sess.zoomed then
      cfg.title = string.format(" %s %s (%s) ", sess.adapter.icon or "󰚩", sess.adapter.label, sess.id)
      cfg.title_pos = "center"
    end
    pcall(vim.api.nvim_win_set_config, sess.winid, cfg)
    return true
  end

  vim.api.nvim_set_current_win(sess.winid)
  if not sess.zoomed then
    sess.saved_layout_dims = {
      width = vim.api.nvim_win_get_width(sess.winid),
      height = vim.api.nvim_win_get_height(sess.winid),
    }
    pcall(vim.cmd, "wincmd _ | wincmd |")
    sess.zoomed = true
  else
    pcall(vim.cmd, "wincmd =")
    if sess.saved_layout_dims then
      pcall(vim.api.nvim_win_set_width, sess.winid, sess.saved_layout_dims.width)
      pcall(vim.api.nvim_win_set_height, sess.winid, sess.saved_layout_dims.height)
    end
    sess.zoomed = false
  end
  return true
end

--- Parse a single token (file[:line[:col]], file:start-end, file#L10-L20, file:// URI, markdown link)
---@param token string
---@param cwd string
---@return string|nil path, integer|nil lnum, integer|nil colnum
function M.parse_file_ref_token(token, cwd)
  if not token or token == "" then
    return nil
  end

  -- Extract URL from markdown link syntax [label](target)
  local md_target = token:match("%]%(([^%)]+)%)")
  if md_target and md_target ~= "" then
    token = md_target
  end

  token = token:gsub("^[`\"'(%[<@*]+", ""):gsub("[`\"')%]>.,;:*]+$", "")
  if token == "" then
    return nil
  end

  -- Strip file:// URI scheme and decode basic percent-encoding
  if token:sub(1, 7) == "file://" then
    token = token:sub(8):gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end)
  end

  local path, lnum, colnum
  -- #L10-L20 or #L10
  path, lnum = token:match("^(.+)#L(%d+)%-L?%d+$")
  if not path then
    path, lnum = token:match("^(.+)#L(%d+)$")
  end
  -- :L10-L20 or :L10
  if not path then
    path, lnum = token:match("^([^:]+):L(%d+)%-L?%d+$")
  end
  if not path then
    path, lnum = token:match("^([^:]+):L(%d+)$")
  end
  -- :10:5 or :10:5-20:1
  if not path then
    path, lnum, colnum = token:match("^([^:]+):(%d+):(%d+)%-%d+:%d+$")
  end
  if not path then
    path, lnum, colnum = token:match("^([^:]+):(%d+):(%d+)$")
  end
  -- :10-20
  if not path then
    path, lnum = token:match("^([^:]+):(%d+)%-%d+$")
  end
  -- :10
  if not path then
    path, lnum = token:match("^([^:]+):(%d+)$")
  end
  if not path then
    path = token
  end
  if not path or path == "" then
    return nil
  end

  local candidates = { path }
  if cwd and cwd ~= "" then
    table.insert(candidates, cwd .. "/" .. path)
  end
  local nvim_cwd = vim.fn.getcwd()
  if nvim_cwd and nvim_cwd ~= "" and nvim_cwd ~= cwd then
    table.insert(candidates, nvim_cwd .. "/" .. path)
  end

  for _, candidate in ipairs(candidates) do
    if vim.fn.filereadable(candidate) == 1 then
      return candidate, tonumber(lnum), tonumber(colnum)
    end
  end
  return nil
end

--- Parse file[:line[:col]] or @file:L<line> under cursor in harness terminal output
---@param line_text string
---@param col integer 0-indexed column
---@param cwd string
---@return string|nil path, integer|nil lnum, integer|nil colnum
function M.parse_file_ref_at(line_text, col, cwd)
  if not line_text or line_text == "" then
    return nil
  end
  local target = col + 1
  local pos = 1
  local token
  while pos <= #line_text do
    local s, e = line_text:find("%S+", pos)
    if not s then break end
    if target >= s and target <= e then
      token = line_text:sub(s, e)
      break
    end
    pos = e + 1
  end
  if not token then
    return nil
  end
  return M.parse_file_ref_token(token, cwd)
end

--- Scan an entire line for the first readable file reference
---@param line_text string
---@param cwd string
---@return string|nil path, integer|nil lnum, integer|nil colnum
function M.parse_file_ref_in_line(line_text, cwd)
  if not line_text or line_text == "" then
    return nil
  end
  for token in line_text:gmatch("%S+") do
    local path, lnum, colnum = M.parse_file_ref_token(token, cwd)
    if path then
      return path, lnum, colnum
    end
  end
  return nil
end

--- Open a file reference or OSC 8 hyperlink at the given 0-indexed buffer position
---@param sess SuperHarnessSession
---@param buf integer
---@param row0 integer
---@param col0 integer
---@param allow_line_fallback? boolean
---@return boolean
function M.open_ref_at(sess, buf, row0, col0, allow_line_fallback)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  -- Check OSC 8 hyperlink extmarks if present (Neovim 0.10+)
  local ok_inspect, pos_info = pcall(vim.inspect_pos, buf, row0, col0)
  if ok_inspect and type(pos_info) == "table" and type(pos_info.extmarks) == "table" then
    for _, em in ipairs(pos_info.extmarks) do
      local url = em.opts and em.opts.url
      if type(url) == "string" and url ~= "" then
        if url:sub(1, 7) == "file://" then
          local path, lnum, colnum = M.parse_file_ref_token(url, sess.cwd)
          if path then
            vim.cmd("stopinsert")
            sync.open_file(path, lnum, colnum)
            pcall(vim.cmd, "normal! zz")
            return true
          end
        elseif url:match("^https?://") and vim.ui and vim.ui.open then
          vim.ui.open(url)
          return true
        end
      end
    end
  end

  local lines = vim.api.nvim_buf_get_lines(buf, row0, row0 + 1, false)
  local line = lines[1] or ""
  local path, lnum, colnum = M.parse_file_ref_at(line, col0, sess.cwd)
  if not path and allow_line_fallback then
    path, lnum, colnum = M.parse_file_ref_in_line(line, sess.cwd)
  end

  if path then
    vim.cmd("stopinsert")
    sync.open_file(path, lnum, colnum)
    pcall(vim.cmd, "normal! zz")
    return true
  end
  return false
end

--- Attach modal-aware smart escape, navigation, hide, zoom, and clickable link/gf keymaps to a terminal buffer
---@param sess SuperHarnessSession
function M.attach_term_keymaps(sess)
  local buf = sess.bufnr
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local opts = { buffer = buf, silent = true }
  local smart_esc = (config.options.keymaps or {}).smart_escape or "<M-Esc>"

  -- Single <Esc> passes through to the agent TUI; double <Esc> or smart_escape exits to Normal mode
  vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", vim.tbl_extend("force", opts, { desc = "SuperHarness: Exit terminal mode" }))
  if smart_esc and smart_esc ~= "" then
    vim.keymap.set("t", smart_esc, "<C-\\><C-n>", vim.tbl_extend("force", opts, { desc = "SuperHarness: Smart escape to Normal mode" }))
  end

  vim.keymap.set("t", "<C-h>", "<C-\\><C-n><C-w>h", opts)
  vim.keymap.set("t", "<C-j>", "<C-\\><C-n><C-w>j", opts)
  vim.keymap.set("t", "<C-k>", "<C-\\><C-n><C-w>k", opts)
  vim.keymap.set("t", "<C-l>", "<C-\\><C-n><C-w>l", opts)

  vim.keymap.set("t", "<C-q>", function()
    vim.cmd("stopinsert")
    M.hide(sess)
  end, vim.tbl_extend("force", opts, { desc = "SuperHarness: Hide harness" }))

  vim.keymap.set("n", "q", function()
    M.hide(sess)
  end, vim.tbl_extend("force", opts, { desc = "SuperHarness: Hide harness" }))

  vim.keymap.set({ "n", "t" }, "<M-z>", function()
    M.zoom(sess)
  end, vim.tbl_extend("force", opts, { desc = "SuperHarness: Toggle zoom" }))

  local function open_under_cursor()
    local cur = vim.api.nvim_win_get_cursor(0)
    if not M.open_ref_at(sess, buf, cur[1] - 1, cur[2], true) then
      log.info("No readable file reference under cursor.")
    end
  end

  vim.keymap.set("n", "gf", open_under_cursor, vim.tbl_extend("force", opts, { desc = "SuperHarness: Open file:line in code window" }))
  vim.keymap.set("n", "gx", open_under_cursor, vim.tbl_extend("force", opts, { desc = "SuperHarness: Open link/file:line in code window" }))

  local function make_mouse_handler(fallback_key, allow_line_fallback)
    return function()
      local m = vim.fn.getmousepos()
      if m and m.winid and m.winid > 0 and vim.api.nvim_win_is_valid(m.winid) then
        local clicked_buf = vim.api.nvim_win_get_buf(m.winid)
        if clicked_buf == buf and m.line and m.line >= 1 then
          local row0 = m.line - 1
          local col0 = math.max(0, (m.column or 1) - 1)
          if M.open_ref_at(sess, buf, row0, col0, allow_line_fallback) then
            return
          end
        end
      end
      local keys = vim.api.nvim_replace_termcodes(fallback_key, true, false, true)
      vim.api.nvim_feedkeys(keys, "n", false)
    end
  end

  vim.keymap.set({ "n", "t" }, "<LeftMouse>", make_mouse_handler("<LeftMouse>", false), vim.tbl_extend("force", opts, { desc = "SuperHarness: Click file link to open" }))
  vim.keymap.set({ "n", "t" }, "<2-LeftMouse>", make_mouse_handler("<2-LeftMouse>", true), vim.tbl_extend("force", opts, { desc = "SuperHarness: Double-click line link to open" }))
  vim.keymap.set({ "n", "t" }, "<C-LeftMouse>", make_mouse_handler("<C-LeftMouse>", true), vim.tbl_extend("force", opts, { desc = "SuperHarness: Ctrl+click line link to open" }))
end

return M
