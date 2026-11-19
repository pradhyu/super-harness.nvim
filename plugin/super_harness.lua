if vim.g.loaded_super_harness == 1 then
  return
end
vim.g.loaded_super_harness = 1

local sh = require("super_harness")
local adapters = require("super_harness.adapters")
local log = require("super_harness.utils.log")

local SUBCOMMANDS = {
  "toggle",
  "open",
  "resume",
  "send",
  "send-context",
  "compose",
  "prompt",
  "history",
  "broadcast",
  "tray",
  "review",
  "quickfix",
  "comment",
  "dispatch-comments",
  "sessions",
  "pick",
  "hud",
  "qa",
  "transcript",
  "approval",
  "slash",
  "zoom",
  "kill",
  "install-cli",
  "status",
  "reload",
}

local function range_opts(cmd_opts)
  if cmd_opts and cmd_opts.range == 2 then
    return { start_line = cmd_opts.line1, end_line = cmd_opts.line2 }
  end
  return {}
end

--- Unified :SuperHarness <subcommand> [...] router (matches SPEC.md Section 5.2)
vim.api.nvim_create_user_command("SuperHarness", function(opts)
  local fargs = opts.fargs or {}
  local sub = (fargs[1] or "toggle"):lower()
  local r_opts = range_opts(opts)

  if sub == "toggle" then
    sh.toggle(fargs[2], { layout = fargs[3] })
  elseif sub == "open" then
    sh.open(fargs[2], { layout = fargs[3], name = fargs[4] })
  elseif sub == "resume" then
    sh.resume(fargs[2], { layout = fargs[3] })
  elseif sub == "send" then
    local text = table.concat(vim.list_slice(fargs, 2), " ")
    if text ~= "" then
      sh.send(text, { focus = true })
    else
      sh.compose(r_opts)
    end
  elseif sub == "send-context" then
    local kind = fargs[2] or (opts.range == 2 and "selection" or "file")
    sh.send_context(kind, r_opts)
  elseif sub == "compose" then
    sh.compose(r_opts)
  elseif sub == "prompt" then
    sh.pick_prompt(r_opts)
  elseif sub == "history" then
    sh.pick_history()
  elseif sub == "broadcast" then
    local text = table.concat(vim.list_slice(fargs, 2), " ")
    if text ~= "" then
      r_opts.text = text
    end
    sh.broadcast(r_opts)
  elseif sub == "tray" then
    local act = (fargs[2] or "show"):lower()
    if act == "add" then
      sh.tray_add_current(r_opts)
    elseif act == "clear" then
      sh.context.tray_clear()
      log.info("Context Tray cleared.")
    elseif act == "send" then
      sh.send_context("tray")
    else
      sh.hud("tray")
    end
  elseif sub == "review" then
    sh.review()
  elseif sub == "quickfix" then
    sh.populate_quickfix(true)
  elseif sub == "comment" then
    sh.add_comment(r_opts)
  elseif sub == "dispatch-comments" then
    sh.dispatch_comments()
  elseif sub == "sessions" or sub == "session" then
    sh.pick_session()
  elseif sub == "pick" then
    sh.pick_adapter()
  elseif sub == "hud" then
    sh.hud(fargs[2])
  elseif sub == "qa" or sub == "transcript" then
    sh.transcript({ filter = fargs[2] })
  elseif sub == "approval" or sub == "approve" then
    sh.approval()
  elseif sub == "slash" then
    sh.pick_slash()
  elseif sub == "zoom" then
    sh.zoom()
  elseif sub == "kill" then
    sh.kill(fargs[2])
  elseif sub == "install-cli" then
    local ok, msg = sh.install_cli(fargs[2])
    if ok then
      log.info(msg)
    else
      log.error(msg)
    end
  elseif sub == "reload" then
    sh.reload()
  elseif sub == "status" then
    local active = sh.state.get_active()
    local installed = vim.tbl_map(function(a) return a.name end, adapters.detect_installed())
    log.info(table.concat({
      "Active Session: " .. (active and (active.id .. " [" .. active.state .. "/" .. active.backend .. "]") or "none"),
      "Total Sessions: " .. tostring(#sh.state.list()),
      "Installed Agents: " .. (#installed > 0 and table.concat(installed, ", ") or "none"),
      "Context Tray: " .. tostring(#sh.context.tray_list()) .. " item(s) (~" .. log.format_tokens(sh.context.tray_tokens()) .. " tok)",
      "Review Comments: " .. tostring(#sh.review_engine.list_comments()),
      "RPC Socket: " .. (sh.sync.get_socket() ~= "" and sh.sync.get_socket() or "(file bridge)"),
    }, "\n"))
  else
    -- Treat unknown first arg as an adapter name for :SuperHarness claude
    sh.toggle(fargs[1], { layout = fargs[2] })
  end
end, {
  nargs = "*",
  range = true,
  complete = function(arg_lead, cmd_line)
    local parts = vim.split(cmd_line, "%s+", { trimempty = true })
    if #parts <= 2 and not cmd_line:match("%s$") then
      local pool = vim.deepcopy(SUBCOMMANDS)
      vim.list_extend(pool, vim.tbl_keys(adapters.all()))
      return vim.tbl_filter(function(item)
        return vim.startswith(item, arg_lead)
      end, pool)
    end
    local sub = (parts[2] or ""):lower()
    if sub == "open" or sub == "toggle" or sub == "resume" then
      if #parts == 2 or (#parts == 3 and not cmd_line:match("%s$")) then
        return vim.tbl_keys(adapters.all())
      end
      return { "drawer", "bottom", "float", "tab", "background", "detached" }
    elseif sub == "send-context" then
      return { "selection", "file", "scope", "diagnostics", "workspace_diagnostics", "diff", "staged", "buffers", "quickfix", "tray" }
    elseif sub == "hud" then
      return { "sessions", "tray", "review" }
    elseif sub == "tray" then
      return { "show", "add", "clear", "send" }
    elseif sub == "kill" then
      local ids = vim.tbl_map(function(s) return s.id end, sh.state.list())
      table.insert(ids, "all")
      return ids
    end
    return {}
  end,
  desc = "SuperHarness command router: :SuperHarness [toggle|open|send|send-context|review|sessions|hud|kill|reload]",
})

vim.api.nvim_create_user_command("SuperHarnessReload", function()
  sh.reload()
end, { desc = "Hot-reload super-harness.nvim without restarting Neovim" })
