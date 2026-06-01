local M = {}

---@class zxz.ProviderConfig
---@field name string
---@field command string
---@field args? string[]
---@field env? table<string, string>
---@field models? string[]
---@field model? string
---@field auth_method? string
---@field ignore_stderr_patterns? string[]  Lua patterns; matching stderr lines are silenced

---@class zxz.Config
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
}

local THINKING_MODEL_MARKERS = { "thinking", "reasoning" }
local THINKING_MODEL_DENYLIST = {
	o3 = true,
}

local DEFAULT_COMPLETION_MODELS = {
	"gpt-5.3-codex",
	"gpt-5.5",
	"claude-opus-4-8",
	"claude-sonnet-4-6",
	"claude-haiku-4-5-20251001",
	"gemini-3.5-flash",
	"gemini-3.1-pro-preview",
	"gemini-3-flash-preview",
	"gemini-3.1-flash-lite",
	"composer-2.5",
	"composer-2.5-fast",
}

local DEFAULT_COMPLETION_MODEL_PROVIDERS = {
	["gpt-5.3-codex"] = "codex-acp",
	["gpt-5.5"] = "codex-acp",
	["claude-opus-4-8"] = "claude-acp",
	["claude-sonnet-4-6"] = "claude-acp",
	["claude-haiku-4-5-20251001"] = "claude-acp",
	["gemini-3.5-flash"] = "gemini-acp",
	["gemini-3.1-pro-preview"] = "gemini-acp",
	["gemini-3-flash-preview"] = "gemini-acp",
	["gemini-3.1-flash-lite"] = "gemini-acp",
	["composer-2.5"] = "cursor-acp",
	["composer-2.5-fast"] = "cursor-acp",

	-- Backward-compatible model names from older defaults.
	["gpt-5-codex"] = "codex-acp",
	["gpt-5"] = "codex-acp",
	["claude-haiku-4-5"] = "claude-acp",
	["claude-opus-4-7"] = "claude-acp",
	["gemini-2.5-flash"] = "gemini-acp",
	["gemini-2.5-pro"] = "gemini-acp",
	["sonnet-4"] = "cursor-acp",
}

---@type zxz.Config
M.defaults = {
	request_timeout_ms = 60000,
	idle_kill_ms = 120000,
	initialize_retries = 3,
	complete = {
		enabled = true,
		model = "gpt-5.3-codex",
		models = vim.deepcopy(DEFAULT_COMPLETION_MODELS),
		model_providers = vim.deepcopy(DEFAULT_COMPLETION_MODEL_PROVIDERS),
		debounce_ms = 300,
		max_tokens = 128,
		temperature = 0,
		effort = "none",
		prompt_timeout_ms = 10000,
		session_reuse = {
			enabled = true,
			max_prompts = 12,
			max_age_ms = 180000,
			max_idle_ms = 60000,
		},
		trigger_on_cursor_moved = false,
		debug = false,
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
	},
	providers = {
		["claude-acp"] = {
			name = "Claude ACP",
			command = "claude-acp",
			model = "claude-haiku-4-5-20251001",
			models = { "claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5-20251001" },
			ignore_stderr_patterns = DEFAULT_STDERR_PATTERNS["claude-acp"],
		},
		["codex-acp"] = {
			name = "Codex ACP",
			command = "codex-acp",
			args = { "-c", "notify=[]" },
			auth_method = "chatgpt",
			model = "gpt-5.3-codex",
			models = { "gpt-5.3-codex", "gpt-5.5" },
		},
		["gemini-acp"] = {
			name = "Gemini ACP",
			command = "gemini",
			args = { "--acp" },
			model = "gemini-3.5-flash",
			models = { "gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-3-flash-preview", "gemini-3.1-flash-lite" },
		},
		["cursor-acp"] = {
			name = "Cursor ACP",
			command = "cursor-agent",
			args = { "acp" },
			model = "composer-2.5-fast",
			models = { "composer-2.5", "composer-2.5-fast" },
		},
	},
}

