local state = require("super_harness.state")
local log = require("super_harness.utils.log")
local adapters = require("super_harness.adapters")
local sync = require("super_harness.sync")

local M = {}

function M.is_available()
  return vim.fn.executable("zellij") == 1
end

--- Spawn a detached/external agent inside a Zellij pane
---@param adapter table
---@param opts table
---@return SuperHarnessSession|nil, string|nil
function M.spawn(adapter, opts)
  if not M.is_available() then
    return nil, "zellij executable not found on $PATH"
  end
  local cwd = opts.cwd or vim.fn.getcwd()
  local id = state.next_id(adapter.name, opts.name)
  local cmd = adapters.build_cmd(adapter, opts)

  local zcmd = { "zellij", "run", "--name", id, "--cwd", cwd, "--" }
  vim.list_extend(zcmd, cmd)

  local out, code = log.system(zcmd)
  if code ~= 0 then
    return nil, "zellij spawn failed: " .. vim.trim(out)
  end

  local sess = {
    id = id,
    name = opts.name or id,
    adapter = adapter,
    backend = "zellij",
    external_id = id,
    cwd = cwd,
    layout = "detached",
    state = "idle",
    started_at = os.time(),
    last_activity = os.time(),
    last_prompt = "",
    zoomed = false,
  }
  state.add(sess)
  sync.watch_project(cwd)
  return sess, nil
end

function M.send(sess, text, opts)
  local _, code = log.system({ "zellij", "action", "write-chars", text })
  if code ~= 0 then
    return false, "zellij write-chars failed"
  end
  if opts == nil or opts.submit ~= false then
    log.system({ "zellij", "action", "write", "13" })
  end
  sess.last_activity = os.time()
  return true, nil
end

function M.kill(sess)
  state.remove(sess.id)
end

return M
