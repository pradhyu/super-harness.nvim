local config = require("super_harness.config")
local state = require("super_harness.state")
local log = require("super_harness.utils.log")
local adapters = require("super_harness.adapters")
local context = require("super_harness.context")
local backends = require("super_harness.backends")
local picker = require("super_harness.ui.picker")

local M = {}

M._buf = nil
M._win = nil

--- Expand inline @-tokens inside a composed prompt
---@param raw string
---@param opts? { adapter?: table, bufnr?: integer, start_line?: integer, end_line?: integer }
---@return string expanded, table[] attached
function M.expand_tokens(raw, opts)
  opts = opts or {}
  local adapter = opts.adapter or adapters.resolve_default()
  local bufnr = opts.bufnr
  local extra = {}

  local token_map = {
    file = function()
      local item = context.collect_file(bufnr)
      if item then
        if item.ref_only and item.rel_path then
          return adapters.format_file_ref(adapter, item.rel_path)
        end
        table.insert(extra, item)
        return item.rel_path or ""
      end
      return ""
    end,
    this = function()
      local item = context.collect_file(bufnr)
      return (item and item.rel_path) and adapters.format_file_ref(adapter, item.rel_path) or ""
    end,
    sel = function()
      local item = context.collect_selection(bufnr, opts.start_line, opts.end_line)
      if item then
        table.insert(extra, item)
        return adapters.format_file_ref(adapter, item.rel_path or "", item.start_line, item.end_line)
      end
      return ""
    end,
    scope = function()
      local item = context.collect_scope(bufnr)
      if item then
        table.insert(extra, item)
        return adapters.format_file_ref(adapter, item.rel_path or "", item.start_line, item.end_line)
      end
      return ""
    end,
    diag = function()
      local item = context.collect_diagnostics(bufnr)
      if item then
        table.insert(extra, item)
        return "(buffer diagnostics attached)"
      end
      return "(no diagnostics)"
    end,
    wdiag = function()
      local item = context.collect_diagnostics(bufnr, { workspace = true })
      if item then
        table.insert(extra, item)
        return "(workspace diagnostics attached)"
      end
      return "(no workspace diagnostics)"
    end,
    diff = function()
      local item = context.collect_git_diff({ staged = false })
      if item then
        table.insert(extra, item)
        return "(unstaged git diff attached)"
      end
      return "(no unstaged diff)"
    end,
    staged = function()
      local item = context.collect_git_diff({ staged = true })
      if item then
        table.insert(extra, item)
        return "(staged git diff attached)"
      end
      return "(no staged diff)"
    end,
    bufs = function()
      local item = context.collect_buffers()
      if item then
        table.insert(extra, item)
        return "(open buffers attached)"
      end
      return ""
    end,
    qf = function()
      local item = context.collect_quickfix()
      if item then
        table.insert(extra, item)
        return "(quickfix list attached)"
      end
      return "(empty quickfix)"
    end,
    tray = function()
      for _, titem in ipairs(context.tray_list()) do
        table.insert(extra, titem)
      end
      return "(context tray attached)"
    end,
  }

  local expanded = (raw or ""):gsub("@([%w_]+)", function(tok)
    return token_map[tok] and token_map[tok]() or ("@" .. tok)
  end)

  if #extra > 0 then
    expanded = adapters.format_payload(adapter, expanded, extra)
  end
  return vim.trim(expanded), extra
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
end

