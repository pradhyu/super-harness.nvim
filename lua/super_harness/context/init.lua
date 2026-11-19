local config = require("super_harness.config")
local state = require("super_harness.state")
local log = require("super_harness.utils.log")
local adapters = require("super_harness.adapters")
local git = require("super_harness.context.git")
local treesitter = require("super_harness.context.treesitter")
local lsp = require("super_harness.context.lsp")

local M = {}

---@type table[]
M.tray = {}

--- Resolve target code buffer (prefers active code buffer, else last_code_win)
---@param bufnr? integer
---@return integer
local function resolve_buf(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  local cur = vim.api.nvim_get_current_buf()
  if log.is_code_buffer(cur) then
    return cur
  end
  if state.last_code_win and vim.api.nvim_win_is_valid(state.last_code_win) then
    return vim.api.nvim_win_get_buf(state.last_code_win)
  end
  return cur
end

local function format_lines(lines, start_line)
  if not config.options.context.include_line_numbers then
    return table.concat(lines, "\n")
  end
  local out = {}
  local w = #tostring(start_line + #lines - 1)
  local fmt = "%" .. w .. "d | %s"
  for i, l in ipairs(lines) do
    table.insert(out, string.format(fmt, start_line + i - 1, l))
  end
  return table.concat(out, "\n")
end

--- Collect active file context
---@param bufnr? integer
---@param opts? { ref_only?: boolean }
---@return table|nil
function M.collect_file(bufnr, opts)
  opts = opts or {}
  local buf = resolve_buf(bufnr)
  local path = vim.api.nvim_buf_get_name(buf)
  local ft = vim.bo[buf].filetype or ""
  local ref_only = opts.ref_only
  if ref_only == nil then
    ref_only = config.options.context.ref_only_for_files and path ~= ""
  end

  local rel = path ~= "" and git.rel_path(path) or ("[Buffer #" .. buf .. "]")
  if ref_only and path ~= "" then
    return {
      key = "file:" .. rel,
      kind = "file",
      label = "File: " .. rel,
      rel_path = rel,
      filetype = ft,
      ref_only = true,
      tokens = log.estimate_tokens("@" .. rel),
    }
  end

  local max_lines = config.options.context.max_context_lines or 1000
  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, max_lines, false)
  local total = vim.api.nvim_buf_line_count(buf)
  local content = format_lines(all_lines, 1)
  if total > max_lines then
    content = content .. string.format("\n... (%d more lines truncated)", total - max_lines)
  end
  local text = string.format("File `%s`:\n```%s\n%s\n```", rel, ft, content)
  return {
    key = "file:" .. rel,
    kind = "file",
    label = string.format("File: %s (%d lines)", rel, total),
    rel_path = rel,
    filetype = ft,
    ref_only = false,
    content = content,
    text = text,
    tokens = log.estimate_tokens(text),
  }
end

--- Collect visual selection or explicit line range
---@param bufnr? integer
---@param start_line? integer
---@param end_line? integer
---@return table|nil
function M.collect_selection(bufnr, start_line, end_line)
  local buf = resolve_buf(bufnr)
  if not start_line or not end_line then
    local mode = vim.fn.mode()
    if mode == "v" or mode == "V" or mode == "\22" then
      local s, e = vim.fn.line("v"), vim.fn.line(".")
      start_line, end_line = math.min(s, e), math.max(s, e)
    else
      local s, e = vim.fn.line("'<"), vim.fn.line("'>")
      if s > 0 and e >= s then
        start_line, end_line = s, e
      else
        local row = vim.api.nvim_win_get_cursor(0)[1]
        start_line, end_line = row, row
      end
    end
  end

  local total = vim.api.nvim_buf_line_count(buf)
  start_line = math.max(1, math.min(start_line, total))
  end_line = math.max(start_line, math.min(end_line, total))
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local path = vim.api.nvim_buf_get_name(buf)
  local rel = path ~= "" and git.rel_path(path) or ("[Buffer #" .. buf .. "]")
  local ft = vim.bo[buf].filetype or ""
  local content = format_lines(lines, start_line)

  return {
    key = string.format("sel:%s:%d-%d", rel, start_line, end_line),
    kind = "selection",
    label = string.format("Selection: %s:L%d-L%d", rel, start_line, end_line),
    rel_path = rel,
    start_line = start_line,
    end_line = end_line,
    filetype = ft,
    content = content,
    tokens = log.estimate_tokens(content) + 12,
  }
