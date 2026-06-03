local M = {}

---@class zxz.Config
---@field request_timeout_ms integer  reserved for future use
---@field idle_kill_ms integer  kill completion server if no stdout/stderr for this long during a request
---@field complete table

local THINKING_MODEL_MARKERS = { "thinking", "reasoning" }
local THINKING_MODEL_DENYLIST = {
	o3 = true,
}

local DEFAULT_COMPLETION_MODELS = {
	"mistral/codestral",
}

local DEFAULT_FAVORITE_COMPLETION_MODELS = {
	"mistral/codestral",
	"xai/grok-code-fast-1",
	"alibaba/qwen3-coder-30b-a3b",
	"alibaba/qwen3-coder",
	"alibaba/qwen3-coder-plus",
	"openai/codex-mini",
	"openai/gpt-5.1-codex-mini",
	"openai/gpt-5-codex",
	"openai/gpt-5.1-codex",
}

---@type zxz.Config
M.defaults = {
	request_timeout_ms = 60000,
	idle_kill_ms = 120000,
	complete = {
		enabled = true,
		model = "mistral/codestral",
		models = vim.deepcopy(DEFAULT_COMPLETION_MODELS),
		favorite_models = vim.deepcopy(DEFAULT_FAVORITE_COMPLETION_MODELS),
		gateway = {
			api_key_env = "AI_GATEWAY_API_KEY",
		},
		debounce_ms = 300,
		max_tokens = 64,
		temperature = 0,
		prompt_timeout_ms = 10000,
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
		rag = {
			enabled = true,
			max_entries = 5000,
			session_entries = 3,
			max_field_chars = 300,
			direct_hit_threshold = 0.92,
			example_threshold = 0.75,
			max_examples = 3,
			embedding_model = "Xenova/all-MiniLM-L6-v2",
			warmup_on_start = true,
			persist_debounce_ms = 500,
		},
	},
}

M.current = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
	M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
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

local function favorite_rank(model)
	if type(model) ~= "string" or model == "" then
		return nil
	end
	local favorites = M.current.complete and M.current.complete.favorite_models
	if type(favorites) ~= "table" then
		favorites = DEFAULT_FAVORITE_COMPLETION_MODELS
	end
	local lower_model = model:lower()
	for index, favorite in ipairs(favorites) do
		if type(favorite) == "string" and lower_model == favorite:lower() then
			return index
		end
	end
	return nil
end

---@param models string[]
---@return string[]
function M.sort_completion_models(models)
	table.sort(models, function(a, b)
		local a_rank = favorite_rank(a)
		local b_rank = favorite_rank(b)
		if a_rank and b_rank and a_rank ~= b_rank then
			return a_rank < b_rank
		end
		if a_rank and not b_rank then
			return true
		end
		if b_rank and not a_rank then
			return false
		end
		return a < b
	end)
	return models
end

local function first_non_thinking_model(models)
	for _, model in ipairs(models or {}) do
		if type(model) == "string" and model ~= "" and not M.is_thinking_model(model) then
			return model
		end
	end
end

---@return string[]
function M.completion_model_choices()
	local catalog = require("zxz.core.model_catalog")
	local choices = {}
	local seen = {}

	local function add(model)
		if type(model) ~= "string" or model == "" or seen[model] or M.is_thinking_model(model) then
			return
		end
		choices[#choices + 1] = model
		seen[model] = true
	end

	for _, model in ipairs(catalog.get_models()) do
		add(model)
	end

	return M.sort_completion_models(choices)
end

---@param _provider nil|table ignored legacy parameter
---@param requested_model string|nil
---@return string|nil
function M.resolve_completion_model(_provider, requested_model)
	if type(requested_model) == "string" and requested_model ~= "" and not M.is_thinking_model(requested_model) then
		return requested_model
	end
	return first_non_thinking_model(M.completion_model_choices())
		or first_non_thinking_model({ M.current.complete and M.current.complete.model })
end

---@return boolean, string|nil
function M.gateway_ready()
	local gateway_auth = require("zxz.core.gateway_auth")
	if gateway_auth.configured() then
		return true
	end
	return false, "AI Gateway API key required"
end

return M
