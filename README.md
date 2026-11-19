# super-harness.nvim 🚀

**The universal Neovim harness & bidirectional orchestrator for CLI-based AI agents.**

Run, switch, feed rich editor context to, broadcast across, and review file edits from **any** CLI AI agent — **Google Antigravity** (`agy`), **Claude Code** (`claude`), **Aider** (`aider`), **Goose** (`goose`), **Codex** (`codex`), **Gemini CLI** (`gemini`), **OpenCode** (`opencode`), **Amp** (`amp`), **Copilot CLI** (`copilot`), **Kiro** (`kiro-cli`), **Cursor Agent** (`cursor-agent`), **Cline** (`cline`), **Pi** (`pi`), or **any custom CLI/script**.

See [`SPEC.md`](./SPEC.md) for the full architectural specification.

---

## ✨ Key Capabilities

- **Universal Agent Adapter Engine**: Built-in adapters for 13+ CLI agents with `$PATH` auto-detection, aliases (`agy` → `antigravity`), native `--resume`/`--continue`/`--model`, adapter-specific file references (`@path:L10-L20` vs `/add path`), bracketed paste protection, per-TUI `submit_delay_ms`, and live output `status_detector` (`idle`, `thinking`, `executing`, `awaiting_input`, `errored`).
- **Pluggable Execution Backends**: Built-in Neovim PTY (`nvim_term`), detached **Tmux** (`tmux`), and **Zellij** (`zellij`).
- **Ergonomic Layouts & Smart Modal Escape**: `drawer` (right/left), `bottom`, `float`, `tab`, `background`, and `detached` layouts, fullscreen zoom (`<leader>az` / `<M-z>`), single `<Esc>` passthrough to agent TUIs with `<Esc><Esc>` / `<M-Esc>` to exit terminal mode, and `gf` inside harness output to jump directly to `file:line` in your code window.
- **Multi-Dimension Context Pipeline & Context Tray**: Collect or stage active files, visual ranges, Treesitter enclosing functions/classes, LSP diagnostics (buffer/workspace), git diffs (staged/unstaged), open buffers, and quickfix lists with live token estimates.
- **Floating Markdown Prompt Composer (`<leader>ap`)**: Write prompts with Vim motions and inline `@`-token expansion (`@file`, `@sel`, `@scope`, `@diag`, `@wdiag`, `@diff`, `@staged`, `@bufs`, `@qf`, `@tray`), `<C-t>` token picker, `<C-p>` template library, `<C-s>` send, `<C-b>` broadcast.
- **Active Buffer Sync Shield**: Pre-prompt auto-flush (`:update`), `uv.fs_event` libuv file watcher, cursor/fold-preserving `:checktime` hot-reload, and side-by-side conflict diff guard when unsaved edits collide with agent disk writes.
- **Native Review & Diff Engine**: Side-by-side baseline diffsplit (`a` accept, `r` revert, `e` edit, `A` accept all, `R` revert all), quickfix change-list (`]f` / `[f`), and PR-style queued inline review comments (`<leader>ac` → `<leader>aC`).
- **Bidirectional RPC Synergy (`harness-use-neovim`)**: Automatically injects `$NVIM` / `$NVIM_LISTEN_ADDRESS` / `$SUPER_HARNESS_CONTEXT_FILE` (`live_context.json`) and registers `_G.SuperHarnessBridge`.
- **Hot-Reloadable (`:SuperHarnessReload`)**: Cleanly unloads modules, stops libuv watchers, and re-applies config without restarting Neovim.

---

## 📦 Installation (`lazy.nvim`)

```lua
{
  "pkshrestha/super-harness.nvim",
  dir = vim.fn.expand("~/git/super-harness.nvim"),
  lazy = false,
  opts = {
    default_adapter = nil, -- auto-detects first installed agent
    ui = {
      layout = "drawer", -- "drawer" | "bottom" | "float" | "tab" | "background" | "detached"
    },
    sync = {
      auto_save_on_send = true,
      silent_autoread = true,
      fs_watch = true,
      conflict_action = "diff",
    },
  },
  config = function(_, opts)
    require("super_harness").setup(opts)
  end,
}
```

### Lualine Component

```lua
{
  function() return require("super_harness").statusline() end,
  cond = function() return require("super_harness").statusline() ~= "" end,
}
```

---

## 🧪 Testing & Health

```bash
bash tests/run_tests.sh
```

Inside Neovim, run `:checkhealth super_harness`.