end

--- Collect Treesitter enclosing function/method/class scope
---@param bufnr? integer
---@param row? integer
---@return table|nil
function M.collect_scope(bufnr, row)
  local buf = resolve_buf(bufnr)
  local win = (state.last_code_win and vim.api.nvim_win_is_valid(state.last_code_win))
      and state.last_code_win
    or vim.api.nvim_get_current_win()
  local cur_row = row or (vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_cursor(win)[1] or 1)
  local s, e = treesitter.get_enclosing_range(buf, cur_row)
  local item = M.collect_selection(buf, s, e)
  if item then
    item.kind = "scope"
    item.key = string.format("scope:%s:%d-%d", item.rel_path or "", s, e)
    item.label = string.format("Scope: %s:L%d-L%d", item.rel_path or "", s, e)
  end
  return item
end

function M.collect_diagnostics(bufnr, opts)
  return lsp.collect_diagnostics(resolve_buf(bufnr), opts)
end

function M.collect_quickfix()
  return lsp.collect_quickfix()
end

function M.collect_git_diff(opts)
  return git.collect_diff(opts)
end

--- Collect all open listed file buffers
---@return table|nil
function M.collect_buffers()
  local root = git.project_root()
  local entries = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted and log.is_code_buffer(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        local mod = vim.bo[b].modified and " [modified]" or ""
        table.insert(entries, "- " .. git.rel_path(name, root) .. mod)
      end
    end
  end
  if #entries == 0 then
    return nil
  end
  local text = "Open Buffers:\n" .. table.concat(entries, "\n")
  return {
    key = "buffers:all",
    kind = "buffers",
    label = string.format("Open Buffers (%d)", #entries),
    text = text,
    tokens = log.estimate_tokens(text),
  }
end

-- =============================================================================
-- Context Tray (Staging Queue)
-- =============================================================================

function M.tray_add(item)
  if not item or not item.key then
    return false
  end
  for i, existing in ipairs(M.tray) do
    if existing.key == item.key then
      M.tray[i] = item
      return true
    end
  end
  table.insert(M.tray, item)
  return true
end

function M.tray_remove(idx_or_key)
  if type(idx_or_key) == "number" then
    if M.tray[idx_or_key] then
      table.remove(M.tray, idx_or_key)
      return true
    end
    return false
  end
  for i, item in ipairs(M.tray) do
    if item.key == idx_or_key then
      table.remove(M.tray, i)
      return true
    end
  end
  return false
end

function M.tray_clear()
  M.tray = {}
end

function M.tray_list()
  return M.tray
end

function M.tray_tokens()
  local total = 0
  for _, item in ipairs(M.tray) do
    total = total + (item.tokens or 0)
  end
  return total
end

function M.tray_format(adapter, prompt)
  return adapters.format_payload(adapter, prompt, M.tray)
end

-- =============================================================================
-- Prompt Templates & Frecency History
-- =============================================================================

M.builtin_prompts = {
  explain = {
    name = "explain",
    label = "Explain Code",
    description = "Explain active selection or enclosing Treesitter scope",
    template = "Explain how this code works, including non-obvious edge cases and invariants:\n\n{selection_or_scope}",
  },
  fix_diagnostics = {
    name = "fix_diagnostics",
    label = "Fix Diagnostics",
    description = "Fix all active LSP diagnostics in current buffer",
    template = "Fix all the following LSP diagnostics cleanly without introducing regressions:\n\n{file}\n\n{diagnostics}",
  },
  refactor = {
    name = "refactor",
    label = "Refactor",
    description = "Refactor selection or scope for clarity and maintainability",
    template = "Refactor the following code for clarity, modularity, and idiomatic style while preserving exact behavior:\n\n{selection_or_scope}",
  },
  tests = {
    name = "tests",
    label = "Write Unit Tests",
    description = "Generate comprehensive unit tests",
    template = "Write thorough unit tests covering happy paths, edge cases, and error handling for:\n\n{selection_or_scope}",
  },
  review = {
    name = "review",
    label = "Code Review",
    description = "Senior-level review of current git diff or file",
    template = "Review the following changes for correctness, edge cases, security, and performance:\n\n{git_diff_or_file}",
  },
  debug = {
    name = "debug",
    label = "Debug Error",
    description = "Diagnose diagnostics & quickfix errors",
    template = "Diagnose the root cause of these errors and fix them:\n\n{diagnostics}\n\n{quickfix}",
  },
  optimize = {
    name = "optimize",
    label = "Optimize Performance",
    description = "Analyze complexity and optimize bottlenecks",
    template = "Analyze time/memory bottlenecks and optimize:\n\n{selection_or_scope}",
  },
  plan = {
    name = "plan",
    label = "Draft Implementation Plan",
    description = "Propose a step-by-step architectural plan before editing",
    template = "Before editing any files, draft a concrete step-by-step implementation plan for:\n\n{file}\n\n{tray}",
  },
  commit = {
    name = "commit",
    label = "Conventional Commit",
    description = "Write a conventional commit message from staged diff",
    template = "Write a concise Conventional Commits message for these staged changes:\n\n{git_staged}",
  },
}

M.history = {}
M._history_loaded = false

function M.all_prompts()
  local map = vim.deepcopy(M.builtin_prompts)
  for name, spec in pairs(config.options.prompts.custom or {}) do
    if type(spec) == "string" then
      map[name] = { name = name, label = name, description = "Custom prompt", template = spec }
    elseif type(spec) == "table" then
      map[name] = {
        name = spec.name or name,
        label = spec.label or name,
        description = spec.description or "Custom prompt",
        template = spec.template or "",
      }
    end
  end
  local list = vim.tbl_values(map)
  table.sort(list, function(a, b)
    return a.name < b.name
  end)
  return list
end

function M.render_template(template_str, opts)
  opts = opts or {}
  local adapter = opts.adapter or adapters.resolve_default()
  local bufnr = opts.bufnr
  local function fmt(item)
    return item and adapters.format_payload(adapter, nil, { item }) or ""
  end
  local resolvers = {
    file = function() return fmt(M.collect_file(bufnr)) end,
    selection = function() return fmt(M.collect_selection(bufnr, opts.start_line, opts.end_line)) end,
    scope = function() return fmt(M.collect_scope(bufnr)) end,
    selection_or_scope = function()
      if opts.start_line and opts.end_line then
        return fmt(M.collect_selection(bufnr, opts.start_line, opts.end_line))
      end
      return fmt(M.collect_scope(bufnr) or M.collect_file(bufnr))
    end,
    diagnostics = function() return fmt(M.collect_diagnostics(bufnr)) end,
    git_diff = function() return fmt(M.collect_git_diff({ staged = false })) end,
    git_staged = function() return fmt(M.collect_git_diff({ staged = true })) end,
    git_diff_or_file = function() return fmt(M.collect_git_diff({ staged = false }) or M.collect_file(bufnr)) end,
    quickfix = function() return fmt(M.collect_quickfix()) end,
    buffers = function() return fmt(M.collect_buffers()) end,
    tray = function() return #M.tray > 0 and M.tray_format(adapter) or "" end,
  }
  local rendered = template_str:gsub("{([%w_]+)}", function(k)
    return resolvers[k] and resolvers[k]() or ("{" .. k .. "}")
  end)
  return vim.trim(rendered:gsub("\n\n\n+", "\n\n"))
end

function M.load_history()
  local data = log.read_json(config.options.prompts.history_file)
  M.history = type(data) == "table" and data or {}
  M._history_loaded = true
end

function M.frecency_score(rec, now)
  now = now or os.time()
  local age_hours = math.max(0, (now - (rec.last_used or now)) / 3600)
  return (rec.count or 1) * (1 + 2 / (1 + age_hours / 24))
end

function M.record_history(prompt, adapter_name)
  if not M._history_loaded then
    M.load_history()
  end
  local cleaned = vim.trim(prompt or "")
  if cleaned == "" then
    return
  end
  local key = cleaned:sub(1, 200)
  local existing = M.history[key]
  if existing then
    existing.count = (existing.count or 0) + 1
    existing.last_used = os.time()
    existing.harness = adapter_name or existing.harness or ""
    existing.prompt = cleaned
  else
    M.history[key] = {
      prompt = cleaned,
      count = 1,
      last_used = os.time(),
      harness = adapter_name or "",
    }
  end
  log.write_json(config.options.prompts.history_file, M.history)
end

function M.get_history()
  if not M._history_loaded then
    M.load_history()
  end
  local now = os.time()
  local list = {}
  for _, rec in pairs(M.history) do
    local entry = vim.deepcopy(rec)
    entry.score = M.frecency_score(rec, now)
    table.insert(list, entry)
  end
  table.sort(list, function(a, b)
    return a.score > b.score
  end)
  return list
end

return M
