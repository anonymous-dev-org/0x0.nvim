# 0x0.nvim

Neovim plugin for the [0x0](https://github.com/anonymous-dev-org/0x0) AI coding assistant.

Native Neovim chat experience — floating window with streaming responses, foldable tool output, `vim.ui.input` for prompts, and `vim.ui.select` for permissions. No terminal buffer. Full vim motions and folds.

All commands, agents, and skills are defined in your `config.yaml` and `.zeroxzero/` directory — the plugin fetches them from the server at runtime.

## Requirements

- Neovim >= 0.10
- `curl` in PATH
- [`0x0-server`](https://github.com/anonymous-dev-org/0x0) installed
- `ANTHROPIC_API_KEY` environment variable set (or configured in `~/.config/0x0/config.yaml`)

## Quick Start

1. Install and set your API key:

```bash
npm i -g @anonymous-dev/0x0@latest
export ANTHROPIC_API_KEY="sk-ant-..."
```

2. Add the plugin (lazy.nvim):

```lua
{
  "anonymous-dev-org/0x0.nvim",
  opts = {},
}
```

3. Open Neovim and press `<leader>0` to open the chat window.

## Installation

### lazy.nvim

```lua
{
  "anonymous-dev-org/0x0.nvim",
  opts = {},
}
```

### packer.nvim

```lua
use {
  "anonymous-dev-org/0x0.nvim",
  config = function()
    require("zeroxzero").setup()
  end,
}
```

## Configuration

```lua
require("zeroxzero").setup({
  cmd = "0x0-server",             -- Server binary (falls back to "0x0 serve")
  port = 4096,                    -- Server port
  hostname = "127.0.0.1",
  auto_start = true,              -- Start server if not running
  chat = {
    width = 0.5,                  -- Fraction of editor width (0-1) or absolute columns
    height = 0.8,                 -- Fraction of editor height (0-1) or absolute rows
    border = "rounded",           -- Neovim border style
    fold_tools = true,            -- Auto-fold completed tool output
    show_thinking = false,        -- Show reasoning/thinking blocks
  },
  keymaps = {
    toggle = "<leader>0",
    ask = "<leader>0a",
    add_file = "<leader>0f",
    add_selection = "<leader>0s",
    session_list = "<leader>0l",
    session_new = "<leader>0n",
    session_interrupt = "<leader>0i",
    model_list = "<leader>0m",
    command_picker = "<leader>0c",
    agent_picker = "<leader>0g",
    inline_edit = "<leader>0e",
  },
})
```

## Keymaps

### Global

| Keymap | Mode | Action |
|--------|------|--------|
| `<leader>0` | n | Toggle chat window |
| `<leader>0a` | n,v | Ask (with selection context in visual) |
| `<leader>0f` | n | Add current file to context |
| `<leader>0s` | v | Add selection to context |
| `<leader>0l` | n | List sessions |
| `<leader>0n` | n | New session |
| `<leader>0i` | n | Interrupt session |
| `<leader>0m` | n | Model picker |
| `<leader>0c` | n,v | Command picker |
| `<leader>0g` | n | Agent picker |
| `<leader>0e` | n,v | Inline edit |

### Chat Buffer

| Key | Action |
|-----|--------|
| `q` | Close chat window |
| `<CR>` | New prompt |
| `<C-c>` | Interrupt current response |
| `za` | Toggle fold (tool output) |
| `zM` | Fold all |
| `zR` | Unfold all |

## Commands

| Command | Description |
|---------|-------------|
| `:ZeroOpen` | Open chat window |
| `:ZeroToggle` | Toggle chat window |
| `:ZeroClose` | Close chat window |
| `:ZeroAsk [prompt]` | Ask a question |
| `:ZeroAddFile` | Add current file to context |
| `:ZeroAddSelection` | Add visual selection to context |
| `:ZeroSessionList` | Pick a session |
| `:ZeroSessionNew` | New session |
| `:ZeroSessionInterrupt` | Interrupt current session |
| `:ZeroModelList` | Model picker |
| `:ZeroCommandPicker` | Pick from available commands |
| `:ZeroAgentPicker` | Pick from available agents |
| `:ZeroInlineEdit` | Inline edit at cursor/selection |

## Chat Window

The chat window is a native Neovim floating buffer with:

- **Streaming responses** — text appears as the model generates it
- **Foldable tool output** — tool invocations (file edits, bash, etc.) fold into single lines with status icons
- **Permission dialogs** — `vim.ui.select` for allow/reject decisions
- **Question dialogs** — multi-step `vim.ui.select`/`vim.ui.input` sequences
- **Auto-scroll** — follows output unless you scroll up
- **Session switching** — load history from any session

### Chat Buffer Format

```
────────────────────────────────────────────────────
 You
────────────────────────────────────────────────────
fix the bug in auth.ts

────────────────────────────────────────────────────
 Assistant (claude-sonnet-4-6)
────────────────────────────────────────────────────

I'll fix the authentication bug.

✔ edit src/auth.ts [+5/-3]
│ @@ -10,5 +10,7 @@
│  function auth() {
│ -  return false
│ +  return true
│  }

✔ bash npm test
│ PASS src/auth.test.ts

The tests pass now.
```

## Statusline

```lua
-- lualine
sections = {
  lualine_x = {
    { function() return require("zeroxzero").statusline() end },
  },
}
```

## Health Check

```vim
:checkhealth zeroxzero
```

## How It Works

1. **Connect**: Checks if `0x0-server` is running on port 4096. Starts it in the background if needed.
2. **Stream**: Opens SSE connection to `GET /event` for real-time message streaming.
3. **Prompt**: Sends messages via `POST /session/:id/prompt_async` (non-blocking).
4. **Render**: `message.part.updated` SSE events stream text deltas and tool results into the chat buffer.
5. **Interact**: Permission and question dialogs appear as native `vim.ui.select` overlays.

All requests include an `x-zeroxzero-directory` header so the server routes them to the correct project instance.
