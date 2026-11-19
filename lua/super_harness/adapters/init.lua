local config = require("super_harness.config")
local antigravity = require("super_harness.adapters.antigravity")
local claude = require("super_harness.adapters.claude")
local aider = require("super_harness.adapters.aider")
local goose = require("super_harness.adapters.goose")
local custom = require("super_harness.adapters.custom")

local M = {}

---@type table<string, table>
M.runtime_registry = {}

local function normalize(name, spec)
  local a = vim.deepcopy(spec or {})
  a.name = a.name or name
  a.label = a.label or a.name
  a.icon = a.icon or config.options.ui.icons.harness or "󰚩"
  if type(a.cmd) == "string" then
    a.cmd = vim.split(a.cmd, "%s+", { trimempty = true })
  elseif type(a.cmd) ~= "table" or #a.cmd == 0 then
    a.cmd = { a.name }
  end
  a.bin = a.bin or a.cmd[1]
  a.env = a.env or {}
  a.file_ref_style = a.file_ref_style or "at"
  if a.bracketed_paste == nil then
    a.bracketed_paste = config.options.context.bracketed_paste ~= false
  end
  a.submit_seq = a.submit_seq or "\r"
  a.submit_delay_ms = a.submit_delay_ms ~= nil and a.submit_delay_ms or 50
  a.exit_action = a.exit_action or "hide"
  a.status_detector = a.status_detector or custom.default_status_detector
  return a
end

--- Register or override an adapter at runtime
---@param name string
---@param spec table
---@return table
function M.register(name, spec)
  local existing = M.all()[name]
  local merged = existing and vim.tbl_deep_extend("force", vim.deepcopy(existing), spec) or spec
  local norm = normalize(name, merged)
  M.runtime_registry[name] = norm
  return norm
end

--- Return map of all known adapters (core + presets + user config + runtime)
---@return table<string, table>
function M.all()
  local map = {
    antigravity = normalize("antigravity", antigravity),
    claude = normalize("claude", claude),
    aider = normalize("aider", aider),
    goose = normalize("goose", goose),
  }
  for name, spec in pairs(custom.presets) do
    map[name] = normalize(name, spec)
  end
  for name, spec in pairs(config.options.adapters or {}) do
    local base = map[name]
    local merged = base and vim.tbl_deep_extend("force", vim.deepcopy(base), spec) or spec
    map[name] = normalize(name, merged)
  end
  for name, spec in pairs(M.runtime_registry) do
    local base = map[name]
    local merged = base and vim.tbl_deep_extend("force", vim.deepcopy(base), spec) or spec
    map[name] = normalize(name, merged)
  end
  return map
end

--- Lookup adapter by name or alias; optionally synthesize an ad-hoc adapter
---@param name string
---@param allow_adhoc? boolean
---@return table|nil
function M.get(name, allow_adhoc)
  if not name or name == "" then
    return nil
  end
  local all = M.all()
  if all[name] then
    return all[name]
  end
  -- Check aliases (e.g. "agy" -> "antigravity")
  for _, a in pairs(all) do
    for _, alias in ipairs(a.aliases or {}) do
      if alias == name then
        return a
      end
    end
  end
  if allow_adhoc then
    return normalize(name, custom.from_cmd(name))
  end
  return nil
end

--- Check whether an adapter's binary is executable on $PATH
---@param adapter table|string
---@return boolean
function M.is_installed(adapter)
  local a = type(adapter) == "string" and M.get(adapter, true) or adapter
  return a ~= nil and a.bin ~= nil and vim.fn.executable(a.bin) == 1
end

--- Detect all installed adapters ordered by preferred_order
---@return table[]
function M.detect_installed()
  local all = M.all()
  local seen = {}
  local installed = {}

  for _, name in ipairs(config.options.preferred_order or {}) do
    if all[name] and not seen[name] then
      seen[name] = true
      if M.is_installed(all[name]) then
        table.insert(installed, all[name])
      end
    end
  end

  local rest = {}
  for name, a in pairs(all) do
    if not seen[name] then
      table.insert(rest, a)
    end
  end
  table.sort(rest, function(x, y)
    return x.name < y.name
  end)
  for _, a in ipairs(rest) do
    if M.is_installed(a) then
      table.insert(installed, a)
    end
  end

  return installed
