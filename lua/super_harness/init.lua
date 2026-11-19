local config = require("super_harness.config")
local state = require("super_harness.state")
local log = require("super_harness.utils.log")
local adapters = require("super_harness.adapters")
local backends = require("super_harness.backends")
local context = require("super_harness.context")
local sync = require("super_harness.sync")
local review = require("super_harness.review")
local diffsplit = require("super_harness.review.diffsplit")
local quickfix = require("super_harness.review.quickfix")
local picker = require("super_harness.ui.picker")
local input = require("super_harness.ui.input")
local hud = require("super_harness.ui.hud")
local statusline = require("super_harness.ui.statusline")
local keymaps = require("super_harness.utils.keymaps")

local M = {}

M.config = config
M.state = state
M.adapters = adapters
M.backends = backends
M.context = context
M.sync = sync
M.review_engine = review
M.cli = require("harness_neovim")
M._initialized = false
M._last_opts = nil

function M.install_cli(target_dir)
  return M.cli.install_cli(target_dir or config.options.rpc.bin_install_dir)
end

--- Initialize super-harness.nvim
---@param opts? table
---@return table
function M.setup(opts)
  M._last_opts = opts
  local merged = config.setup(opts)
  sync.setup()
  keymaps.setup(M)
  M._initialized = true
  return merged
end

--- Hot-reload super-harness.nvim cleanly without restarting Neovim (:SuperHarnessReload)
function M.reload()
  local saved_opts = M._last_opts
  pcall(backends.kill_all)
  pcall(sync.teardown)
  pcall(hud.close)
  pcall(input.close)
  pcall(diffsplit.close)
  state.reset()

  for name, _ in pairs(package.loaded) do
    if
      name == "super_harness"
      or name:match("^super_harness%.")
      or name == "harness_neovim"
      or name:match("^harness_neovim%.")
      or name == "nvim_cli"
      or name:match("^nvim_cli%.")
    then
      package.loaded[name] = nil
    end
  end

  local fresh = require("super_harness")
  fresh.setup(saved_opts)
  log.info("super-harness.nvim reloaded cleanly.")
  return fresh
end

function M.register_adapter(name, spec)
  return adapters.register(name, spec)
end

-- =============================================================================
-- Session & Window Controls
-- =============================================================================

function M.toggle(adapter_name, opts)
  return backends.toggle(adapter_name, opts)
end

function M.open(adapter_name, opts)
  return backends.spawn(adapter_name, opts)
end

function M.resume(adapter_name, opts)
  local o = vim.tbl_extend("force", opts or {}, { resume = true, continue = true })
  return backends.spawn(adapter_name, o)
end

function M.new_session()
  vim.ui.input({ prompt = "New session name (optional): " }, function(name)
    picker.pick_adapter({ name = (name and vim.trim(name) ~= "") and vim.trim(name) or nil })
  end)
end

function M.show(id, layout)
  return backends.show(id, layout)
end

function M.hide(id)
  return backends.hide(id)
end

function M.zoom(id)
  return backends.zoom(id)
end

function M.kill(id)
  if id == "all" then
    backends.kill_all()
    return true
  end
  return backends.kill(id)
end

function M.pick_adapter(opts)
  picker.pick_adapter(opts)
end

function M.pick_session()
  picker.pick_session()
end

function M.pick_slash()
  picker.pick_slash()
end

-- =============================================================================
-- Prompting, Context Injection & Tray
-- =============================================================================

function M.send(text, opts)
  return backends.send(text, opts)
end

function M.send_context(kind, opts)
  opts = opts or {}
  local item

  if kind == "tray" then
    local tray = context.tray_list()
    if #tray == 0 then
      log.info("Context Tray is empty.")
      return false, "Empty tray"
    end
    local ok, err = backends.send(opts.prompt or "", { context_items = tray, focus = opts.focus ~= false })
    if ok and config.options.context.clear_tray_on_send then
      context.tray_clear()
    end
    return ok, err
  elseif kind == "selection" then
    item = context.collect_selection(opts.bufnr, opts.start_line, opts.end_line)
  elseif kind == "diagnostics" then
    item = context.collect_diagnostics(opts.bufnr, { workspace = false })
  elseif kind == "workspace_diagnostics" then
    item = context.collect_diagnostics(opts.bufnr, { workspace = true })
  elseif kind == "diff" then
    item = context.collect_git_diff({ staged = false })
  elseif kind == "staged" then
    item = context.collect_git_diff({ staged = true })
  elseif kind == "scope" then
    item = context.collect_scope(opts.bufnr)
  elseif kind == "buffers" then
    item = context.collect_buffers()
  elseif kind == "quickfix" then
    item = context.collect_quickfix()
  else
    item = context.collect_file(opts.bufnr)
  end

  if not item then
    log.info("No " .. tostring(kind) .. " context available.")
    return false, "No context"
  end
  return backends.send(opts.prompt or "", { context_items = { item }, focus = opts.focus ~= false })
end

function M.tray_add_current(opts)
  opts = opts or {}
  local item = (opts.start_line and opts.end_line)
      and context.collect_selection(opts.bufnr, opts.start_line, opts.end_line)
    or context.collect_file(opts.bufnr)
  if item and context.tray_add(item) then
    log.info(string.format("Staged in Context Tray: %s (~%s tok)", item.label, log.format_tokens(item.tokens)))
    return true
  end
  return false
end

function M.compose(opts)
  input.open(opts)
end

function M.pick_prompt(opts)
  picker.pick_prompt(opts)
end

function M.pick_history()
  picker.pick_history()
end

function M.broadcast(opts)
  opts = opts or {}
  if opts.text and opts.text ~= "" then
    return backends.broadcast(opts.text, opts.session_ids, opts)
  end
  input.open(vim.tbl_extend("force", opts, { broadcast = true }))
end

-- =============================================================================
-- Review, Diffsplit, Quickfix, Comments & HUD
-- =============================================================================

function M.review()
  diffsplit.open(function()
    M.dispatch_comments()
  end)
end

function M.populate_quickfix(open_qf)
  return quickfix.populate(open_qf)
end

function M.next_changed_file()
  quickfix.next_file()
end

function M.prev_changed_file()
  quickfix.prev_file()
end

function M.add_comment(opts)
  opts = opts or {}
  local buf = opts.bufnr or vim.api.nvim_get_current_buf()
  local s = opts.start_line
  local e = opts.end_line
  if not s or not e then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    s, e = row, row
  end

  if opts.comment then
    return review.add_comment(buf, s, e, opts.comment)
  end

  vim.ui.input({ prompt = string.format("Review comment (L%d-L%d): ", s, e) }, function(text)
    if text and vim.trim(text) ~= "" then
      local entry = review.add_comment(buf, s, e, text)
      if entry then
        log.info(string.format("Queued review comment #%d (%d total)", entry.id, #review.list_comments()))
      end
    end
  end)
end

function M.dispatch_comments()
  local active = state.get_active()
  local payload = review.format_comments_payload(active and active.adapter or nil)
  if payload == "" then
    log.info("No review comments queued.")
    return false
  end
  local ok = backends.send(payload, { focus = true })
  if ok then
    review.clear_comments()
  end
  return ok
end

function M.hud(tab)
  hud.open(tab)
end

function M.statusline()
  return statusline.get()
end

return M
