local log = require("super_harness.utils.log")

local M = {}

local uv = vim.uv or vim.loop

---@type table<string, any> dir -> uv_fs_event_t
M._handles = {}
---@type any
M._debounce_timer = nil

--- Start watching a directory with libuv fs_event
---@param dir string
---@param on_change fun(dir:string, filename:string|nil)
---@return boolean
function M.watch(dir, on_change)
  if not uv or not uv.new_fs_event or not dir or dir == "" then
    return false
  end
  if vim.fn.isdirectory(dir) ~= 1 then
    return false
  end
  if M._handles[dir] then
    return true
  end

  local handle, err = uv.new_fs_event()
  if not handle then
    log.debug("uv.new_fs_event failed: " .. tostring(err))
    return false
  end

  local ok = pcall(function()
    handle:start(dir, {}, function(watch_err, filename)
      if watch_err then
        return
      end
      if filename and (filename:match("^%.git") or filename:match("%.swp$") or filename:match("~$")) then
        return
      end
      -- Debounce rapid multi-file writes from agents
      if M._debounce_timer then
        pcall(function()
          M._debounce_timer:stop()
          M._debounce_timer:close()
        end)
        M._debounce_timer = nil
      end
      local t = uv.new_timer()
      if t then
        M._debounce_timer = t
        t:start(120, 0, function()
          pcall(function()
            t:stop()
            t:close()
          end)
          M._debounce_timer = nil
          vim.schedule(function()
            pcall(on_change, dir, filename)
          end)
        end)
      end
    end)
  end)

  if not ok then
    pcall(function()
      handle:close()
    end)
    return false
  end

  M._handles[dir] = handle
  return true
end

--- Stop watching a specific directory
---@param dir string
function M.unwatch(dir)
  local h = M._handles[dir]
  if h then
    pcall(function()
      h:stop()
      h:close()
    end)
    M._handles[dir] = nil
  end
end

--- Stop all active libuv watchers (called by :SuperHarnessReload & VimLeavePre)
function M.stop_all()
  if M._debounce_timer then
    pcall(function()
      M._debounce_timer:stop()
      M._debounce_timer:close()
    end)
    M._debounce_timer = nil
  end
  for dir, h in pairs(M._handles) do
    pcall(function()
      h:stop()
      h:close()
    end)
    M._handles[dir] = nil
  end
end

--- Return list of currently watched directories
---@return string[]
function M.list()
  return vim.tbl_keys(M._handles)
end

return M
