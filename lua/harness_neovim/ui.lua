local M = {}

--- Map string log level to vim.log.levels
---@param level string|number|nil
---@return number
local function parse_level(level)
  if type(level) == "number" then
    return level
  end
  if type(level) == "string" then
    local l = level:lower()
    if l == "debug" or l == "trace" then
      return vim.log.levels.DEBUG
    elseif l == "info" then
      return vim.log.levels.INFO
    elseif l == "warn" or l == "warning" then
      return vim.log.levels.WARN
    elseif l == "error" or l == "err" then
      return vim.log.levels.ERROR
    end
  end
  return vim.log.levels.INFO
end

--- Show a notification in Neovim (and optionally clickable desktop notification + open harness modal)
---@param msg string
---@param level string|number|nil
---@param opts table?
---@return boolean
function M.notify(msg, level, opts)
  opts = opts or {}
  local lvl = parse_level(level)
  local title = opts.title or "Nvim-CLI"
  vim.notify(tostring(msg), lvl, { title = title, timeout = opts.timeout })

  local ok_state, sh_state = pcall(require, "super_harness.state")
  local ok_term, nvim_term = pcall(require, "super_harness.backends.nvim_term")
  local ok_log, sh_log = pcall(require, "super_harness.utils.log")

  if ok_state and ok_term and ok_log then
    local sess = (opts.session and sh_state.get(opts.session)) or sh_state.get_active()
    local is_attention = opts.attention == true
    local should_open = opts.open == true or is_attention
    local target_layout = opts.layout or (is_attention and "float") or nil

    if opts.desktop ~= false and (opts.desktop == true or should_open) then
      local urgency = opts.urgency or (is_attention and "critical") or (lvl >= vim.log.levels.ERROR and "critical") or "normal"
      local on_click = nil
      if sess then
        on_click = function()
          sh_log.focus_host_window()
          nvim_term.open_session(sess, {
            layout = target_layout,
            temporary_layout = target_layout ~= nil,
            enter_insert = true,
          })
        end
      end
      sh_log.desktop_notify(title, tostring(msg), {
        urgency = urgency,
        on_click = on_click,
        action_label = is_attention and "Approve in Neovim" or "Open in Neovim",
      })
    end

    if should_open and sess then
      vim.schedule(function()
        nvim_term.open_session(sess, {
          layout = target_layout or "float",
          temporary_layout = true,
          title_prefix = is_attention and "▲ Permission — " or nil,
          enter_insert = true,
        })
      end)
    end
  end

  return true
end

--- Create and display a floating popup window with content
---@param title string|nil
---@param lines string|string[]
---@param opts table?
---@return { win_id: number, bufnr: number }
function M.show_float(title, lines, opts)
  opts = opts or {}
  if type(lines) == "string" then
    lines = vim.split(lines, "\n", { plain = true })
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = opts.modifiable or false

  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end

  -- Calculate dimensions
  local max_line_len = 0
  for _, line in ipairs(lines) do
    if #line > max_line_len then
      max_line_len = #line
    end
  end

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  local width = opts.width or math.min(math.max(max_line_len + 4, 40), math.floor(editor_width * 0.85))
  local height = opts.height or math.min(math.max(#lines, 1), math.floor(editor_height * 0.75))

  local row = opts.row or math.floor((editor_height - height) / 2)
  local col = opts.col or math.floor((editor_width - width) / 2)

  local win_config = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = opts.border or "rounded",
    title = title and (" " .. title .. " ") or nil,
    title_pos = title and "center" or nil,
  }

  local win = vim.api.nvim_open_win(buf, true, win_config)
  vim.wo[win].wrap = opts.wrap ~= nil and opts.wrap or true
  vim.wo[win].cursorline = opts.cursorline or false

  -- Set keymaps to easily dismiss the float
  local close_keys = { "q", "<Esc>" }
  for _, key in ipairs(close_keys) do
    vim.keymap.set("n", key, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true, silent = true, desc = "Close floating window" })
  end

  return { win_id = win, bufnr = buf }
end

--- Show a side-by-side diff in Neovim
---@param title string
---@param original_lines string[]
---@param modified_lines string[]
---@param opts table?
---@return { orig_buf: number, mod_buf: number }
function M.show_diff(title, original_lines, modified_lines, opts)
  opts = opts or {}
  vim.cmd("tabnew")

  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, original_lines)
  vim.bo[orig_buf].buftype = "nofile"
  vim.bo[orig_buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(orig_buf, (title or "Diff") .. " (Original)")
  vim.cmd("diffthis")

  vim.cmd("vsplit")
  local mod_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(mod_buf)
  vim.api.nvim_buf_set_lines(mod_buf, 0, -1, false, modified_lines)
  vim.bo[mod_buf].buftype = "nofile"
  vim.bo[mod_buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(mod_buf, (title or "Diff") .. " (Modified)")
  vim.cmd("diffthis")

  return { orig_buf = orig_buf, mod_buf = mod_buf }
end

return M