end

--- Resolve default adapter (configured default -> first installed -> antigravity)
---@return table
function M.resolve_default()
  local def = config.options.default_adapter
  if def and def ~= "" then
    return M.get(def, true)
  end
  local installed = M.detect_installed()
  if #installed > 0 then
    return installed[1]
  end
  return M.get("antigravity", true)
end

--- Build final argv for spawning an adapter
---@param adapter table
---@param opts? { resume?: boolean, continue?: boolean, model?: string, extra_args?: string[], one_shot?: string }
---@return string[]
function M.build_cmd(adapter, opts)
  opts = opts or {}
  local cmd = vim.deepcopy(adapter.cmd)
  if adapter.extra_args then
    vim.list_extend(cmd, adapter.extra_args)
  end
  if opts.resume and adapter.resume_args then
    vim.list_extend(cmd, adapter.resume_args)
  elseif opts.continue and adapter.continue_args then
    vim.list_extend(cmd, adapter.continue_args)
  end
  if opts.model and opts.model ~= "" and adapter.model_flag then
    table.insert(cmd, adapter.model_flag)
    table.insert(cmd, opts.model)
  end
  if opts.one_shot and adapter.prompt_arg then
    table.insert(cmd, adapter.prompt_arg)
    table.insert(cmd, opts.one_shot)
  end
  if opts.extra_args then
    vim.list_extend(cmd, opts.extra_args)
  end
  return cmd
end

--- Format a file/range reference for the target adapter
---@param adapter table
---@param rel_path string
---@param start_line? integer
---@param end_line? integer
---@return string
function M.format_file_ref(adapter, rel_path, start_line, end_line)
  if type(adapter.file_ref_style) == "function" then
    return adapter.file_ref_style(rel_path, start_line, end_line)
  end
  if adapter.file_ref_style == "aider" then
    if start_line and end_line then
      return string.format("/add %s # L%d-L%d", rel_path, start_line, end_line)
    end
    return "/add " .. rel_path
  elseif adapter.file_ref_style == "plain" then
    if start_line and end_line then
      return string.format("%s:%d-%d", rel_path, start_line, end_line)
    end
    return rel_path
  end
  if start_line and end_line then
    if start_line == end_line then
      return string.format("@%s:L%d", rel_path, start_line)
    end
    return string.format("@%s:L%d-L%d", rel_path, start_line, end_line)
  end
  return "@" .. rel_path
end

--- Format a prompt + context items payload using adapter conventions
---@param adapter table
---@param prompt? string
---@param items? table[]
---@return string
function M.format_payload(adapter, prompt, items)
  if type(adapter.context_format) == "function" then
    return adapter.context_format({ prompt = prompt, items = items or {} })
  end

  local refs = {}
  local blocks = {}

  for _, item in ipairs(items or {}) do
    if item.kind == "file" and item.ref_only and item.rel_path then
      table.insert(refs, M.format_file_ref(adapter, item.rel_path))
    elseif (item.kind == "selection" or item.kind == "scope") and item.rel_path then
      local ref = M.format_file_ref(adapter, item.rel_path, item.start_line, item.end_line)
      if item.content and item.content ~= "" then
        table.insert(blocks, string.format("%s\n```%s\n%s\n```", ref, item.filetype or "", item.content))
      else
        table.insert(refs, ref)
      end
    elseif item.text and item.text ~= "" then
      table.insert(blocks, item.text)
    elseif item.rel_path then
      table.insert(refs, M.format_file_ref(adapter, item.rel_path, item.start_line, item.end_line))
    end
  end

  local out = {}
  if #refs > 0 then
    table.insert(out, table.concat(refs, adapter.file_ref_style == "aider" and "\n" or " "))
  end
  for _, b in ipairs(blocks) do
    table.insert(out, b)
  end
  if prompt and vim.trim(prompt) ~= "" then
    table.insert(out, vim.trim(prompt))
  end
  return table.concat(out, "\n\n")
end

return M
