# 0x0.nvim

Inline ghost-text completion for Neovim, backed by a bundled Node completion
server that calls Vercel AI SDK `streamText` through AI Gateway.

## Requirements

- Neovim 0.10+
- Node.js 18+ on `PATH`
- An AI Gateway API key (prompted on first use, or set in advance)

On first completion attempt without a key, 0x0 opens a secret prompt. The key is
saved under `stdpath('state')/0x0/gateway.json`. You can also set it ahead of
time:

```bash
export AI_GATEWAY_API_KEY="vck_..."
```

Or via `:ZxzCompleteSettings` → **API key**, or `complete.gateway.api_key` in
your plugin config.

## Install

Example with lazy.nvim:

```lua
{
  "anonymous-dev-org/0x0.nvim",
  opts = {
    complete = {
      enabled = true,
      model = "mistral/codestral",
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

Ghost text streams from the selected gateway model as you type, with caching and
debouncing. `:ZxzCompleteSettings` lets users toggle completion and pick the
model. `:ZxzLog` opens the debug log.

The bundled server inlines buffer context in the prompt and performs plain text
completion only — no agent tools, no provider subprocesses.

### nvim-cmp coexistence

The default accept key is `<Tab>`, which conflicts with nvim-cmp. When using
cmp, set a different accept key (for example `<M-]>`) or disable keymaps with
`complete.keymaps.enabled = false` and bind `require("zxz.complete").accept()`
yourself.

## Configuration

- **`complete.*`** — completion settings (model, debounce, cache, keymaps,
  timeouts). Inline prompts use a bounded default (`prompt_timeout_ms = 10000`);
  see `lua/zxz/core/config.lua` for the full defaults.
- **`complete.model`** — gateway model id in `provider/model` form, for example
  `mistral/codestral` or `anthropic/claude-sonnet-4.6`.
- **`complete.gateway.api_key_env`** — environment variable name for the gateway
  key (default: `AI_GATEWAY_API_KEY`). Used when no saved key exists.
- **`complete.gateway.api_key`** — optional direct API key override.
- **`complete.temperature`**, **`complete.max_tokens`** — passed to
  `streamText`. Defaults favor completion latency and determinism:
  `temperature = 0`, `max_tokens = 128`.
- **`complete.models`** — model ids shown by `:ZxzCompleteSettings`.

Thinking/reasoning model variants are filtered out for completion, because
ghost text must be insertable code rather than assistant preamble.

## Maintainers

Rebuild the bundled server after changing `server/src/`:

```bash
make build-server
make test-server
```
