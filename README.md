# 0x0.nvim

Neovim plugin for the [0x0](https://github.com/anonymous-dev-org/0x0) AI coding assistant.

Spawns 0x0's TUI in a Neovim terminal and bridges editor context (files, selections, diagnostics) via HTTP. Reacts to SSE events for file reloads, permission dialogs, and notifications.

All commands, agents, and skills are defined in your `config.yaml` and `.zeroxzero/` directory — the plugin fetches them from the server at runtime.

## Requirements

- Neovim >= 0.10
- `curl` in PATH
- `0x0` CLI installed

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
  cmd = "0x0",                    -- Path to 0x0 binary
  args = {},                      -- Extra CLI arguments
  port = 0,                       -- 0 = random port
  hostname = "127.0.0.1",
  terminal = {
    position = "vsplit",          -- "vsplit" | "split" | "float" | "tab"
    size = 80,
    float_opts = {
      width = 0.8,
      height = 0.8,
      border = "rounded",
    },
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
  },
})
```

## Keymaps

| Keymap | Mode | Action |
|--------|------|--------|
| `<leader>0` | n | Toggle terminal |
| `<leader>0a` | n,v | Ask (with selection context in visual) |
| `<leader>0f` | n | Add current file to prompt |
| `<leader>0s` | v | Add selection to prompt |
| `<leader>0l` | n | List sessions |
| `<leader>0n` | n | New session |
| `<leader>0i` | n | Interrupt session |
| `<leader>0m` | n | List models |
| `<leader>0c` | n,v | Command picker |
| `<leader>0g` | n | Agent picker |

## Commands

| Command | Description |
|---------|-------------|
| `:ZeroOpen` | Open 0x0 terminal |
| `:ZeroToggle` | Toggle terminal visibility |
| `:ZeroClose` | Hide terminal |
| `:ZeroAsk [prompt]` | Ask a question |
| `:ZeroAddFile` | Add current file to prompt |
| `:ZeroAddSelection` | Add visual selection to prompt |
| `:ZeroSessionList` | Pick a session |
| `:ZeroSessionNew` | New session |
| `:ZeroSessionInterrupt` | Interrupt current session |
| `:ZeroModelList` | Open model picker |
| `:ZeroCommandPicker` | Pick from available commands |
| `:ZeroAgentPicker` | Pick from available agents |

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

The plugin communicates with 0x0's HTTP server using the same TUI routes as the VS Code extension:

1. **Spawn**: Opens `0x0 --port <random>` in a Neovim terminal
2. **Poll**: Waits for the server to be ready via `GET /app`
3. **Inject**: Sends file references and prompts via `POST /tui/append-prompt` + `POST /tui/submit-prompt`
4. **React**: Listens to `GET /app/event` SSE stream for file changes, permissions, and notifications
5. **Manage**: Sessions, models, commands, and agents are all fetched from the server (`GET /session`, `GET /command`, `GET /agent`)

Commands and agents are defined in your project's `config.yaml`, `.zeroxzero/commands/*.md`, and `.zeroxzero/agents/*.md` — the plugin never hardcodes them.
