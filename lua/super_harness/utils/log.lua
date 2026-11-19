local M = {}

M.levels = {
  DEBUG = vim.log.levels.DEBUG,
  INFO = vim.log.levels.INFO,
  WARN = vim.log.levels.WARN,
  ERROR = vim.log.levels.ERROR,
}

M.debug_enabled = false

--- Structured notification helper
---@param msg string
---@param level? integer
function M.notify(msg, level)
  vim.schedule(function()
    vim.notify(tostring(msg), level or vim.log.levels.INFO, { title = "SuperHarness" })
  end)
end

function M.debug(msg)
  if M.debug_enabled then
    M.notify("[DEBUG] " .. tostring(msg), vim.log.levels.DEBUG)
  end
end

function M.info(msg)
  M.notify(msg, vim.log.levels.INFO)
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

--- Walk /proc/<pid>/stat to collect ancestor PIDs of the current Neovim process (Linux)
---@return table<integer, boolean>
local function get_ancestor_pids()
  local pids = {}
  local cur = vim.fn.getpid()
  for _ = 1, 16 do
    if not cur or cur <= 1 or pids[cur] then
      break
    end
    pids[cur] = true
    local ok, lines = pcall(vim.fn.readfile, string.format("/proc/%d/stat", cur))
    if not ok or not lines or not lines[1] then
      break
    end
    -- Format: pid (comm) state ppid ...
    local rest = lines[1]:match("%)%s+%S+%s+(%d+)")
    cur = tonumber(rest)
  end
  return pids
end

--- Best-effort focus of the OS terminal window hosting this Neovim instance (Hyprland)
function M.focus_host_window()
  if not vim.env.HYPRLAND_INSTANCE_SIGNATURE or vim.env.HYPRLAND_INSTANCE_SIGNATURE == "" then
    return
  end
  if vim.fn.executable("hyprctl") ~= 1 or not vim.system then
    return
  end
  local ancestors = get_ancestor_pids()
  pcall(vim.system, { "hyprctl", "clients", "-j" }, { text = true, timeout = 2000 }, function(res)
    if not res or res.code ~= 0 or not res.stdout or res.stdout == "" then
      return
    end
    local ok, clients = pcall(vim.json.decode, res.stdout)
    if not ok or type(clients) ~= "table" then
      return
    end
    for _, c in ipairs(clients) do
      if type(c) == "table" and c.pid and ancestors[tonumber(c.pid)] and c.address then
        pcall(vim.system, { "hyprctl", "dispatch", "focuswindow", "address:" .. tostring(c.address) }, { detach = true })
        return
      end
    end
  end)
end

--- Send an asynchronous OS desktop notification (notify-send on Linux, osascript on macOS).
--- Silently no-ops in headless mode (e.g. unit tests) or if no notifier binary is installed.
--- When `opts.on_click` is provided on Linux, uses `notify-send -A` so clicking the notification invokes the callback.
---@param title string
---@param body string
---@param opts? { urgency?: "low"|"normal"|"critical", on_click?: fun(), action_label?: string }
function M.desktop_notify(title, body, opts)
  opts = opts or {}
  vim.schedule(function()
    if #vim.api.nvim_list_uis() == 0 then
      return
    end
    local urgency = opts.urgency or "normal"
    local has_click = type(opts.on_click) == "function"
    if vim.fn.executable("notify-send") == 1 then
      if has_click and vim.system then
        local label = opts.action_label or "Open in Neovim"
        local cmd = {
          "notify-send",
          "-a",
          "SuperHarness",
          "-u",
          urgency,
          "-A",
          "default=" .. tostring(label),
          tostring(title),
          tostring(body),
        }
        pcall(vim.system, cmd, { text = true }, function(res)
          if res and res.code == 0 and vim.trim(res.stdout or "") == "default" then
            vim.schedule(function()
              pcall(opts.on_click)
            end)
          end
        end)
        return
      end
      local cmd = { "notify-send", "-a", "SuperHarness", "-u", urgency, tostring(title), tostring(body) }
      if vim.system then
        pcall(vim.system, cmd, { detach = true })
      else
        pcall(vim.fn.jobstart, cmd, { detach = true })
      end
    elseif vim.fn.executable("osascript") == 1 then
      local esc_title = tostring(title):gsub('"', '\\"')
      local esc_body = tostring(body):gsub('"', '\\"')
      local cmd = { "osascript", "-e", string.format('display notification "%s" with title "%s"', esc_body, esc_title) }
      if vim.system then
        pcall(vim.system, cmd, { detach = true })
      else
        pcall(vim.fn.jobstart, cmd, { detach = true })
      end
    end
  end)
end

--- Run a synchronous system command safely
---@param cmd string[]
---@param opts? { cwd?: string, timeout?: integer }
---@return string stdout, integer code
function M.system(cmd, opts)
  opts = opts or {}
  if vim.system then
    local ok, obj = pcall(function()
      return vim.system(cmd, {
        text = true,
        cwd = opts.cwd,
        timeout = opts.timeout or 4000,
      }):wait()
    end)
    if ok and obj then
      return obj.stdout or "", obj.code or 1
    end
    return "", 1
  end
  local out = vim.fn.system(cmd)
  return out or "", vim.v.shell_error
end

--- Ensure parent directory exists safely
---@param filepath string
---@return boolean
function M.ensure_dir(filepath)
  local dir = vim.fn.fnamemodify(filepath, ":h")
  if dir and dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    local ok = pcall(vim.fn.mkdir, dir, "p")
    return ok and vim.fn.isdirectory(dir) == 1
  end
  return true
end

--- Read JSON file safely
---@param filepath string
---@return table|nil
function M.read_json(filepath)
  if not filepath or vim.fn.filereadable(filepath) ~= 1 then
    return nil
  end
  local lines = vim.fn.readfile(filepath)
  if not lines or #lines == 0 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

--- Write JSON file safely
---@param filepath string
---@param data table
---@return boolean
function M.write_json(filepath, data)
  if not M.ensure_dir(filepath) then
    return false
  end
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then
    return false
  end
  local wok = pcall(vim.fn.writefile, { encoded }, filepath)
  return wok
end

--- Estimate LLM tokens (~4 chars per token)
---@param text string|nil
---@return integer
function M.estimate_tokens(text)
  if type(text) ~= "string" or text == "" then
    return 0
  end
  return math.max(1, math.ceil(#text / 4))
end

---@param count integer
---@return string
function M.format_tokens(count)
  count = tonumber(count) or 0
  if count >= 1000 then
    return string.format("%.1fk", count / 1000)
  end
  return tostring(count)
end

---@param secs number
---@return string
function M.format_duration(secs)
  secs = math.max(0, math.floor(tonumber(secs) or 0))
  if secs < 60 then
    return string.format("%ds", secs)
  elseif secs < 3600 then
    return string.format("%dm %ds", math.floor(secs / 60), secs % 60)
  end
  return string.format("%dh %dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60))
end

---@param str string
---@param max_len integer
---@return string
function M.truncate(str, max_len)
  if type(str) ~= "string" then
    return ""
  end
  if #str <= max_len then
    return str
  end
  if max_len <= 3 then
    return str:sub(1, max_len)
  end
  return str:sub(1, max_len - 3) .. "..."
end

--- Check whether a buffer is a normal editable code buffer
---@param bufnr integer
---@return boolean
function M.is_code_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.b[bufnr].super_harness_buf then
    return false
  end
  return vim.bo[bufnr].buftype == ""
end

return M
