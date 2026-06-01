local transport_mod = require("zxz.core.completion_transport")
local config = require("zxz.core.config")
local paths = require("zxz.core.paths")
local log = require("zxz.core.log")

local M = {}
local uv = vim.uv or vim.loop

local _server_entry = nil
local _next_request_id = 0
local _transport_factory = transport_mod.create

local function now_ms()
	if uv and uv.hrtime then
		return math.floor(uv.hrtime() / 1000000)
	end
	return math.floor(os.clock() * 1000)
end

local function completion_debug_enabled()
	local complete = config.current and config.current.complete or {}
	return complete.debug == true
end

local function completion_debug(fmt, ...)
	if not completion_debug_enabled() then
		return
	end
	local msg = fmt
	if select("#", ...) > 0 then
		local ok, formatted = pcall(string.format, fmt, ...)
		msg = ok and formatted or tostring(fmt)
	end
	log.debug("completion-server: " .. tostring(msg))
end

local function gateway_env()
	local api_key = require("zxz.core.gateway_auth").get_api_key()
	local env = {}
	if type(api_key) == "string" and api_key ~= "" then
		env.AI_GATEWAY_API_KEY = api_key
	end
	return env
end

local function server_script_path()
	local script = paths.completion_server()
	if vim.fn.filereadable(script) ~= 1 then
		return nil, "completion server not found at " .. tostring(script)
	end
	return script
end

local function transport_alive(entry)
	if not entry or not entry.transport then
		return false
	end
	if entry.state == "disconnected" or entry.state == "error" then
		return false
	end
	local transport = entry.transport
	if transport.process and transport.process:is_closing() then
		return false
	end
	if entry.state == "ready" then
		if not transport.stdin or transport.stdin:is_closing() then
			return false
		end
	end
	return true
end

local function fail_pending(entry, err)
	for id, pending in pairs(entry.pending or {}) do
		if pending.on_done then
			vim.schedule(function()
				pending.on_done(err)
			end)
		end
		entry.pending[id] = nil
	end
end

local function discard_server(entry, reason)
	if not entry then
		return
	end
	completion_debug("discard server reason=%s pending=%d", tostring(reason), vim.tbl_count(entry.pending or {}))
	fail_pending(entry, { message = "transport disconnected" })
	if entry.transport then
		entry.transport:stop()
	end
	if _server_entry == entry then
		_server_entry = nil
	end
end

local function send_message(entry, message)
	if not entry or not entry.transport then
		return false
	end
	local ok, encoded = pcall(vim.json.encode, message)
	if not ok then
		return false
	end
	return entry.transport:send(encoded)
end