--- Open Floating Markdown Prompt Composer
---@param opts? { initial_text?: string, bufnr?: integer, start_line?: integer, end_line?: integer, include_tray?: boolean, broadcast?: boolean }
function M.open(opts)
  opts = opts or {}
  M.close()

  local source_buf = opts.bufnr or vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.b[buf].super_harness_buf = true
  M._buf = buf

  local init_lines = { "" }
  if opts.initial_text and opts.initial_text ~= "" then
    init_lines = vim.split(opts.initial_text, "\n", { plain = true })
  elseif opts.start_line and opts.end_line then
    init_lines = { "@sel", "" }
  elseif opts.include_tray and #context.tray_list() > 0 then
    init_lines = { "@tray", "" }
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, init_lines)

  local cols = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = math.max(54, math.floor(cols * 0.65))
  local height = math.max(10, math.floor(lines * 0.40))

  local active = state.get_active()
  local target_name = active and active.id or adapters.resolve_default().name
  local tray_n = #context.tray_list()
  local tray_hint = tray_n > 0 and string.format(" | Tray: %d (%s tok)", tray_n, log.format_tokens(context.tray_tokens())) or ""

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((lines - height) / 2),
    col = math.floor((cols - width) / 2),
    style = "minimal",
    border = (config.options.ui.float or {}).border or "rounded",
    title = string.format(" 󰚩 Prompt Composer → %s%s ", target_name, tray_hint),
    title_pos = "center",
    footer = " <C-s> Send | <C-b> Broadcast | <C-p> Template | <C-t> Insert @token | q Cancel ",
    footer_pos = "center",
  })
  M._win = win
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local function update_winbar()
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
      return
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    local toks = log.estimate_tokens(text) + (opts.include_tray and context.tray_tokens() or 0)
    vim.wo[win].winbar = string.format("%%#Comment# ~%s tokens  |  Target: %s", log.format_tokens(toks), target_name)
  end
  update_winbar()
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = update_winbar })

  local function submit(is_broadcast)
    local raw = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    M.close()
    if vim.trim(raw) == "" then
      return
    end
    local act = state.get_active()
    local adapter = act and act.adapter or adapters.resolve_default()
    local expanded = M.expand_tokens(raw, {
      adapter = adapter,
      bufnr = source_buf,
      start_line = opts.start_line,
      end_line = opts.end_line,
    })

    if is_broadcast then
      local n = backends.broadcast(expanded, nil, {})
      log.info(string.format("Broadcast prompt to %d active session(s)", n))
    else
      local ok, err = backends.send(expanded, { focus = true })
      if ok and opts.include_tray and config.options.context.clear_tray_on_send then
        context.tray_clear()
      elseif not ok and err then
        log.error("Failed to send prompt: " .. err)
      end
    end
  end

  local map_opts = { buffer = buf, silent = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    submit(opts.broadcast == true)
  end, map_opts)
  vim.keymap.set({ "n", "i" }, "<C-b>", function()
    vim.cmd("stopinsert")
    submit(true)
  end, map_opts)
  vim.keymap.set({ "n", "i" }, "<C-p>", function()
    vim.cmd("stopinsert")
    picker.pick_prompt({
      bufnr = source_buf,
      start_line = opts.start_line,
      end_line = opts.end_line,
      on_render = function(rendered)
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(rendered, "\n", { plain = true }))
          update_winbar()
        end
      end,
    })
  end, map_opts)
  vim.keymap.set({ "n", "i" }, "<C-t>", function()
    vim.cmd("stopinsert")
    picker.select({
      title = "Insert Context @-Token",
      items = {
        { tok = "@file", desc = "Active file reference" },
        { tok = "@sel", desc = "Visual selection with line range" },
        { tok = "@scope", desc = "Treesitter enclosing function/class" },
        { tok = "@diag", desc = "Active buffer LSP diagnostics" },
        { tok = "@wdiag", desc = "Workspace LSP diagnostics" },
        { tok = "@diff", desc = "Unstaged git diff" },
        { tok = "@staged", desc = "Staged git diff" },
        { tok = "@bufs", desc = "All open listed buffers" },
        { tok = "@qf", desc = "Quickfix list" },
        { tok = "@tray", desc = "Staged Context Tray items" },
      },
      format_item = function(item)
        return string.format("%-10s  %s", item.tok, item.desc)
      end,
      on_select = function(item)
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win) then
          local row, col = unpack(vim.api.nvim_win_get_cursor(win))
          local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
          vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { line:sub(1, col) .. item.tok .. " " .. line:sub(col + 1) })
          vim.api.nvim_win_set_cursor(win, { row, col + #item.tok + 1 })
          update_winbar()
          vim.cmd("startinsert")
        end
      end,
    })
  end, map_opts)
  vim.keymap.set("n", "q", M.close, map_opts)
  vim.keymap.set("n", "<Esc>", M.close, map_opts)

  pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
  vim.cmd("startinsert")
end

return M
