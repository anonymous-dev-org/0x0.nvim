# 0x0.nvim

Inline ghost-text completion for Neovim, backed by an ACP provider over stdio.
Users choose a model; 0x0 routes that model to the connected provider
internally. Cursor support uses `cursor-agent acp`.

## Install

Example with lazy.nvim:

```lua
{
  "anonymous-dev-org/0x0.nvim",
  opts = {
    complete = {
      enabled = true,
      model = "gpt-5-codex",
      keymaps = {
        enabled = true,
        accept = "<Tab>",
        dismiss = "<C-]>",
      },
    },
  },
}
```

Without a plugin manager, load the plugin and call setup explicitly:

```lua
require("zxz").setup({
  complete = { enabled = true },
})
```

Ghost text streams from the model connected to `complete.model` as you type,
with caching and debouncing. `:ZxzCompleteSettings` lets users toggle
completion and pick the model. `:ZxzLog` opens the debug log.

### nvim-cmp coexistence

The default accept key is `<Tab>`, which conflicts with nvim-cmp. When using
cmp, set a different accept key (for example `<M-]>`) or disable keymaps with
`complete.keymaps.enabled = false` and bind `require("zxz.complete").accept()`
yourself.

## Configuration

- **`complete.*`** — completion settings (model, debounce, cache, keymaps,
  timeouts). See `lua/zxz/core/config.lua` for defaults.
- **`complete.model`** — user-facing model name. Provider routing is derived
  internally.
- **`complete.models`** — model names shown by `:ZxzCompleteSettings`.

Thinking/reasoning model variants are filtered out for completion, because
ghost text must be insertable code rather than assistant preamble.
