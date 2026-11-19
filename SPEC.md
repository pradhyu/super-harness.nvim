# super-harness.nvim 🚀
### The Ultimate Neovim Harness & Orchestrator for CLI-Based AI Agents

> **Vision**: Transform Neovim into an intelligent, frictionless command center for modern CLI-based autonomous agents (Google Antigravity, Anthropic Claude Code, Aider, Goose, OpenHands, and custom agent CLIs). Bridge the chasm between raw terminal TUIs and deep editor awareness with bidirectional context injection, zero-conflict buffer synchronization, native diff reviews, multi-session management, and seamless keychord ergonomics.

---

## 1. Executive Summary & Problem Space

### 1.1 The Shift: From API Copilots to Autonomous CLI Agents
The state of the art in AI-assisted software engineering has rapidly evolved from single-completion copilot plugins (e.g., inline autocompletion or static chat windows via OpenAI/Anthropic APIs) to **autonomous CLI agents** such as:
- **Google Antigravity (`agy`)**: Multi-agent swarms, background workflows, subagents, and native tool execution.
- **Anthropic Claude Code (`claude`)**: Interactive terminal-based agent with bash execution, file editing, and auto-compaction.
- **Aider (`aider`)**: Git-native pair-programming agent with repository map indexing.
- **Goose / OpenHands / Codex CLI**: Extensible agentic harnesses with MCP (Model Context Protocol) toolchains.

These agents run as full-blown terminal interactive applications (TUIs) that execute shell commands, edit files directly on disk, inspect git status, run test suites, and coordinate multi-step workflows.

### 1.2 The Dilemma in Neovim Today
Neovim users currently face an uncomfortable choice:
1. **Alt-tabbing away** to an external terminal emulator (Ghostty, WezTerm, Alacritty, Kitty, Tmux):
   - Fast TUI, but loses all editor context (cursor position, visual selections, LSP diagnostics, open buffers, folded code).
   - Constant copy-pasting of file paths, line numbers, and error messages.
2. **Opening a raw `:terminal` or using generic terminal wrappers (`toggleterm.nvim`, `snacks.terminal`)**:
   - Terminal mode keybinding collision hell (pressing `<Esc>` enters normal mode vs. escaping an agent prompt or menu).
   - Text injection is primitive: dumping raw multiline text into the terminal buffer can break interactive prompts, trigger accidental shell execution, or choke on special characters.
   - No agent status tracking: Neovim doesn't know if the agent is thinking, running a tool, or waiting for approval.
