local config = require("super_harness.config")
local state = require("super_harness.state")
local log = require("super_harness.utils.log")
local adapters = require("super_harness.adapters")
local context = require("super_harness.context")
local backends = require("super_harness.backends")
local window = require("super_harness.ui.window")

local M = {}

--- Multi-backend picker (Snacks.picker -> Telescope -> vim.ui.select)
---@param opts { title: string, items: table[], format_item: fun(item:table):string, on_select: fun(item:table) }
function M.select(opts)
  local items = opts.items or {}
  if #items == 0 then
    log.info("Nothing to select for " .. (opts.title or "SuperHarness"))
    return
  end

  local backend = (config.options.ui or {}).picker or "auto"

  if backend == "auto" or backend == "snacks" then
    local ok_snacks, snacks = pcall(require, "snacks")
    if ok_snacks and snacks.picker and snacks.picker.pick then
      local picker_items = {}
      for idx, item in ipairs(items) do
        table.insert(picker_items, { idx = idx, text = opts.format_item(item), raw = item })
      end
      snacks.picker.pick({
        title = opts.title or "SuperHarness",
        items = picker_items,
        format = "text",
        confirm = function(picker, picked)
          picker:close()
          if picked and picked.raw then
            opts.on_select(picked.raw)
          end
        end,
      })
      return
    end
  end

  if backend == "auto" or backend == "telescope" then
    local ok_tel, pickers = pcall(require, "telescope.pickers")
    if ok_tel then
      local finders = require("telescope.finders")
      local conf = require("telescope.config").values
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")
      pickers.new({}, {
        prompt_title = opts.title or "SuperHarness",
        finder = finders.new_table({
          results = items,
          entry_maker = function(item)
            local lbl = opts.format_item(item)
            return { value = item, display = lbl, ordinal = lbl }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            local sel = action_state.get_selected_entry()
            if sel and sel.value then
              opts.on_select(sel.value)
            end
          end)
          return true
        end,
      }):find()
      return
    end
  end

  vim.ui.select(items, {
    prompt = (opts.title or "SuperHarness") .. ":",
    format_item = opts.format_item,
  }, function(choice)
    if choice then
      opts.on_select(choice)
    end
  end)
end

function M.pick_adapter(opts)
  opts = opts or {}
  local list = {}
  for _, a in pairs(adapters.all()) do
    table.insert(list, { adapter = a, installed = adapters.is_installed(a) })
  end
  table.sort(list, function(x, y)
    if x.installed ~= y.installed then
      return x.installed
    end
    return x.adapter.name < y.adapter.name
  end)

  M.select({
    title = "SuperHarness: Launch Agent",
    items = list,
    format_item = function(item)
      local a = item.adapter
      local badge = item.installed and "✓" or "✗"
      return string.format("[%s] %s %-14s  %-20s  (%s)", badge, a.icon or "󰚩", a.name, a.label, table.concat(a.cmd, " "))
    end,
    on_select = function(item)
      if opts.on_pick then
        opts.on_pick(item.adapter)
      else
        backends.spawn(item.adapter.name, { layout = opts.layout, name = opts.name })
      end
    end,
  })
end

function M.pick_session()
  local list = state.list()
  if #list == 0 then
    log.info("No active sessions — launching agent picker...")
    M.pick_adapter()
    return
  end

  local icons = config.options.ui.icons or {}
  M.select({
    title = "SuperHarness: Active Sessions",
    items = list,
    format_item = function(s)
      local active = (s.id == state.active_id) and "*" or " "
      local st = icons[s.state] or "●"
      local vis = window.is_visible(s) and "visible" or s.backend
      local age = log.format_duration(os.time() - (s.started_at or os.time()))
      local last = s.last_prompt ~= "" and (" | " .. log.truncate(s.last_prompt, 42)) or ""
      return string.format("%s %s %-16s [%s/%s] %s%s", active, st, s.id, s.layout, vis, age, last)
    end,
    on_select = function(s)
      backends.show(s.id)
    end,
  })
end

function M.pick_prompt(opts)
  opts = opts or {}
  M.select({
    title = "SuperHarness: Prompt Library",
    items = context.all_prompts(),
    format_item = function(t)
      return string.format("%-18s  %-24s  %s", t.name, t.label, t.description)
    end,
    on_select = function(t)
      local active = state.get_active()
      local adapter = active and active.adapter or adapters.resolve_default()
      local rendered = context.render_template(t.template, {
        adapter = adapter,
        bufnr = opts.bufnr,
        start_line = opts.start_line,
        end_line = opts.end_line,
      })
      if opts.on_render then
        opts.on_render(rendered, t)
      else
        backends.send(rendered, { focus = true })
      end
    end,
  })
end

function M.pick_history()
  local hist = context.get_history()
  if #hist == 0 then
    log.info("Prompt history is empty.")
    return
  end
  M.select({
    title = "SuperHarness: Prompt History (Frecency)",
    items = hist,
    format_item = function(rec)
      local preview = (rec.prompt or ""):gsub("\n", " ")
      return string.format("🔥 %2dx  [%-11s]  %s", rec.count or 1, rec.harness or "any", log.truncate(preview, 72))
    end,
    on_select = function(rec)
      backends.send(rec.prompt, { focus = true })
    end,
  })
end

function M.pick_slash()
  local active = state.get_active()
  local adapter = active and active.adapter or adapters.resolve_default()
  local cmds = (adapter and adapter.slash_commands) or { "/clear", "/compact", "/help", "/status" }
  local items = vim.tbl_map(function(c)
    return { cmd = c, adapter = adapter and adapter.name or "agent" }
  end, cmds)

  M.select({
    title = string.format("SuperHarness: %s Slash Commands", adapter and adapter.label or "Agent"),
    items = items,
    format_item = function(item)
      return string.format("%-16s  [%s]", item.cmd, item.adapter)
    end,
    on_select = function(item)
      backends.send(item.cmd, { focus = true, record_history = false })
    end,
  })
end

return M
