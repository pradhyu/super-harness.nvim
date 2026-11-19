local M = {}

---@alias AgentState "starting"|"idle"|"thinking"|"executing"|"awaiting_input"|"errored"|"exited"

---@class SuperHarnessSession
---@field id string
---@field name string Human-friendly session name
---@field adapter table
---@field backend string "nvim_term"|"tmux"|"zellij"
---@field bufnr integer|nil
---@field winid integer|nil
---@field job_id integer|nil
---@field external_id string|nil Tmux pane/window or Zellij session id
---@field cwd string
---@field layout string
---@field state AgentState
---@field started_at integer
---@field last_activity integer
---@field last_prompt string
---@field zoomed boolean
---@field saved_layout_dims? table
---@field idle_timer? any

---@type table<string, SuperHarnessSession>
M.sessions = {}
---@type string[]
M.order = {}
---@type string|nil
M.active_id = nil
---@type table<string, integer>
M._counters = {}
---@type integer|nil
M.last_code_win = nil

--- Generate a unique session ID
---@param adapter_name string
---@param custom_name? string
---@return string
function M.next_id(adapter_name, custom_name)
  if custom_name and custom_name ~= "" and not M.sessions[custom_name] then
    return custom_name
  end
  M._counters[adapter_name] = (M._counters[adapter_name] or 0) + 1
  return string.format("%s#%d", adapter_name, M._counters[adapter_name])
end

--- Register a newly created session
---@param sess SuperHarnessSession
function M.add(sess)
  M.sessions[sess.id] = sess
  table.insert(M.order, sess.id)
  M.active_id = sess.id
end

--- Remove a session from registry
---@param id string
function M.remove(id)
  M.sessions[id] = nil
  M.order = vim.tbl_filter(function(x)
    return x ~= id
  end, M.order)
  if M.active_id == id then
    M.active_id = M.order[#M.order]
  end
end

--- Get session by ID
---@param id? string
---@return SuperHarnessSession|nil
function M.get(id)
  if id and M.sessions[id] then
    return M.sessions[id]
  end
  return nil
end

--- Get active session (falling back to most recent live session)
---@return SuperHarnessSession|nil
function M.get_active()
  if M.active_id and M.sessions[M.active_id] then
    return M.sessions[M.active_id]
  end
  for i = #M.order, 1, -1 do
    local s = M.sessions[M.order[i]]
    if s and s.state ~= "exited" then
      M.active_id = s.id
      return s
    end
  end
  return nil
end

--- Set active session by ID
---@param id string
---@return boolean
function M.set_active(id)
  if M.sessions[id] then
    M.active_id = id
    return true
  end
  return false
end

--- List all sessions in creation order
---@return SuperHarnessSession[]
function M.list()
  local out = {}
  for _, id in ipairs(M.order) do
    if M.sessions[id] then
      table.insert(out, M.sessions[id])
    end
  end
  return out
end

--- Reset all state (used by :SuperHarnessReload)
function M.reset()
  M.sessions = {}
  M.order = {}
  M.active_id = nil
  M._counters = {}
end

return M
