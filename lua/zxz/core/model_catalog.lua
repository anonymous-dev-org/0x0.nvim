local config = require("zxz.core.config")
local paths = require("zxz.core.paths")
local log = require("zxz.core.log")

local M = {}

local _models = nil
local _refreshing = false
local _refresh_waiters = {}

local function cache_path()
	return paths.gateway_models_path()
end

local function read_cache()
	local path = cache_path()
	if vim.fn.filereadable(path) ~= 1 then
		return nil
	end
	local lines = vim.fn.readfile(path)
	if not lines or #lines == 0 then
		return nil
	end
	local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	local models = decoded.models
	if type(models) ~= "table" then
		return nil
	end
	local cleaned = {}
	for _, model in ipairs(models) do
		if type(model) == "string" and model ~= "" and not config.is_thinking_model(model) then
			cleaned[#cleaned + 1] = model
		end
	end
	config.sort_completion_models(cleaned)
	if #cleaned == 0 then
		return nil
	end
	return cleaned
end

local function write_cache(models)
	vim.fn.mkdir(paths.state_dir(), "p")
	vim.fn.writefile({ vim.json.encode({ models = models, updated_at = os.time() }) }, cache_path())
end

local function sanitize_models(models)
	local cleaned = {}
	for _, model in ipairs(models) do
		if type(model) == "string" and model ~= "" and not config.is_thinking_model(model) then
			cleaned[#cleaned + 1] = model
		end
	end
	config.sort_completion_models(cleaned)
	return cleaned
end

local function apply_models(models)
	_models = models
	config.current.complete.models = vim.deepcopy(models)
	local selected = config.current.complete.model
	if type(selected) ~= "string" or selected == "" or config.is_thinking_model(selected) then
		config.current.complete.model = models[1]
	elseif vim.tbl_contains(models, selected) == false then
		config.current.complete.model = models[1]
	end
end

---@return string[]
function M.get_models()
	if _models then
		return vim.deepcopy(_models)
	end
	local cached = read_cache()
	if cached then
		_models = cached
		config.current.complete.models = vim.deepcopy(cached)
		return vim.deepcopy(cached)
	end
	return vim.deepcopy(config.current.complete.models or {})
end

---@param on_done? fun(models: string[]|nil, err?: any)
function M.refresh(on_done)
	if not config.gateway_ready() then
		if on_done then
			on_done(nil, { message = "AI Gateway API key required" })
		end
		return
	end

	if _refreshing then
		if on_done then
			table.insert(_refresh_waiters, on_done)
		end
		return
	end

	_refreshing = true
	require("zxz.core.completion_client").list_models(function(models, err)
		_refreshing = false
		if models and #models > 0 then
			local cleaned = sanitize_models(models)
			if #cleaned > 0 then
				apply_models(cleaned)
				write_cache(cleaned)
				log.debug(("model catalog refreshed count=%d"):format(#cleaned))
				models = cleaned
			else
				models = nil
			end
		elseif err then
			log.warn("model catalog refresh failed: " .. tostring(err.message or err))
		end

		local waiters = _refresh_waiters
		_refresh_waiters = {}
		if on_done then
			on_done(models, err)
		end
		for _, waiter in ipairs(waiters) do
			waiter(models, err)
		end
	end)
end

function M._reset()
	_models = nil
	_refreshing = false
	_refresh_waiters = {}
	pcall(vim.fn.delete, cache_path())
end

return M
