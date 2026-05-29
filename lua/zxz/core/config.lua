local M = {}

local function join(...)
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end
  return table.concat({ ... }, "/")
end

local function normalize(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function executable(command)
  return type(command) == "string" and command ~= "" and vim.fn.executable(command) == 1
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  return vim.fn.fnamemodify(source, ":p:h:h:h:h")
end

function M.resolve_claude_acp_command(opts)
  opts = opts or {}
  local root = opts.plugin_root or plugin_root()
  local is_executable = opts.executable or executable

  local data_bin = join(vim.fn.stdpath("data"), "0x0", "claude-agent-server", "bin", "run")
  if is_executable(data_bin) then
    return data_bin
  end

  local plugin_bin = normalize(join(root, "claude-agent-server", "bin", "run"))
  if is_executable(plugin_bin) then
    return plugin_bin
  end

  local monorepo_bin = normalize(join(root, "..", "claude-agent-server", "bin", "run"))
  if is_executable(monorepo_bin) then
    return monorepo_bin
  end

  if is_executable("claude-agent-server") then
    return "claude-agent-server"
  end

  if is_executable("claude-agent-acp") then
    return "claude-agent-acp"
  end

  if is_executable("claude-code-acp") then
    return "claude-code-acp"
  end

  return "claude-agent-server"
end

---@class zxz.ProviderConfig
---@field name string
---@field command string
---@field args? string[]
---@field env? table<string, string>
---@field models? string[]
---@field auth_method? string
---@field kind? string
---@field ignore_stderr_patterns? string[]  Lua patterns; matching stderr lines are silenced

---@class zxz.Config
---@field provider string
---@field request_timeout_ms integer  per-request ACP timeout (cancelled with timeout error after)
---@field idle_kill_ms integer  kill provider subprocess if no stdout/stderr for this long during a request
---@field initialize_retries integer  retry count for the ACP initialize handshake
---@field complete table
---@field providers table<string, zxz.ProviderConfig>

local DEFAULT_STDERR_PATTERNS = {
  ["claude-acp"] = {
    "Session not found",
    "session/prompt",
    "Spawning Claude Code",
    "does not appear in the file:",
    "Experiments loaded",
    "No onPostToolUseHook found",
    "%[PreToolUseHook%]",
  },
  ["claude-agent-acp"] = {
    "Session not found",
    "session/prompt",
    "Spawning Claude Code",
    "Experiments loaded",
  },
}

--- Chat/agent-era defaults kept for downstream forks. The completion plugin
--- does not read these keys.
M.legacy_defaults = {
  width = 0.4,
  input_height = 3,
  title_model = {
    ["claude-acp"] = "claude-haiku-4-5",
    ["claude-agent-acp"] = "claude-haiku-4-5",
    ["codex-acp"] = "o3",
    ["gemini-acp"] = "gemini-2.5-flash",
  },
  sound = vim.fn.has("mac") == 1 and "notification" or "bell",
  checkpoint_keep_n = 20,
  reconcile = "strict",
  profile = "write",
  default_profile = "write",
  profiles = {
    ask = {
      name = "Ask",
      description = "Read-only codebase inspection.",
      tool_policy = {
        auto_approve = { "read" },
        deny = { "write", "shell" },
        auto_approve_paths = {},
        deny_paths = {},
      },
    },
    write = {
      name = "Write",
      description = "Edit files with approval gates for risky actions.",
      tool_policy = {
        auto_approve = { "read" },
        auto_approve_paths = {},
        deny_paths = {},
      },
    },
    review = {
      name = "Review",
      description = "Inspect diffs, diagnostics, tests, and risks.",
      tool_policy = {
        auto_approve = { "read" },
        deny = { "write", "shell" },
        auto_approve_paths = {},
        deny_paths = {},
      },
    },
    autonomous = {
      name = "Autonomous",
      description = "Long-running codebase work with explicit review.",
      tool_policy = {
        auto_approve = { "read" },
        auto_approve_paths = {},
        deny_paths = {},
      },
    },
  },
  favorite_models = {},
  thinking = {
    enabled = nil,
    effort = nil,
  },
  tool_policy = {
    auto_approve = { "read" },
    auto_approve_paths = {},
    deny_paths = {},
  },
  repo_map = {
    budget_bytes = 50 * 1024,
  },
  rules = {
    paths = { ".0x0/rules.md", ".zed/rules.md", "AGENTS.md" },
  },
  auto_prelude = {
    cursor = false,
    repo_map = false,
    recent = false,
  },
  code_actions = {},
  inline_diff = {
    streaming_refresh = true,
    streaming_refresh_delay_ms = 40,
  },
  edit_events = {
    max_content_bytes = 512 * 1024,
    max_diff_bytes = 256 * 1024,
    max_retained_runs = 64,
    max_age_seconds = 24 * 60 * 60,
  },
  detached_runs_max = 4,
  test_command = nil,
  test_command_timeout_ms = 5000,
  context = {
    summarize_threshold = 8 * 1024,
  },
  tool_output_max_lines = 200,
}

---@type zxz.Config
M.defaults = {
  provider = "claude-acp",
  request_timeout_ms = 60000,
  idle_kill_ms = 120000,
  initialize_retries = 3,
  complete = {
    enabled = true,
    provider = "codex-acp",
    model = nil,
    debounce_ms = 150,
    max_tokens = 128,
    temperature = 0,
    prompt_timeout_ms = 15000,
    trigger_on_cursor_moved = false,
    allow_read_tools = false,
    suppress_in_strings_and_comments = true,
    keymaps = {
      enabled = true,
      accept = "<Tab>",
      dismiss = "<C-]>",
      accept_fallback = true,
    },
    filetypes = {
      exclude = {
        "TelescopePrompt",
        "NvimTree",
        "help",
        "qf",
        "alpha",
        "dashboard",
      },
    },
    cache = {
      enabled = true,
      max_entries = 100,
    },
    telemetry = {
      enabled = false,
      path = nil,
    },
  },
  providers = {
    ["claude-acp"] = {
      name = "Claude ACP",
      command = M.resolve_claude_acp_command(),
      models = { "claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5" },
      ignore_stderr_patterns = DEFAULT_STDERR_PATTERNS["claude-acp"],
    },
    ["claude-agent-acp"] = {
      name = "Claude Agent ACP",
      command = "claude-agent-acp",
      models = { "claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5" },
      ignore_stderr_patterns = DEFAULT_STDERR_PATTERNS["claude-agent-acp"],
    },
    ["codex-acp"] = {
      name = "Codex ACP",
      command = "codex-acp",
      args = { "-c", "notify=[]" },
      auth_method = "chatgpt",
      models = { "gpt-5-codex", "gpt-5", "o3" },
    },
    ["gemini-acp"] = {
      name = "Gemini ACP",
      command = "gemini",
      args = { "--acp" },
      models = { "gemini-2.5-pro", "gemini-2.5-flash" },
    },
    ["cursor"] = {
      name = "Cursor CLI",
      kind = "cursor",
      command = "cursor-agent",
      models = { "gpt-5", "gpt-5-codex", "claude-sonnet-4-6", "claude-opus-4-7" },
    },
  },
}

M.current = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

---@param name? string
---@return zxz.ProviderConfig|nil, string|nil
function M.resolve_provider(name)
  name = name or M.current.provider
  local provider = M.current.providers[name]
  if not provider then
    return nil, "unknown provider: " .. tostring(name)
  end
  return provider, nil
end

---@return zxz.ProviderConfig|nil, string|nil
function M.resolve_completion_provider()
  local complete = M.current.complete or {}
  local override = complete.acp
  if type(override) == "table" and override.command and override.command ~= "" then
    local provider = vim.deepcopy(override)
    provider.name = provider.name or provider.provider or "completion"
    return provider, nil
  end

  local provider_name = complete.provider
  if (not provider_name or provider_name == "") and type(override) == "table" then
    provider_name = override.provider
  end
  provider_name = provider_name or M.current.provider

  local provider, err = M.resolve_provider(provider_name)
  if not provider then
    return nil, err
  end
  return vim.deepcopy(provider), nil
end

return M