M.current = vim.deepcopy(M.defaults)

local first_non_thinking_model

---@param opts? table
function M.setup(opts)
	M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

---@param name? string
---@return zxz.ProviderConfig|nil, string|nil
function M.resolve_provider(name)
	if not name or name == "" then
		return nil, "provider name required"
	end
	local provider = M.current.providers[name]
	if not provider then
		return nil, "unknown provider: " .. tostring(name)
	end
	return provider, nil
end

---@param models string[]
---@param model string
---@return boolean
local function model_in_list(models, model)
	for _, candidate in ipairs(models or {}) do
		if candidate == model then
			return true
		end
	end
	return false
end

local function provider_accepts_model(provider, model)
	return not provider.command or provider.model == model or model_in_list(provider.models, model)
end

---@param model string
---@return zxz.ProviderConfig|nil, string|nil
local function resolve_provider_for_model(model)
	local complete = M.current.complete or {}
	local provider_name = type(complete.model_providers) == "table" and complete.model_providers[model] or nil
	if provider_name and provider_name ~= "" then
		return M.resolve_provider(provider_name)
	end

	local provider_names = {}
	for name in pairs(M.current.providers or {}) do
		provider_names[#provider_names + 1] = name
	end
	table.sort(provider_names)

	for _, name in ipairs(provider_names) do
		local provider = M.current.providers[name]
		if provider and (provider.model == model or model_in_list(provider.models, model)) then
			return provider, nil
		end
	end

	return nil, "unknown completion model: " .. tostring(model)
end

---@return zxz.ProviderConfig|nil, string|nil
function M.resolve_completion_provider()
	local complete = M.current.complete or {}

	local model = M.resolve_completion_model(nil, complete.model)
	if not model then
		return nil, "no non-thinking completion model configured"
	end

	local provider, err = resolve_provider_for_model(model)
	if not provider then
		return nil, err
	end
	return vim.deepcopy(provider), nil
end

---@param model string|nil
---@return boolean
function M.is_thinking_model(model)
	if type(model) ~= "string" or model == "" then
		return false
	end
	local lower = model:lower()
	if THINKING_MODEL_DENYLIST[lower] then
		return true
	end
	for _, marker in ipairs(THINKING_MODEL_MARKERS) do
		if lower:find(marker, 1, true) then
			return true
		end
	end
	return false
end

function first_non_thinking_model(models)
	for _, model in ipairs(models or {}) do
		if type(model) == "string" and model ~= "" and not M.is_thinking_model(model) then
			return model
		end
	end
end

---@return string[]
function M.completion_model_choices()
	local complete = M.current.complete or {}
	local choices = {}
	local seen = {}

	local function add(model)
		if type(model) ~= "string" or model == "" or seen[model] or M.is_thinking_model(model) then
			return
		end
		choices[#choices + 1] = model
		seen[model] = true
	end

	for _, model in ipairs(complete.models or {}) do
		add(model)
	end

	if #choices == 0 then
		local provider_names = {}
		for name in pairs(M.current.providers or {}) do
			provider_names[#provider_names + 1] = name
		end
		table.sort(provider_names)
		for _, name in ipairs(provider_names) do
			local provider = M.current.providers[name] or {}
			add(provider.model)
			for _, model in ipairs(provider.models or {}) do
				add(model)
			end
		end
	end

	return choices
end

---@param provider zxz.ProviderConfig|nil
---@param requested_model string|nil
---@return string|nil
function M.resolve_completion_model(provider, requested_model)
	provider = provider or {}
	if type(requested_model) == "string" and requested_model ~= "" and not M.is_thinking_model(requested_model) then
		return requested_model
	end

	local configured_model = first_non_thinking_model(M.completion_model_choices())
	if configured_model and provider_accepts_model(provider, configured_model) then
		return configured_model
	end

	if type(provider.model) == "string" and provider.model ~= "" and not M.is_thinking_model(provider.model) then
		return provider.model
	end

	return first_non_thinking_model(provider.models)
end

return M