local function get_server(on_ready)
	if _server_entry and transport_alive(_server_entry) then
		if _server_entry.state == "ready" then
			if on_ready then
				on_ready(_server_entry)
			end
			return _server_entry
		end
		if on_ready then
			table.insert(_server_entry.ready_waiters, on_ready)
		end
		return _server_entry
	end

	if _server_entry then
		discard_server(_server_entry, "stale transport")
	end

	local script, err = server_script_path()
	if not script then
		if on_ready then
			vim.schedule(function()
				on_ready(nil, { message = err or "completion server unavailable" })
			end)
		end
		return nil
	end

	local entry = {
		state = "starting",
		transport = nil,
		pending = {},
		ready_waiters = on_ready and { on_ready } or {},
		ping_id = nil,
	}

	_server_entry = entry

	local transport = _transport_factory({
		command = "node",
		args = { script },
		env = gateway_env(),
	}, {
		on_state = function(state)
			completion_debug("transport state=%s", tostring(state))
			if state == "connected" then
				entry.state = "connected"
				entry.ping_id = _next_request_id + 1
				_next_request_id = entry.ping_id
				send_message(entry, { id = entry.ping_id, method = "ping" })
				return
			end
			if state == "disconnected" or state == "error" then
				entry.state = state
				local waiters = entry.ready_waiters
				entry.ready_waiters = {}
				local disconnect_err = { message = state == "error" and "transport error" or "transport disconnected" }
				for _, waiter in ipairs(waiters) do
					vim.schedule(function()
						waiter(nil, disconnect_err)
					end)
				end
				fail_pending(entry, disconnect_err)
				if _server_entry == entry then
					_server_entry = nil
				end
			end
		end,
		on_message = function(message)
			if type(message) ~= "table" then
				return
			end
			local id = message.id
			if entry.ping_id and id == entry.ping_id and message.event == "pong" then
				entry.state = "ready"
				entry.ping_id = nil
				local waiters = entry.ready_waiters
				entry.ready_waiters = {}
				for _, waiter in ipairs(waiters) do
					vim.schedule(function()
						waiter(entry)
					end)
				end
				return
			end
			local pending = entry.pending[id]
			if not pending then
				return
			end
			if message.event == "chunk" and type(message.text) == "string" and pending.on_chunk then
				vim.schedule(function()
					pending.on_chunk(message.text)
				end)
				return
			end
			if message.event == "done" then
				entry.pending[id] = nil
				if pending.on_done then
					vim.schedule(function()
						pending.on_done(nil)
					end)
				end
				return
			end
			if message.event == "error" then
				entry.pending[id] = nil
				if pending.on_done then
					vim.schedule(function()
						pending.on_done({ message = tostring(message.message or "completion failed") })
					end)
				end
			end
		end,
		on_exit = function(code, stderr_lines)
			completion_debug("transport exit code=%s stderr_lines=%d", tostring(code), #(stderr_lines or {}))
		end,
	}, {
		idle_kill_ms = config.current.idle_kill_ms,
	})

	entry.transport = transport
	transport:start()
	if entry.state == "error" then
		discard_server(entry, "spawn failed")
	end
	return entry
end

---Stream an inline completion via the bundled AI Gateway server.
---@param _provider any ignored; kept for API compatibility
---@param request { prefix: string, suffix: string, language?: string, filepath?: string, model?: string, max_tokens?: number, temperature?: number, scope?: table }
---@param on_chunk fun(text: string)
---@param on_done fun(err?: any)
---@return fun() abort
function M.stream_completion(_provider, request, on_chunk, on_done)
	local active = true
	local done = false
	local complete_cfg = config.current.complete or {}
	local prompt_timeout_ms = complete_cfg.prompt_timeout_ms or 0
	local request_id = nil
	local cancel_id = nil
	local timeout_timer = nil
	local entry_ref = nil

	local function clear_timeout()
		if timeout_timer then
			timeout_timer:stop()
			timeout_timer:close()
			timeout_timer = nil
		end
	end

	local function finish(err)
		if done then
			return
		end
		done = true
		active = false
		clear_timeout()
		if entry_ref and entry_ref.transport then
			entry_ref.transport:set_idle_armed(false)
		end
		if on_done then
			vim.schedule(function()
				on_done(err)
			end)
		end
	end

	local function abort()
		if not active then
			return
		end
		active = false
		clear_timeout()
		if entry_ref and request_id then
			entry_ref.pending[request_id] = nil
			cancel_id = _next_request_id + 1
			_next_request_id = cancel_id
			send_message(entry_ref, {
				id = cancel_id,
				method = "cancel",
				params = { target = request_id },
			})
		end
		if entry_ref and entry_ref.transport then
			entry_ref.transport:set_idle_armed(false)
		end
	end

	local ready, gateway_err = config.gateway_ready()
	if not ready then
		finish({ message = gateway_err or "AI Gateway API key not configured" })
		return abort
	end

	get_server(function(entry, err)
		if not active then
			return
		end
		if not entry then
			finish(err or { message = "completion server unavailable" })
			return
		end

		entry_ref = entry
		request_id = _next_request_id + 1
		_next_request_id = request_id

		if prompt_timeout_ms > 0 and uv and uv.new_timer then
			timeout_timer = uv.new_timer()
			timeout_timer:start(
				prompt_timeout_ms,
				0,
				vim.schedule_wrap(function()
					if done or not active then
						return
					end
					abort()
					finish({ message = "request timed out" })
				end)
			)
		end

		entry.pending[request_id] = {
			on_chunk = function(text)
				if active then
					on_chunk(text)
				end
			end,
			on_done = function(err)
				if active then
					finish(err)
				end
			end,
		}

		entry.transport:set_idle_armed(true)
		local sent = send_message(entry, {
			id = request_id,
			method = "complete",
			params = {
				model = request.model,
				prefix = request.prefix,
				suffix = request.suffix,
				language = request.language,
				filepath = request.filepath,
				scope = request.scope,
				max_tokens = request.max_tokens,
				temperature = request.temperature,
			},
		})
		if not sent then
			entry.pending[request_id] = nil
			discard_server(entry, "send failed")
			finish({ message = "transport disconnected" })
		end
	end)

	return abort
end

function M.stop_server()
	if _server_entry then
		discard_server(_server_entry, "stop_server")
	end
end

function M._set_transport_factory(factory)
	_transport_factory = factory or transport_mod.create
end

function M._reset_transport_factory()
	_transport_factory = transport_mod.create
	M.stop_server()
end

return M
