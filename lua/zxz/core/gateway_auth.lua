local config = require("zxz.core.config")
local paths = require("zxz.core.paths")

local M = {}

local _prompting = false
local _auto_prompted = false

local function key_path()
	return paths.gateway_key_path()
end

local function env_key()
	local gateway = config.current.complete and config.current.complete.gateway or {}
	local env_name = gateway.api_key_env or "AI_GATEWAY_API_KEY"
	local from_env = vim.fn.getenv(env_name)
	if type(from_env) == "string" and from_env ~= "" then
		return from_env
	end
end

---@return string|nil
function M.load_persisted_key()
	local path = key_path()
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
	local api_key = decoded.api_key
	if type(api_key) == "string" and api_key ~= "" then
		return api_key
	end
	return nil
end

---@return string|nil
function M.get_api_key()
	local gateway = config.current.complete and config.current.complete.gateway or {}
	if type(gateway.api_key) == "string" and gateway.api_key ~= "" then
		return gateway.api_key
	end
	local from_env = env_key()
	if from_env then
		return from_env
	end
	return M.load_persisted_key()
end

---@return boolean
function M.configured()
	return M.get_api_key() ~= nil
end

---@param api_key string
function M.set_api_key(api_key)
	api_key = vim.trim(tostring(api_key or ""))
	if api_key == "" then
		return false
	end
	config.current.complete.gateway = config.current.complete.gateway or {}
	config.current.complete.gateway.api_key = api_key
	vim.fn.mkdir(paths.state_dir(), "p")
	vim.fn.writefile({ vim.json.encode({ api_key = api_key }) }, key_path())
	pcall(function()
		require("zxz.core.completion_client").stop_server()
	end)
	return true
end

---@param on_done? fun(saved: boolean)
function M.prompt(on_done)
	if _prompting then
		if on_done then
			on_done(false)
		end
		return
	end
	_prompting = true
	vim.ui.input({
		prompt = "AI Gateway API key: ",
		secret = true,
	}, function(input)
		_prompting = false
		if not input or vim.trim(input) == "" then
			if on_done then
				on_done(false)
			end
			return
		end
		local saved = M.set_api_key(input)
		if saved then
			vim.notify("0x0 completion: API key saved", vim.log.levels.INFO)
		end
		if on_done then
			on_done(saved)
		end
	end)
end

--- Prompt once per session when completion needs a key.
---@param on_done? fun(saved: boolean)
---@return boolean ready
function M.ensure_auto(on_done)
	if M.configured() then
		if on_done then
			on_done(true)
		end
		return true
	end
	if _auto_prompted then
		if on_done then
			on_done(false)
		end
		return false
	end
	_auto_prompted = true
	M.prompt(on_done)
	return false
end

function M._reset_prompt_state()
	_prompting = false
	_auto_prompted = false
end

return M
