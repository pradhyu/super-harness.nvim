local log = require("super_harness.utils.log")

local M = {}

M.defaults = {
  -- Default active agent adapter ("antigravity" | "claude" | "aider" | "goose" | "codex" | "gemini" | "opencode" | ... | nil for auto-detect)
  default_adapter = nil,

  -- Priority order when auto-detecting installed CLI agents
  preferred_order = {
    "antigravity",
    "claude",
    "codex",
    "gemini",
    "opencode",
    "aider",
    "goose",
    "amp",
    "copilot",
    "kiro",
    "cursor",
    "cline",
    "pi",
  },

  -- Execution backend ("nvim_term" | "tmux" | "zellij")
  backend = "nvim_term",

  -- Window UI & Layout options
  ui = {
    layout = "drawer", -- "drawer" | "bottom" | "float" | "tab" | "background" | "detached"
    drawer = {
      position = "right", -- "right" | "left"
      width = 0.40,
    },
    bottom = {
      height = 0.35,
    },
    float = {
      width = 0.85,
      height = 0.85,
      border = "rounded",
    },
    winblend = 0,
    auto_insert = true,
    picker = "auto", -- "auto" | "snacks" | "telescope" | "select"
    icons = {
      harness = "󰚩",
      idle = "●",
      thinking = "◐",
      executing = "⚙",
      awaiting_input = "▲",
      errored = "✖",
      exited = "○",
      tray = "󰆧",
      comment = "",
    },
  },

  -- Key ergonomics & smart escaping
  default_keymaps = true,
  keymaps = {
    toggle = "<leader>aa",
    toggle_float = "<leader>aA",
    new_session = "<leader>an",
    select_session = "<leader>aS",
    hud = "<leader>ah",
    compose = "<leader>ap",
    send_selection = "<leader>as",
    send_file = "<leader>af",
    send_diagnostics = "<leader>ad",
    send_diff = "<leader>aD",
    tray_stage = "<leader>at",
    tray_open = "<leader>aT",
    prompt_library = "<leader>al",
    prompt_history = "<leader>aH",
    broadcast = "<leader>ab",
    review_changes = "<leader>ar",
    add_comment = "<leader>ac",
    dispatch_comments = "<leader>aC",
    slash_commands = "<leader>a/",
    resume = "<leader>aR",
    zoom = "<leader>az",
    kill = "<leader>ax",
    smart_escape = "<M-Esc>",
  },

  -- Context formatting options
  context = {
    include_filepath = true,
    include_line_numbers = true,
    ref_only_for_files = true,
    treesitter_expand = true,
    max_context_lines = 1000,
    bracketed_paste = true,
    token_budget_warn = 32000,
    clear_tray_on_send = true,
  },

  -- Buffer synchronization & safety (Buffer Sync Shield)
  sync = {
    auto_save_on_send = true,
    silent_autoread = true,
    fs_watch = true,
    conflict_action = "diff", -- "diff" | "ask" | "keep_buffer"
  },

  -- Session & telemetry behavior
  session = {
    idle_threshold_ms = 2500,
    auto_submit = true,
    start_in_project_root = true,
  },

  -- Bidirectional RPC & harness-use-neovim synergy
  rpc = {
    enabled = true,
    inject_nvim_socket = true,
    write_live_context = true,
  },

  -- Prompt templates & history
  prompts = {
    custom = {},
    history_max = 200,
    history_file = vim.fn.stdpath("state") .. "/super_harness/history.json",
  },

  -- Adapter overrides or custom agent definitions
  adapters = {},

  -- Notifications & statusline
  notifications = {
    enabled = true,
    notify_on_complete = true,
    sound = false,
  },

  -- Load repo-local .superharness.json / .superharness.lua
  project_config = true,
  debug = false,
}

M.options = vim.deepcopy(M.defaults)

--- Load project-local overrides from .superharness.json or .superharness.lua
---@param root? string
---@return table
function M.load_project_config(root)
  local dir = root or vim.fn.getcwd()
  local json_path = dir .. "/.superharness.json"
  local lua_path = dir .. "/.superharness.lua"

  if vim.fn.filereadable(json_path) == 1 then
    local decoded = log.read_json(json_path)
    if type(decoded) == "table" then
      return decoded
    end
  end
  if vim.fn.filereadable(lua_path) == 1 then
    local chunk, err = loadfile(lua_path)
    if chunk then
      local ok, res = pcall(chunk)
      if ok and type(res) == "table" then
        return res
      end
    elseif err then
      log.warn("Failed to load .superharness.lua: " .. tostring(err))
    end
  end
  return {}
end

--- Validate and normalize user options
---@param opts? table
---@return table
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if merged.project_config then
    local proj = M.load_project_config()
    if next(proj) ~= nil then
      merged = vim.tbl_deep_extend("force", merged, proj)
    end
  end
  log.debug_enabled = merged.debug == true
  M.options = merged
  return M.options
end

return M
