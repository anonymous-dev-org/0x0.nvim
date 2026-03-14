# 0x0.nvim

Neovim companion for the [0x0](https://github.com/anonymous-dev-org/0x0) AI coding assistant.

Send file and selection context from Neovim to a TUI session's prompt stash. Pick which session to target. That's it.

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

3. Start the TUI in a terminal, then use `<leader>0s` in Neovim to send the current file to the TUI prompt.

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
  keymaps = {
    send = "<leader>0s",          -- Send file (n) or selection (v) to TUI
    switch_session = "<leader>0p",-- Switch pinned session
  },
})
```

## Keymaps

| Keymap | Mode | Action |
|--------|------|--------|
| `<leader>0s` | n | Send current file reference to TUI prompt |
| `<leader>0s` | v | Send selection with file reference to TUI prompt |
| `<leader>0p` | n | Switch pinned session |

## Commands

| Command | Description |
|---------|-------------|
| `:ZeroSend` | Send current file to TUI prompt |

## Features

### Send Context to TUI

Select code in Neovim, press `<leader>0s`, and it lands in the TUI's prompt stash as a file reference with the selected lines. On first use, you'll be prompted to pick a session to pin.

### Session Picker

Press `<leader>0p` to switch which TUI session receives your context. The plugin pins one session per working directory.

### SSE Integration

The plugin maintains an SSE connection to the server for:
- **File auto-reload** — buffers update when the agent edits files
- **Statusline** — connection status and pinned session title

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
2. **Stream**: Opens SSE connection to `GET /event` for file auto-reload events.
3. **Send**: Sends context to the TUI via `POST /session/:id/prompt/stash`.

All requests include an `x-zeroxzero-directory` header so the server routes them to the correct project instance.
