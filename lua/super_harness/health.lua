local adapters = require("super_harness.adapters")
local sync = require("super_harness.sync")
local git = require("super_harness.context.git")

local M = {}

function M.check()
  local health = vim.health
  health.start("super-harness.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    local v = vim.version()
    health.ok(string.format("Neovim %d.%d.%d (>= 0.10 required)", v.major, v.minor, v.patch))
  else
    health.error("Neovim >= 0.10.0 is required")
  end

  local installed = adapters.detect_installed()
  if #installed > 0 then
    local names = vim.tbl_map(function(a)
      return string.format("%s (%s)", a.name, a.bin)
    end, installed)
    health.ok("Installed CLI agents: " .. table.concat(names, ", "))
  else
    health.warn("No built-in CLI agents detected on $PATH (install agy, claude, aider, goose, codex, gemini, opencode, etc.)")
  end

  if vim.fn.executable("git") == 1 then
    local root = git.git_root()
    health.ok("git available" .. (root and (" (repo: " .. root .. ")") or ""))
  else
    health.warn("git not found on $PATH (using snapshot fallback for review diffs)")
  end

  if vim.fn.executable("tmux") == 1 then
    health.ok("tmux backend available")
  else
    health.info("tmux not found (optional detached backend)")
  end

  if vim.fn.executable("zellij") == 1 then
    health.ok("zellij backend available")
  else
    health.info("zellij not found (optional detached backend)")
  end

  local sock = sync.get_socket()
  if sock ~= "" then
    health.ok("Bidirectional RPC socket active: " .. sock)
  else
    health.info("No $NVIM RPC socket active (live_context.json bridge active at " .. sync.live_context_path .. ")")
  end

  local bin_dir = sync.get_bin_dir()
  if bin_dir and vim.fn.executable(bin_dir .. "/nvim-cli") == 1 then
    health.ok("Bundled nvim-cli executable ready: " .. bin_dir .. "/nvim-cli")
  else
    health.warn("Bundled nvim-cli not found or not executable in plugin bin/ directory")
  end
end

return M