3. **Using nascent single-tool plugins (`claude-code.nvim`, `aider.nvim`)**:
   - Rigidly tied to a single binary.
   - Incomplete handling of file collisions (agent writes to disk while Neovim holds unsaved buffers).
   - Primitive diffing capabilities (relying on raw terminal git diffs instead of Neovim's superior native diff view, quickfix list, or floating previews).

### 1.3 The Mission: `super-harness.nvim`
`super-harness.nvim` is designed from the ground up as a **universal, agent-agnostic harness and bidirectional control plane**. It treats CLI agents as first-class citizens inside Neovim, marrying the unconstrained power of CLI agents with the precision and speed of Neovim's editing buffer and LSP ecosystem.

---

## 2. Comparative Analysis: What Exists vs. What We Are Building

| Feature / Dimension | Raw `:terminal` / `toggleterm` | `claude-code.nvim` (early forks) | `avante.nvim` / `codecompanion` | `aider.nvim` | **`super-harness.nvim` (Our Vision)** |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Agent Paradigm** | Shell command | Hardcoded to `claude` | Direct LLM API / HTTP (not CLI agent) | Hardcoded to `aider` | **Universal Adapter System** (Antigravity, Claude Code, Aider, Goose, Custom) |
| **Terminal Key Ergonomics** | Breaks on `<Esc>` / insert mode clashes | Basic `<C-\><C-N>` escape | N/A (Custom buffer UI) | Manual terminal switching | **Modal-Aware Smart Escape & Passthrough Layer** |
| **Context Injection** | None (manual paste) | Selected text sent via `chansend` | Custom API prompt formatting | Basic `/add` file injection | **Multi-Dimension Context Engine** (Treesitter node, LSP diagnostics, Git diff, `@file:range`, quickfix) |
| **File Collision Shield** | None (`File changed on disk` alert dialogs) | None / rudimentary `checktime` | N/A (controls buffer directly) | Rudimentary auto-reload | **Active Buffer Sync Shield** (pre-prompt auto-save, libuv file-watchers, zero-dialog safe hot-reload) |
| **Diff & Review Experience** | Read terminal text | None (rely on git in CLI) | Split buffer diff | None | **Native Review Engine** (Hunk inspector, 3-way diffsplit, quickfix change-list, virtual-text diffs) |
| **Bidirectional RPC Synergy** | None | None | Custom Lua functions | None | **Full Bidirectional Bridge** (Direct integration with `harness-use-neovim` and MCP servers) |
| **Multi-Session & Swarms** | Unmanaged terminal buffers | Single session | Single active thread | Single session | **Named Multi-Session Manager** (e.g., Background Reviewer, Active Feature Builder, Quick Ask) |
| **Statusline & UI Feedback** | Static terminal status | Minimal | Spinners on floating window | None | **Live Agent State Detection** (Idle, Thinking, Executing, Awaiting Approval, Errored) |
| **Detached / Daemon Sessions** | Lost if Neovim closes | Lost | Lost | Lost | **Pluggable Session Backends** (Built-in Neovim PTY, Tmux, Zellij, or LibUV daemon) |

---

## 3. Core Architectural Pillars

```
+-----------------------------------------------------------------------------------+
|                                SUPER-HARNESS.NVIM                                 |
+-----------------------------------------------------------------------------------+
|  [Keychord / Command Router]  -->  [Smart Mode / Escape Interceptor]              |
|                                                                                   |
|  +--------------------+     +---------------------+     +----------------------+  |
|  | Context Packager   |     | Session & Backend   |     | Buffer Sync Shield   |  |
|  | - Treesitter AST   |     | - Neovim PTY Term   |     | - Pre-prompt flush   |  |
|  | - LSP Diagnostics  |     | - Tmux / Zellij     |     | - libuv fs watch     |  |
|  | - @File / Line Ref |     | - Multi-agent tabs  |     | - Silent hot-reload  |  |
|  +--------------------+     +---------------------+     +----------------------+  |
|                                                                                   |
|  +-----------------------------------------------------------------------------+  |
|  | Universal Agent Adapters:                                                   |  |
|  | [Google Antigravity]   [Claude Code]   [Aider]   [Goose]   [Custom Shell]   |  |
|  +-----------------------------------------------------------------------------+  |
|                                                                                   |
|  +--------------------+     +---------------------+     +----------------------+  |
|  | Review & Diff Hub  |     | Status & Telemetry  |     | Bidirectional RPC    |  |
|  | - 3-way diff split |     | - Idle/Busy/Pending |     | - 'harness-use-nvim' |  |
|  | - Hunk accept/rej  |     | - Lualine indicator |     | - Neovim as MCP tool |  |
|  | - Quickfix staged  |     | - Toast alerts      |     | - File open / select |  |
|  +--------------------+     +---------------------+     +----------------------+  |
+-----------------------------------------------------------------------------------+
```

### Pillar I: Universal Agent Adapter Engine
The harness makes no assumptions about specific agent CLI flags or interactive prompts. Every agent is defined by a clean, declarative Lua adapter table:

```lua
---@class AgentAdapter
---@field name string Agent identifier (e.g. "antigravity", "claude", "aider")
---@field cmd string|string[] Executable and base flags
---@field env table<string, string> Environment variables (e.g., NVIM_SERVER_SOCKET)
---@field prompt_arg string|nil Flag to pass one-shot prompt (e.g., "-p" or nil for interactive)
---@field context_format fun(ctx: ContextPayload): string How files, selections, and diagnostics are serialized
---@field status_detector fun(term_output: string): AgentState Pattern matcher for agent states
---@field exit_action "keep"|"close"|"hide" Behavior when agent terminates
```

- **Built-in Adapters out of the box**:
  - `antigravity`: Configured for Google Antigravity CLI (`agy`), with multi-subagent awareness, slash command passthrough (`/plan`, `/boost`, `/teamwork`), and markdown artifact handling.
  - `claude`: Configured for Claude Code (`claude`), supporting compact mode, permission approval prompts, and cost/token tracking.
  - `aider`: Configured with git repository map awareness, `/add` context injection, and model selector flags.
  - `goose`: Configured for Goose CLI with MCP extensions.
  - `custom`: Easily hook any internal company agent or script.

---

### Pillar II: Ergonomic TUI & Terminal Windowing

1. **Flexible Layout Modes**:
   - **Slide-out Drawer**: Dedicated sidebar (right or left, 40% width) that preserves editor buffer layout.
   - **Bottom Split**: Traditional terminal drawer (height adjustable, toggled with a single chord).
   - **Smart Floating Window**: Centered modal with backdrop dimming, rounded borders, and dynamic sizing.
   - **Background Worker**: Agent runs invisibly in headless PTY; pops up only when it needs confirmation or finishes.
   - **Detached Multiplexer**: Spawns or connects to an existing `tmux` or `zellij` session, allowing the agent to outlive the Neovim session.

2. **Smart Escape & Keychord Routing**:
   - *The Problem*: In Neovim `:terminal`, pressing `<Esc>` either gets swallowed by the agent TUI or, if mapped to `<C-\><C-N>`, makes it impossible to use Escape inside interactive CLI TUIs (like closing menus in Claude Code or exiting vi-mode inside the agent prompt).
   - *The Solution*:
     - **Double-Escape / Chord Switching**: A seamless escape strategy where single `<Esc>` is forwarded directly to the agent TTY, while `<C-q>`, `<M-Esc>`, or a dedicated leader toggle (`<leader>aa`) toggles between Terminal Normal Mode and Terminal Insert Mode.
     - **Floating Quick-Input Bar**: Allows typing prompt instructions in a native Neovim buffer (with full autocomplete, snippets, and vim motions) and sending it directly into the agent session on `<CR>`.

---

### Pillar III: Rich Context Injection Pipeline

Agents are only as effective as the context they receive. Instead of naive text dumping, `super-harness.nvim` provides an intelligent context packager:

1. **Precision Selection & Treesitter Awareness**:
   - **Selected Lines**: Sends file path, line bounds, and formatted content (`@src/main.rs:45-80`).
   - **Treesitter Node**: Automatically expands selection to the enclosing function, class, or method under the cursor.
   - **Current Buffer / Visible Viewport**: Injects the active file or only the lines currently visible in the active window.

2. **LSP Diagnostics & Quickfix Integration**:
   - Inject all errors/warnings under the cursor or across the current file.
   - Example prompt: `/fix-diagnostics` bundles the LSP error message, code, source line, and surrounding context into a structured prompt.
   - Inject the entire current `quickfix` or `loclist` (e.g. from failed compiler builds or tests).

3. **Git & Workspace Context**:
   - Inject staged or unstaged git diffs directly into the agent prompt without leaving Neovim.
   - Inject project root relative paths automatically.

4. **Bracketed Paste & Terminal Sanitization**:
   - Protects multi-line code snippets with ANSI bracketed paste sequences (`\x1b[200~` ... `\x1b[201~`) so the CLI agent does not prematurely execute half-pasted code or mess up whitespace indentation.

---

### Pillar IV: Active Buffer Sync Shield (Zero-Conflict Guarantee)

One of the greatest hazards of running CLI agents inside Neovim is **disk-vs-buffer desynchronization**: the agent uses tools to edit files directly on disk while the user has unsaved buffers in Neovim.

`super-harness.nvim` eliminates this with a 3-layer safety shield:
1. **Pre-Prompt Auto-Flush**:
   - The moment a prompt or context is sent to the agent, the harness automatically flushes modified buffers (`:wall` or target file save) to disk.
2. **libuv File Watcher & Auto-Reload**:
   - Leverages `vim.loop` (`uv.fs_event`) to track project files.
   - When the agent writes a file to disk:
     - If the buffer is unmodified in Neovim: silently and instantaneously reloads the buffer (`:checktime` without jarring confirm dialogs).
     - If the buffer has unsaved changes made by the user while the agent was running: safely pauses and prompts with a side-by-side diff resolution window instead of blindly overwriting.
3. **Cursor & Viewport Preservation**:
   - Reloading a buffer after agent edits preserves cursor line, column, view folds, and jump history.

---

### Pillar V: Native Review, Diff & Hunk Inspection Engine

When an agent changes 5 files across your repository, looking at terminal logs is frustrating. `super-harness.nvim` brings the full power of Neovim's diffing into the workflow:

1. **Agent Turn Change Tracker**:
   - Watches git state before and after each agent turn.
   - Populates a dedicated **Agent Review List** (or Quickfix list) of all files touched by the agent during the turn.

2. **Interactive 3-Way & Inline Diff Inspection**:
   - Jump between changed files with `]f` / `[f`.
   - Open a side-by-side `:diffsplit` comparing `HEAD` (or pre-turn state) against the agent's new disk changes.
   - One-key operations inside the review window:
     - `a`: Accept hunk / stage.
     - `r`: Reject hunk / restore.
     - `e`: Edit manually.
     - `A`: Accept all changes from this agent turn.
     - `R`: Revert all changes from this agent turn (`git restore`).

3. **Virtual Text Mini-Diffs**:
   - Displays subtle virtual text annotations (added, removed, modified counts) directly in the active buffer's gutter or signcolumn as soon as the agent completes its edits.

---

### Pillar VI: Bidirectional Agent-to-Editor Protocol & Synergy with `harness-use-neovim`

Neovim shouldn't just be a passive display for the agent; the agent should be able to reach into Neovim, and Neovim should respond.

1. **Synergy with `harness-use-neovim`**:
   - `harness-use-neovim` already provides the reverse RPC pipe: a CLI tool and RPC bridge for external scripts to control the host Neovim instance (`$NVIM` socket).
   - `super-harness.nvim` seamlessly injects the active Neovim socket (`NVIM_LISTEN_ADDRESS` / `NVIM`) into the agent's subshell environment.
   - This enables CLI agents (via custom tools or MCP sidecars) to:
     - Query open buffers and cursor positions directly via RPC.
     - Tell Neovim to open a specific file and highlight a line (`nvim-cli open file.lua:10`).
     - Request user selection or confirmation inside Neovim's native floating UI (`vim.ui.select` / `vim.ui.input`).

2. **Agent Telemetry & State Detection**:
   - Monitors terminal ANSI output and PTY state using pattern recognition:
     - **Thinking**: Agent is waiting for model stream.
     - **Tool Executing**: Agent is running bash commands or editing files.
     - **Awaiting User Input**: Agent has prompted the user for permission or input.
     - **Idle / Done**: Turn completed.
   - Exposes these states to:
     - Statusline (Lualine, Heirline, Mini.statusline).
     - Winbar indicators.
     - Desktop notifications (`vim.notify` or system notifications via `libnotify` / Omarchy desktop alerts).

---

### Pillar VII: Multi-Session & Background Worker Management

Modern workflows often involve more than one agent:
- Session 1: **Main Planner / Interactive Chat** (Claude Code in floating window).
- Session 2: **Background Test & Reviewer Swarm** (Google Antigravity subagent running `pytest` in background).
- Session 3: **Ad-hoc Doc / Explainer** (Aider in right drawer).

`super-harness.nvim` provides a session manager:
- `:SuperHarness session list` / Telescope / Snacks picker to switch between active agent sessions.
- Ability to name sessions (e.g. `feat-auth`, `refactor-db`, `bg-linter`).
- Background notifications: Get notified with a toast when a background agent completes its run, with a one-click/one-key shortcut to jump directly to its output.

---

## 4. Technical Architecture & Module Structure

The plugin is structured cleanly in modern Lua under `lua/super_harness/`:

```
super-harness.nvim/
├── .gitignore
├── LICENSE
├── README.md
├── SPEC.md                           <-- You are here
├── doc/
│   └── super-harness.txt             <-- Vimdoc documentation
├── plugin/
│   └── super_harness.lua             <-- Ex-commands and autocmd registration
└── lua/
    └── super_harness/
        ├── init.lua                  <-- Entry point: setup(), reload()
        ├── config.lua                <-- Options normalization & validation
        ├── state.lua                 <-- Session registry and active harness state
        ├── adapters/                 <-- Agent adapters
        │   ├── init.lua              <-- Adapter loader & interface
        │   ├── antigravity.lua       <-- Google Antigravity adapter (agy)
        │   ├── claude.lua            <-- Anthropic Claude Code adapter
        │   ├── aider.lua             <-- Aider adapter
        │   ├── goose.lua             <-- Goose CLI adapter
        │   └── custom.lua            <-- Generic shell / custom CLI adapter
        ├── backends/                 <-- Execution environments
        │   ├── init.lua              <-- Backend interface
        │   ├── nvim_term.lua         <-- Built-in Neovim PTY (:terminal)
        │   ├── tmux.lua              <-- Tmux pane / window backend
        │   └── zellij.lua            <-- Zellij session backend
        ├── context/                  <-- Context extraction pipeline
        │   ├── init.lua              <-- Context builder
        │   ├── treesitter.lua        <-- AST node extraction
        │   ├── lsp.lua               <-- Diagnostics & symbol extraction
        │   ├── git.lua               <-- Diff & repo state extraction
        │   └── sanitizer.lua         <-- Bracketed paste & prompt escaping
        ├── sync/                     <-- Buffer synchronization & safety
        │   ├── init.lua              <-- Sync coordinator
        │   ├── watcher.lua           <-- libuv file event watcher
        │   └── reloader.lua          <-- Safe checktime & conflict resolver
        ├── review/                   <-- Review & Diff Engine
        │   ├── init.lua              <-- Turn diff tracker
        │   ├── diffsplit.lua         <-- 3-way side-by-side diff
        │   └── quickfix.lua          <-- Changed files list & hunk stepper
        ├── ui/                       <-- Windowing & UI components
        │   ├── window.lua            <-- Float, split, and drawer management
        │   ├── input.lua             <-- Floating vim prompt input buffer
        │   ├── picker.lua            <-- Session & adapter pickers
        │   └── statusline.lua        <-- Lualine / statusline integration
        └── utils/                    <-- Helper functions
            ├── log.lua               <-- Structured logging
            └── keymaps.lua           <-- Ergonomic keymap registration
```

---

## 5. User API & Keybinding Ergonomics

### 5.1 Lua Configuration Specification (`setup`)

```lua
require("super_harness").setup({
  -- Default active agent adapter ("antigravity" | "claude" | "aider" | "goose" | "custom")
  default_adapter = "antigravity",

  -- Window UI & Layout options
  ui = {
    layout = "drawer", -- "drawer" | "bottom" | "float" | "detached"
    drawer = {
      position = "right", -- "right" | "left"
      width = 0.40,       -- 40% of screen width
    },
    bottom = {
      height = 0.35,      -- 35% of screen height
    },
    float = {
      width = 0.85,
      height = 0.85,
      border = "rounded",
    },
    winblend = 0,
    auto_insert = true,   -- Automatically enter Terminal Insert mode when focused
  },

  -- Key ergonomics & smart escaping
  keymaps = {
    toggle = "<leader>aa",          -- Toggle active agent harness UI
    toggle_float = "<leader>aA",    -- Toggle as centered floating window
    new_session = "<leader>an",     -- Spawn a new named session
    select_session = "<leader>as",  -- Open session picker
    send_selection = "<leader>ac",  -- Send visual selection with context
    send_file = "<leader>af",       -- Send current file reference
    send_diagnostics = "<leader>ad",-- Send current LSP diagnostics
    review_changes = "<leader>ar",  -- Open agent diff review window
    smart_escape = "<M-Esc>",       -- Unconditional escape to Normal mode from terminal
  },

  -- Context formatting options
  context = {
    include_filepath = true,
    include_line_numbers = true,
    treesitter_expand = true,      -- Auto-expand selection to enclosing AST node
    max_context_lines = 1000,
    bracketed_paste = true,        -- Wrap sent text in bracketed paste ANSI codes
  },

  -- Buffer synchronization & safety
  sync = {
    auto_save_on_send = true,      -- Flush modified buffers before prompt sent
    silent_autoread = true,        -- Reload unchanged buffers silently on agent disk edits
    conflict_action = "diff",      -- "diff" | "ask" | "keep_buffer" when unsaved collision occurs
  },

  -- Adapter configurations (override or extend)
  adapters = {
    antigravity = {
      cmd = { "agy" },
      env = {},
    },
    claude = {
      cmd = { "claude" },
      env = {},
    },
    aider = {
      cmd = { "aider", "--no-auto-commits" },
      env = {},
    },
  },

  -- Notifications & statusline
  notifications = {
    enabled = true,
    notify_on_complete = true,     -- Toast notification when agent turn finishes
    sound = false,
  },
})
```

### 5.2 User Commands (`:SuperHarness ...`)

- `:SuperHarness` (or `:SuperHarness toggle`): Toggle the primary agent window.
- `:SuperHarness open [adapter] [layout]`: Open a specific agent (e.g. `:SuperHarness open claude float`).
- `:SuperHarness send [text]`: Send prompt string to active session.
- `:SuperHarness send-context [selection|buffer|diagnostics|diff]`: Send contextual payload.
- `:SuperHarness review`: Open the review diffsplit / quickfix viewer for agent edits.
- `:SuperHarness sessions`: Open interactive session manager.
- `:SuperHarness kill`: Terminate current agent session.

---

## 6. Implementation Milestones & Roadmap

### Phase 1: Core Harness Foundation (MVP)
- [ ] Implement `config.lua` and option normalization.
- [ ] Implement `backends/nvim_term.lua` (PTY creation, buffer management, layout management).
- [ ] Implement `adapters/` for `antigravity` and `claude`.
- [ ] Implement Smart Modal Escape and ergonomic keymaps.
- [ ] Basic prompt injection with bracketed paste protection.

### Phase 2: Context Pipeline & Buffer Sync Shield
- [ ] Implement `context/treesitter.lua` (AST node scoping) and `context/lsp.lua` (diagnostics packager).
- [ ] Implement `sync/watcher.lua` with `uv.fs_event` and `sync/reloader.lua` with atomic `:checktime` reload.
- [ ] Pre-send buffer flush (`:wall` safe wrapper).

### Phase 3: Review & Diff Engine
- [ ] Implement git change snapshotting before and after agent prompt turns.
- [ ] Create interactive review UI with quickfix navigation and 3-way `:diffsplit`.
- [ ] One-key hunk accept / reject operations.

### Phase 4: Bidirectional RPC & Multi-Session Swarms
- [ ] Export `$NVIM` socket into adapter environment and integrate with `harness-use-neovim`.
- [ ] Implement multi-session manager with naming, background execution, and picker integration.
- [ ] Implement agent status detector (Thinking / Tool Running / Awaiting Input) and Lualine/Heirline component.
- [ ] Tmux / Zellij detached backend support.

---

## 7. Quality Standards & Testing

1. **Zero External Dependencies**: Pure LuaJIT using Neovim `>= 0.10.0` core APIs and `vim.loop` (`uv`).
2. **Robust Test Suite**:
   - Unit tests using `plenary.nvim` / `mini.test`.
   - Mock PTY test runner to verify escape handling, prompt formatting, and adapter command line generation.
3. **Hot-Reloadable Architecture**:
   - Clean `:SuperHarnessReload` function that unloads modules from `package.loaded`, purges active libuv file watches, cleans up terminal buffers, and re-applies configuration without restarting Neovim.
