local transport_mod = require("zxz.core.acp_transport")
local config = require("zxz.core.config")
local log = require("zxz.core.log")

local M = {}
local uv = vim.uv or vim.loop

-- Some requests are inherently long-running (a streaming model turn) and
-- should not be timed out by the per-request watchdog.
local NON_TIMED_METHODS = {
	["session/prompt"] = true,
}

local function now_ms()
	if uv and uv.hrtime then
		return math.floor(uv.hrtime() / 1000000)
	end
	return math.floor(os.clock() * 1000)
end

local function elapsed_ms(start_ms)
	if not start_ms then
		return 0
	end
	return math.max(0, now_ms() - start_ms)
end

local function provider_label(provider)
	if type(provider) ~= "table" then
		return "unknown"
	end
	return tostring(provider.name or provider.command or "unknown")
end

local function command_summary(provider)
	if type(provider) ~= "table" then
		return "unknown"
	end
	local parts = { tostring(provider.command or "unknown") }
	for _, arg in ipairs(provider.args or {}) do
		parts[#parts + 1] = tostring(arg)
	end
	return table.concat(parts, " ")
end

local function display_key(key)
	return tostring(key or ""):gsub("%z", "\\0"):gsub("\1", "\\1")
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
	log.debug("acp[completion]: " .. tostring(msg))
end

local function acp_debug(provider, fmt, ...)
	if not completion_debug_enabled() then
		return
	end
	local msg = fmt
	if select("#", ...) > 0 then
		local ok, formatted = pcall(string.format, fmt, ...)
		msg = ok and formatted or tostring(fmt)
	end
	log.debug(("acp[%s]: %s"):format(provider_label(provider), tostring(msg)))
end

local function pending_summary(callbacks)
	local items = {}
	for id, entry in pairs(callbacks or {}) do
		local method = type(entry) == "table" and entry.method or "request"
		items[#items + 1] = ("%s#%s"):format(tostring(method or "?"), tostring(id))
	end
	table.sort(items)
	if #items == 0 then
		return "none"
	end
	return table.concat(items, ",")
end

local function err_summary(err)
	if err == nil then
		return "nil"
	end
	if type(err) == "table" then
		return tostring(err.message or vim.inspect(err))
	end
	return tostring(err)
end

local function table_len(value)
	if type(value) ~= "table" then
		return 0
	end
	local count = 0
	for _ in pairs(value) do
		count = count + 1
	end
	return count
end

local function result_summary(method, result)
	if type(result) ~= "table" then
		return tostring(result)
	end
	if method == "initialize" then
		local agent = result.agentInfo or {}
		return ("protocol=%s agent=%s version=%s capability_groups=%d"):format(
			tostring(result.protocolVersion or ""),
			tostring(agent.name or ""),
			tostring(agent.version or ""),
			table_len(result.agentCapabilities)
		)
	end
	if method == "session/new" then
		return ("session=%s config_options=%d"):format(tostring(result.sessionId or ""), #(result.configOptions or {}))
	end
	if method == "session/prompt" then
		return ("keys=%d"):format(table_len(result))
	end
	local keys = {}
	for key in pairs(result) do
		keys[#keys + 1] = tostring(key)
	end
	table.sort(keys)
	if #keys > 6 then
		keys[7] = "..."
	end
	return "keys=" .. table.concat(keys, ",")
end

local function notification_summary(message)
	local params = message.params or {}
	if message.method == "session/update" then
		local update = params.update or {}
		local content = update.content or {}
		return ("method=session/update id=%s session=%s update=%s content_type=%s text_chars=%d"):format(
			tostring(message.id or ""),
			tostring(params.sessionId or ""),
			tostring(update.sessionUpdate or ""),
			tostring(content.type or ""),
			#tostring(content.text or "")
		)
	end
	if message.method == "session/request_permission" then
		local tool_call = params.toolCall or {}
		return ("method=session/request_permission id=%s session=%s tool=%s kind=%s options=%d"):format(
			tostring(message.id or ""),
			tostring(params.sessionId or ""),
			tostring(tool_call.name or params.toolName or ""),
			tostring(tool_call.kind or params.kind or ""),
			#(params.options or {})
		)
	end
	return ("method=%s id=%s session=%s keys=%d"):format(
		tostring(message.method or ""),
		tostring(message.id or ""),
		tostring(params.sessionId or ""),
		table_len(params)
	)
end

local Client = {}
Client.__index = Client

---@param provider { command: string, args?: string[], env?: table<string, string>, name?: string }
---@param opts? { host_fs?: boolean }
function M.new(provider, opts)
	opts = opts or {}
	local self = setmetatable({
		provider = provider,
		state = "disconnected",
		id_counter = 0,
		callbacks = {},
		notification_handlers = {},
		ready_listeners = {},
		subscribers = {},
		agent_info = nil,
		agent_capabilities = nil,
		protocol_version = 1,
		host_fs = opts.host_fs and true or false,
	}, Client)

	self.transport = transport_mod.create(provider, {
		on_state = function(state)
			self:_on_state(state)
		end,
		on_message = function(msg)
			self:_on_message(msg)
		end,
		on_exit = function(code, stderr_lines)
			if code ~= 0 then
				local stderr_blob = table.concat(stderr_lines, "\n")
				log.error(
					("acp[%s]: exited with code %d\n%s"):format(provider.name or provider.command, code, stderr_blob)
				)
				vim.notify(
					("acp[%s]: exited with code %d (see :ZxzLog for details)"):format(
						provider.name or provider.command,
						code
					),
					vim.log.levels.ERROR
				)
			end
		end,
		on_idle = function(ms)
			log.error(
				("acp[%s]: idle for %d ms — provider considered hung"):format(provider.name or provider.command, ms)
			)
			self:_fail_all_pending({
				code = -32001,
				message = "provider hung (no I/O)",
			})
		end,
	}, {
		idle_kill_ms = config.current.idle_kill_ms or 0,
	})

	return self
end

function Client:_on_state(state)
	local previous = self.state
	self.state = state
	acp_debug(
		self.provider,
		"state %s -> %s pending=%s",
		tostring(previous or ""),
		tostring(state or ""),
		pending_summary(self.callbacks)
	)
	if state == "disconnected" or state == "error" then
		self:_fail_all_pending({ code = -32000, message = "transport " .. state })
		local listeners = self.ready_listeners
		self.ready_listeners = {}
		for _, listener in ipairs(listeners) do
			vim.schedule(function()
				pcall(listener, nil, { code = -32000, message = "transport " .. state })
			end)
		end
	end
end

---Reject every pending callback with err. Used by transport disconnects and
---the idle watchdog so callers aren't left hanging.
---@param err table
function Client:_fail_all_pending(err)
	local pending = self.callbacks
	self.callbacks = {}
	if next(pending) then
		acp_debug(
			self.provider,
			"failing pending requests pending=%s err=%s",
			pending_summary(pending),
			err_summary(err)
		)
	end
	for id, entry in pairs(pending) do
		if entry.timer then
			pcall(function()
				entry.timer:stop()
				entry.timer:close()
			end)
		end
		vim.schedule(function()
			pcall(entry.cb, nil, err)
		end)
	end
	if self.transport and self.transport.set_idle_armed then
		self.transport:set_idle_armed(false)
	end
end

function Client:_next_id()
	self.id_counter = self.id_counter + 1
	return self.id_counter
end

---@param method string
---@param params table|nil
---@param callback fun(result: table|nil, err: table|nil)
---@param opts? { timeout_ms?: integer }
---@return integer id
function Client:request(method, params, callback, opts)
	opts = opts or {}
	local id = self:_next_id()
	local entry = { cb = callback, method = method, start_ms = now_ms() }
	self.callbacks[id] = entry

	local timeout = opts.timeout_ms
	if timeout == nil then
		timeout = config.current.request_timeout_ms or 0
		if NON_TIMED_METHODS[method] then
			timeout = 0
		end
	end
	entry.timeout_ms = timeout
	acp_debug(
		self.provider,
		"request start method=%s id=%d timeout_ms=%s pending=%s",
		tostring(method),
		id,
		tostring(timeout),
		pending_summary(self.callbacks)
	)
	if timeout > 0 then
		local timer = vim.uv.new_timer()
		entry.timer = timer
		timer:start(
			timeout,
			0,
			vim.schedule_wrap(function()
				local pending = self.callbacks[id]
				if not pending then
					return
				end
				local pending_before = pending_summary(self.callbacks)
				self.callbacks[id] = nil
				if pending.timer then
					pcall(function()
						pending.timer:stop()
						pending.timer:close()
					end)
				end
				log.warn(
					("acp[%s]: request '%s' (id=%d) timed out after %d ms pending=%s"):format(
						provider_label(self.provider),
						method,
						id,
						timeout,
						pending_before
					)
				)
				pcall(pending.cb, nil, {
					code = -32001,
					message = "request timed out",
					data = { method = method },
				})
			end)
		)
	end

	if self.transport and self.transport.set_idle_armed then
		self.transport:set_idle_armed(true)
	end

	local data = vim.json.encode({
		jsonrpc = "2.0",
		id = id,
		method = method,
		params = params or vim.empty_dict(),
	})
	local sent = self.transport:send(data)
	if sent then
		acp_debug(self.provider, "request sent method=%s id=%d bytes=%d", tostring(method), id, #data)
	else
		self.callbacks[id] = nil
		if entry.timer then
			pcall(function()
				entry.timer:stop()
				entry.timer:close()
			end)
		end
		if not next(self.callbacks) and self.transport and self.transport.set_idle_armed then
			self.transport:set_idle_armed(false)
		end
		local err = {
			code = -32000,
			message = "transport " .. tostring(self.state or "disconnected"),
			data = { method = method },
		}
		log.warn(
			("acp[%s]: failed to send request '%s' (id=%d); transport state=%s"):format(
				provider_label(self.provider),
				method,
				id,
				tostring(self.state)
			)
		)
		vim.schedule(function()
			pcall(callback, nil, err)
		end)
	end
	return id
end

---@param id integer|nil
function Client:forget_request(id)
	if not id then
		return
	end
	local entry = self.callbacks[id]
	if not entry then
		return
	end
	self.callbacks[id] = nil
	acp_debug(
		self.provider,
		"request forgotten method=%s id=%d elapsed_ms=%d pending=%s",
		tostring(entry.method or ""),
		id,
		elapsed_ms(entry.start_ms),
		pending_summary(self.callbacks)
	)
	if entry.timer then
		pcall(function()
			entry.timer:stop()
			entry.timer:close()
		end)
	end
	if not next(self.callbacks) and self.transport and self.transport.set_idle_armed then
		self.transport:set_idle_armed(false)
	end
end

---@param method string
---@param params table|nil
function Client:notify(method, params)
	local data = vim.json.encode({
		jsonrpc = "2.0",
		method = method,
		params = params or vim.empty_dict(),
	})
	local sent = self.transport:send(data)
	if sent then
		acp_debug(self.provider, "notification sent method=%s bytes=%d", tostring(method), #data)
	else
		log.warn(
			("acp[%s]: failed to send notification '%s'; transport state=%s"):format(
				provider_label(self.provider),
				method,
				tostring(self.state)
			)
		)
	end
end

---@param id integer
---@param result table|nil
function Client:respond(id, result)
	local data = vim.json.encode({
		jsonrpc = "2.0",
		id = id,
		result = result or vim.empty_dict(),
	})
	local sent = self.transport:send(data)
	if sent then
		acp_debug(self.provider, "response sent id=%s bytes=%d", tostring(id), #data)
	else
		log.warn(
			("acp[%s]: failed to send response id=%s; transport state=%s"):format(
				provider_label(self.provider),
				tostring(id),
				tostring(self.state)
			)
		)
	end
end

---@param id integer
---@param code integer
---@param message string
---@param data? table
function Client:respond_error(id, code, message, data)
	local err = { code = code, message = message }
	if data then
		err.data = data
	end
	local payload = vim.json.encode({ jsonrpc = "2.0", id = id, error = err })
	local sent = self.transport:send(payload)
	if sent then
		acp_debug(
			self.provider,
			"response error sent id=%s code=%s message=%s bytes=%d",
			tostring(id),
			tostring(code),
			tostring(message),
			#payload
		)
	else
		log.warn(
			("acp[%s]: failed to send error response id=%s; transport state=%s"):format(
				provider_label(self.provider),
				tostring(id),
				tostring(self.state)
			)
		)
	end
end

---@param method string
---@param handler fun(params: table, message_id: integer|nil)
function Client:on_notification(method, handler)
	self.notification_handlers[method] = handler
end

function Client:_on_message(message)
	if message.method and message.result == nil and message.error == nil then
		acp_debug(self.provider, "notification recv %s", notification_summary(message))
		local handler = self.notification_handlers[message.method]
		if handler then
			vim.schedule(function()
				handler(message.params or {}, message.id)
			end)
		else
			vim.schedule(function()
				vim.notify("acp: unhandled notification " .. message.method, vim.log.levels.DEBUG)
			end)
		end
		return
	end

	if message.id ~= nil and (message.result ~= nil or message.error ~= nil) then
		local entry = self.callbacks[message.id]
		if entry then
			self.callbacks[message.id] = nil
			if message.error then
				acp_debug(
					self.provider,
					"response error method=%s id=%s elapsed_ms=%d error=%s",
					tostring(entry.method or ""),
					tostring(message.id),
					elapsed_ms(entry.start_ms),
					err_summary(message.error)
				)
			else
				acp_debug(
					self.provider,
					"response ok method=%s id=%s elapsed_ms=%d result=%s",
					tostring(entry.method or ""),
					tostring(message.id),
					elapsed_ms(entry.start_ms),
					result_summary(entry.method, message.result)
				)
			end
			if entry.timer then
				pcall(function()
					entry.timer:stop()
					entry.timer:close()
				end)
			end
			if not next(self.callbacks) and self.transport and self.transport.set_idle_armed then
				self.transport:set_idle_armed(false)
			end
			vim.schedule(function()
				entry.cb(message.result, message.error)
			end)
		else
			acp_debug(
				self.provider,
				"response ignored id=%s has_error=%s pending=%s",
				tostring(message.id),
				tostring(message.error ~= nil),
				pending_summary(self.callbacks)
			)
		end
		return
	end

	vim.schedule(function()
		if message.error then
			vim.notify("acp: provider error without request id: " .. vim.inspect(message.error), vim.log.levels.WARN)
			return
		end
		vim.notify("acp: unknown message shape: " .. vim.inspect(message), vim.log.levels.WARN)
	end)
end

---@param on_ready fun(self: table)|nil
function Client:start(on_ready)
	if on_ready then
		self.ready_listeners[#self.ready_listeners + 1] = on_ready
	end
	acp_debug(
		self.provider,
		"start command=%s host_fs=%s ready_waiters=%d",
		command_summary(self.provider),
		tostring(self.host_fs),
		#self.ready_listeners
	)

	self:on_notification("session/update", function(params)
		local sub = self.subscribers[params.sessionId]
		if sub and sub.on_update then
			sub.on_update(params.update or {})
		end
	end)

	self:on_notification("session/request_permission", function(params, message_id)
		local sub = self.subscribers[params.sessionId]
		if not sub or not sub.on_request_permission then
			acp_debug(
				self.provider,
				"permission request auto-cancelled session=%s id=%s reason=no_handler",
				tostring(params.sessionId or ""),
				tostring(message_id or "")
			)
			self:respond(message_id, { outcome = { outcome = "cancelled" } })
			return
		end
		if self.transport and self.transport.set_idle_armed then
			self.transport:set_idle_armed(false)
		end
		sub.on_request_permission(params, function(option_id)
			if not option_id or option_id == "" then
				acp_debug(
					self.provider,
					"permission request cancelled session=%s id=%s",
					tostring(params.sessionId or ""),
					tostring(message_id or "")
				)
				self:respond(message_id, { outcome = { outcome = "cancelled" } })
				if next(self.callbacks) and self.transport and self.transport.set_idle_armed then
					self.transport:set_idle_armed(true)
				end
				return
			end
			acp_debug(
				self.provider,
				"permission request selected session=%s id=%s option=%s",
				tostring(params.sessionId or ""),
				tostring(message_id or ""),
				tostring(option_id)
			)
			self:respond(message_id, { outcome = { outcome = "selected", optionId = option_id } })
			if next(self.callbacks) and self.transport and self.transport.set_idle_armed then
				self.transport:set_idle_armed(true)
			end
		end)
	end)

	self:on_notification("fs/read_text_file", function(params, message_id)
		if message_id == nil then
			return
		end
		local sub = self.subscribers[params.sessionId]
		if not sub or not sub.on_fs_read_text_file then
			self:respond_error(message_id, -32601, "fs/read_text_file not handled")
			return
		end
		sub.on_fs_read_text_file(params, function(content, err)
			if err then
				local code = err.code or -32000
				self:respond_error(message_id, code, err.message or tostring(err), err.data)
				return
			end
			self:respond(message_id, { content = content or "" })
		end)
	end)

	self:on_notification("fs/write_text_file", function(params, message_id)
		if message_id == nil then
			return
		end
		local sub = self.subscribers[params.sessionId]
		if not sub or not sub.on_fs_write_text_file then
			self:respond_error(message_id, -32601, "fs/write_text_file not handled")
			return
		end
		sub.on_fs_write_text_file(params, function(err)
			if err then
				local code = err.code or -32000
				self:respond_error(message_id, code, err.message or tostring(err), err.data)
				return
			end
			self:respond(message_id, vim.empty_dict())
		end)
	end)

	self.transport:start()
	self.state = "initializing"
	acp_debug(self.provider, "initialize begin retries=%d", config.current.initialize_retries or 0)
	self:_initialize_with_retry(0)
end

local INITIALIZE_BACKOFF_MS = { 250, 500, 1000 }

function Client:_initialize_with_retry(attempt)
	local max = config.current.initialize_retries or 3
	self:request("initialize", {
		protocolVersion = self.protocol_version,
		clientInfo = { name = "0x0.nvim", version = "7.0.3" },
		clientCapabilities = {
			fs = {
				readTextFile = self.host_fs,
				writeTextFile = self.host_fs,
			},
			terminal = false,
		},
	}, function(result, err)
		if err or not result then
			if attempt + 1 < max then
				local delay = INITIALIZE_BACKOFF_MS[attempt + 1] or 1000
				log.warn(
					("acp: initialize failed (attempt %d/%d), retrying in %d ms: %s"):format(
						attempt + 1,
						max,
						delay,
						vim.inspect(err)
					)
				)
				vim.defer_fn(function()
					if self.state ~= "initializing" then
						return
					end
					self:_initialize_with_retry(attempt + 1)
				end, delay)
				return
			end
			log.error("acp: initialize failed after retries: " .. vim.inspect(err))
			vim.notify("acp: initialize failed: " .. vim.inspect(err), vim.log.levels.ERROR)
			self:_on_state("error")
			return
		end
		self.protocol_version = result.protocolVersion or self.protocol_version
		self.agent_info = result.agentInfo
		self.agent_capabilities = result.agentCapabilities
		self.state = "ready"
		acp_debug(
			self.provider,
			"initialize ready protocol=%s agent=%s version=%s capabilities=%s",
			tostring(self.protocol_version),
			tostring(self.agent_info and self.agent_info.name or ""),
			tostring(self.agent_info and self.agent_info.version or ""),
			vim.inspect(self.agent_capabilities or {})
		)
		local listeners = self.ready_listeners
		self.ready_listeners = {}
		for _, listener in ipairs(listeners) do
			pcall(listener, self)
		end
	end)
end

---@param session_id string
---@param handlers { on_update: fun(update: table), on_request_permission?: fun(request: table, respond: fun(option_id: string)) }
function Client:subscribe(session_id, handlers)
	self.subscribers[session_id] = handlers
end

---@param session_id string
function Client:unsubscribe(session_id)
	self.subscribers[session_id] = nil
end

---@param cwd string
---@param callback fun(result: table|nil, err: table|nil)
function Client:new_session(cwd, callback)
	return self:request("session/new", { cwd = cwd, mcpServers = {} }, callback)
end

---@param session_id string
---@param prompt_blocks table[]
---@param callback fun(result: table|nil, err: table|nil)
---@param opts? { timeout_ms?: integer }
function Client:prompt(session_id, prompt_blocks, callback, opts)
	return self:request("session/prompt", { sessionId = session_id, prompt = prompt_blocks }, callback, opts)
end

---@param session_id string
function Client:cancel(session_id)
	if not session_id then
		return
	end
	self:notify("session/cancel", { sessionId = session_id })
end

function Client:supports_session_close()
	local capabilities = self.agent_capabilities or {}
	local session_capabilities = capabilities.sessionCapabilities or {}
	return session_capabilities.close ~= nil
end

---@param session_id string
---@param callback? fun(result: table|nil, err: table|nil)
function Client:close_session(session_id, callback)
	if not session_id then
		return
	end
	if not self:supports_session_close() then
		log.debug(
			("acp[%s]: skipping session/close; provider did not advertise sessionCapabilities.close session=%s"):format(
				provider_label(self.provider),
				tostring(session_id)
			)
		)
		if callback then
			vim.schedule(function()
				callback(nil, nil)
			end)
		end
		return
	end
	if self.state == "disconnected" or self.state == "error" then
		acp_debug(
			self.provider,
			"session/close skipped session=%s reason=transport_%s",
			tostring(session_id),
			tostring(self.state)
		)
		if callback then
			vim.schedule(function()
				callback(nil, nil)
			end)
		end
		return
	end
	acp_debug(self.provider, "session/close start session=%s", tostring(session_id))
	return self:request("session/close", { sessionId = session_id }, function(result, err)
		if err then
			log.warn(
				("acp[%s]: session/close failed session=%s err=%s"):format(
					provider_label(self.provider),
					tostring(session_id),
					vim.inspect(err)
				)
			)
		else
			acp_debug(self.provider, "session/close done session=%s", tostring(session_id))
		end
		if callback then
			callback(result, err)
		end
	end)
end

---@param session_id string
---@param config_id string|nil
---@param value string|nil
---@param callback fun(result: table|nil, err: table|nil)
function Client:set_config_option(session_id, config_id, value, callback)
	if not session_id or not config_id or config_id == "" or not value or value == "" then
		callback(nil, nil)
		return
	end
	return self:request(
		"session/set_config_option",
		{ sessionId = session_id, configId = config_id, value = value },
		callback
	)
end

function Client:is_ready()
	return self.state == "ready"
end

function Client:stop()
	self.subscribers = {}
	self.transport:stop()
end

-- ---------------------------------------------------------------------------
-- Inline completion: lightweight wrapper around new()/start()/new_session()
-- for ghost-text completion. Completion sessions are context-only and use a
-- per-provider singleton client so providers are not respawned on every key.
-- ---------------------------------------------------------------------------

local _completion_clients = {}
local _client_factory = nil

---@param fn fun(provider: table, opts?: table): table|nil
function M._set_client_factory(fn)
	_client_factory = fn
end

function M._reset_client_factory()
	_client_factory = nil
end

local function _create_client(provider, opts)
	if _client_factory then
		return _client_factory(provider, opts)
	end
	return M.new(provider, opts)
end

local function _completion_key(provider)
	return tostring(provider.command) .. "\0" .. table.concat(provider.args or {}, "\1")
end

local function _completion_session_reuse_config(complete_cfg)
	local raw = type(complete_cfg) == "table" and complete_cfg.session_reuse or nil
	if raw == false then
		return { enabled = false }
	end
	if raw == true or raw == nil then
		raw = {}
	end
	if type(raw) ~= "table" then
		raw = {}
	end
	return {
		enabled = raw.enabled ~= false,
		max_prompts = math.max(1, tonumber(raw.max_prompts) or 12),
		max_age_ms = math.max(1, tonumber(raw.max_age_ms) or 180000),
		max_idle_ms = math.max(1, tonumber(raw.max_idle_ms) or 60000),
	}
end

local function _completion_session_key(request, complete_cfg)
	local cwd = tostring(request.cwd or vim.fn.getcwd())
	local effort = complete_cfg.effort or complete_cfg.reasoning_effort or complete_cfg.thought_level or "none"
	return table.concat({
		cwd,
		tostring(request.model or ""),
		tostring(effort or ""),
		tostring(complete_cfg.temperature or ""),
		tostring(complete_cfg.max_tokens or ""),
	}, "\0")
end

local function _completion_entry(provider, client)
	local entry = _completion_clients[_completion_key(provider)]
	if entry and entry.client == client then
		return entry
	end
end

local function _session_is_reusable(session, reuse_cfg)
	if not session or not reuse_cfg.enabled then
		return false, "disabled"
	end
	if session.in_use then
		return false, "in_use"
	end
	if session.closing then
		return false, "closing"
	end
	if session.prompt_count >= reuse_cfg.max_prompts then
		return false, "prompt_budget"
	end
	local now = now_ms()
	if elapsed_ms(session.created_ms) >= reuse_cfg.max_age_ms then
		return false, "age_budget"
	end
	if session.last_used_ms and now - session.last_used_ms >= reuse_cfg.max_idle_ms then
		return false, "idle_budget"
	end
	return true, nil
end

local function _remove_cached_session(provider, client, session)
	local entry = _completion_entry(provider, client)
	if not entry or not entry.sessions then
		return
	end
	for key, cached in pairs(entry.sessions) do
		if cached == session then
			entry.sessions[key] = nil
		end
	end
end

local _discard_completion_client

local function _retire_completion_session(provider, client, session, reason)
	if not session or session.closing then
		return
	end
	session.closing = true
	session.in_use = false
	_remove_cached_session(provider, client, session)
	completion_debug(
		"session retire provider=%s session=%s reason=%s prompts=%d",
		provider_label(provider),
		tostring(session.id or ""),
		tostring(reason or ""),
		tonumber(session.prompt_count) or 0
	)
	if client and session.id then
		pcall(function()
			client:unsubscribe(session.id)
		end)
		if client:supports_session_close() then
			client:close_session(session.id)
		else
			_discard_completion_client(provider, client, "retired session without close support")
		end
	end
end

function _discard_completion_client(provider, client, reason)
	local key = _completion_key(provider)
	local entry = _completion_clients[key]
	if not entry or entry.client ~= client then
		return
	end
	completion_debug(
		"client discard provider=%s key=%s reason=%s",
		provider_label(provider),
		display_key(key),
		tostring(reason or "")
	)
	_completion_clients[key] = nil
	if entry.sessions then
		for _, session in pairs(entry.sessions) do
			session.closing = true
			session.in_use = false
		end
	end
	pcall(function()
		client:stop()
	end)
end

local function _flush_completion_waiters(entry, client, err)
	local waiters = entry.ready_waiters
	entry.ready_waiters = {}
	for _, fn in ipairs(waiters) do
		vim.schedule(function()
			fn(client, err)
		end)
	end
end

local function _get_completion_client(provider, on_ready)
	local key = _completion_key(provider)
	local entry = _completion_clients[key]
	if entry and entry.client and entry.client.state ~= "disconnected" and entry.client.state ~= "error" then
		if entry.authenticated and entry.client:is_ready() then
			completion_debug(
				"client reuse provider=%s key=%s state=%s authenticated=true",
				provider_label(provider),
				display_key(key),
				tostring(entry.client.state)
			)
			vim.schedule(function()
				on_ready(entry.client, nil)
			end)
		else
			completion_debug(
				"client wait provider=%s key=%s state=%s authenticated=%s waiters=%d",
				provider_label(provider),
				display_key(key),
				tostring(entry.client.state),
				tostring(entry.authenticated),
				#entry.ready_waiters + 1
			)
			entry.ready_waiters[#entry.ready_waiters + 1] = on_ready
		end
		return entry.client
	end

	completion_debug(
		"client create provider=%s command=%s key=%s",
		provider_label(provider),
		command_summary(provider),
		display_key(key)
	)
	local client = _create_client(provider, { host_fs = false })
	entry = {
		client = client,
		ready_waiters = { on_ready },
		authenticated = false,
		sessions = {},
	}
	_completion_clients[key] = entry

	client:start(function(c)
		if not c then
			completion_debug("client start failed provider=%s key=%s", provider_label(provider), display_key(key))
			_completion_clients[key] = nil
			_flush_completion_waiters(entry, nil, { message = "completion client unavailable" })
			return
		end
		if provider.auth_method and provider.auth_method ~= "" then
			completion_debug(
				"client authenticate start provider=%s method=%s",
				provider_label(provider),
				tostring(provider.auth_method)
			)
			c:request("authenticate", { methodId = provider.auth_method }, function(_, err)
				if err then
					log.error("acp[completion]: authenticate failed: " .. vim.inspect(err))
					_completion_clients[key] = nil
					_flush_completion_waiters(entry, nil, err)
					return
				end
				completion_debug("client authenticate done provider=%s", provider_label(provider))
				entry.authenticated = true
				_flush_completion_waiters(entry, c, nil)
			end)
		else
			completion_debug("client ready provider=%s auth=none", provider_label(provider))
			entry.authenticated = true
			_flush_completion_waiters(entry, c, nil)
		end
	end)
	return client
end

local function _model_config_option(config_options)
	for _, option in ipairs(config_options or {}) do
		if
			type(option) == "table"
			and option.type == "select"
			and (option.category == "model" or option.id == "model")
		then
			return option
		end
	end

	for _, option in ipairs(config_options or {}) do
		if type(option) == "table" and option.type == "select" and tostring(option.name or ""):lower() == "model" then
			return option
		end
	end
end

local function _model_config_value(option, requested_model)
	if type(option) ~= "table" or type(requested_model) ~= "string" or requested_model == "" then
		return nil
	end

	local requested_lower = requested_model:lower()
	local requested_fast_base = requested_lower:match("^(.*)%-fast$")
	for _, candidate in ipairs(option.options or {}) do
		if type(candidate) == "table" then
			local value = candidate.value
			local name = candidate.name
			if value == requested_model or name == requested_model then
				return value
			end
			if type(value) == "string" and value:lower() == requested_lower then
				return value
			end
			if type(name) == "string" and name:lower() == requested_lower then
				return value
			end
			if requested_fast_base and type(value) == "string" and value ~= "" then
				local value_lower = value:lower()
				local value_base = value_lower:match("^(.-)%[") or value_lower
				if value_base == requested_fast_base and value_lower:find("fast%s*=%s*true") then
					return value
				end
			end
		end
	end
end

local function _model_config_values(option)
	local values = {}
	for _, candidate in ipairs(type(option) == "table" and option.options or {}) do
		if type(candidate) == "table" and type(candidate.value) == "string" and candidate.value ~= "" then
			values[#values + 1] = candidate.value
		end
	end
	return values
end

local function _model_option_summary(option)
	if type(option) ~= "table" then
		return "none"
	end
	local values = _model_config_values(option)
	local displayed = {}
	for i = 1, math.min(#values, 8) do
		displayed[#displayed + 1] = values[i]
	end
	if #values > #displayed then
		displayed[#displayed + 1] = "..."
	end
	return ("id=%s name=%s current=%s options=%d values=%s"):format(
		tostring(option.id or ""),
		tostring(option.name or ""),
		tostring(option.currentValue or ""),
		#(option.options or {}),
		table.concat(displayed, ",")
	)
end

local function _option_label(option)
	return table
		.concat({
			tostring(option.category or ""),
			tostring(option.id or ""),
			tostring(option.name or ""),
		}, " ")
		:lower()
end

local function _matches_all(label, words)
	for _, word in ipairs(words) do
		if not label:find(word, 1, true) then
			return false
		end
	end
	return true
end

local function _select_config_option(config_options, matcher)
	for _, option in ipairs(config_options or {}) do
		if type(option) == "table" and option.type == "select" and matcher(option, _option_label(option)) then
			return option
		end
	end
end

local function _select_exact_value(option, desired_values)
	if type(option) ~= "table" then
		return nil
	end
	for _, desired in ipairs(desired_values or {}) do
		local desired_text = tostring(desired or "")
		if desired_text ~= "" then
			local desired_lower = desired_text:lower()
			for _, candidate in ipairs(option.options or {}) do
				if type(candidate) == "table" then
					local value = candidate.value
					local name = candidate.name
					if value == desired_text or name == desired_text then
						return value
					end
					if type(value) == "string" and value:lower() == desired_lower then
						return value
					end
					if type(name) == "string" and name:lower() == desired_lower then
						return value
					end
				end
			end
		end
	end
end

local function _select_small_numeric_value(option, preferred)
	local preferred_number = tonumber(preferred)
	local best_value = nil
	local best_score = nil
	for _, candidate in ipairs(type(option) == "table" and option.options or {}) do
		if type(candidate) == "table" then
			local value = candidate.value
			local number = tonumber(value) or tonumber(candidate.name)
			if number then
				local score = number
				if preferred_number and number <= preferred_number then
					score = -number
				end
				if not best_score or score < best_score then
					best_score = score
					best_value = value
				end
			end
		end
	end
	return best_value
end

local function _completion_config_choice(role, config_options, request, complete_cfg)
	if role == "model" then
		if not request.model or request.model == "" then
			return nil, nil, nil, "no_requested_model"
		end
		local option = _model_config_option(config_options)
		if not option then
			return nil, nil, nil, "no_model_option"
		end
		local value = _model_config_value(option, request.model)
		if not value then
			return option,
				nil,
				{
					code = -32602,
					message = "requested completion model is not advertised by provider: " .. tostring(request.model),
					data = { availableModels = _model_config_values(option) },
				},
				"model_unavailable"
		end
		return option, value, nil, nil
	end

	if role == "effort" then
		local option = _select_config_option(config_options, function(option, label)
			return option.category == "thought_level"
				or option.category == "reasoning"
				or label:find("thought", 1, true) ~= nil
				or label:find("thinking", 1, true) ~= nil
				or label:find("reasoning", 1, true) ~= nil
				or label:find("effort", 1, true) ~= nil
		end)
		if not option then
			return nil, nil, nil, "no_effort_option"
		end
		local configured = complete_cfg.effort or complete_cfg.reasoning_effort or complete_cfg.thought_level or "none"
		local value = _select_exact_value(option, {
			configured,
			"none",
			"off",
			"disabled",
			"false",
			"0",
			"minimal",
			"minimum",
			"low",
		})
		return option, value, nil, value and nil or "no_effort_value"
	end

	if role == "temperature" then
		local option = _select_config_option(config_options, function(_, label)
			return label:find("temperature", 1, true) ~= nil
		end)
		if not option then
			return nil, nil, nil, "no_temperature_option"
		end
		local configured = complete_cfg.temperature
		local value = _select_exact_value(option, { configured, "0", "0.0", "zero", "deterministic" })
			or _select_small_numeric_value(option, configured)
		return option, value, nil, value and nil or "no_temperature_value"
	end

	if role == "max_tokens" then
		local option = _select_config_option(config_options, function(_, label)
			return _matches_all(label, { "token" }) and (label:find("max", 1, true) or label:find("output", 1, true))
		end)
		if not option then
			return nil, nil, nil, "no_max_tokens_option"
		end
		local configured = complete_cfg.max_tokens
		local value = _select_exact_value(option, { configured }) or _select_small_numeric_value(option, configured)
		return option, value, nil, value and nil or "no_max_tokens_value"
	end
end

local function _is_prompt_timeout(err)
	return type(err) == "table"
		and err.code == -32001
		and err.message == "request timed out"
		and type(err.data) == "table"
		and err.data.method == "session/prompt"
end

local function _is_transport_closed(err)
	return type(err) == "table" and err.code == -32000 and tostring(err.message or ""):match("^transport ") ~= nil
end

local function _scope_block(scope)
	if type(scope) ~= "table" or type(scope.text) ~= "string" or scope.text == "" then
		return nil
	end
	return table.concat({
		("Relevant surrounding code (%s, lines %s-%s):"):format(
			tostring(scope.type or ""),
			tostring(scope.start_line or ""),
			tostring(scope.end_line or "")
		),
		scope.text,
	}, "\n")
end

local function _completion_prompt(request)
	local lines = {
		("Return only the %s text to insert after this cursor."):format(tostring(request.language or "code")),
		"No tools. No search. No explanation. No markdown.",
		"",
	}

	local scope = _scope_block(request.scope)
	if scope then
		lines[#lines + 1] = scope
		lines[#lines + 1] = ""
	end

	vim.list_extend(lines, {
		"Code before cursor: " .. tostring(request.prefix or ""),
		"",
		"Code after cursor: " .. tostring(request.suffix or ""),
		"",
		"Text to insert:",
	})
	return table.concat(lines, "\n")
end

---Stream an inline completion. Completion sessions are context-only: they do
---not expose host fs and do not install permission handlers.
---@param provider { command: string, args?: string[], auth_method?: string, name?: string }
---@param request { prefix: string, suffix: string, language?: string, filepath?: string, model?: string }
---@param on_chunk fun(text: string)
---@param on_done fun(err?: any)
---@return fun() abort
function M.stream_completion(provider, request, on_chunk, on_done)
	local active = true
	local done = false
	local session_id = nil
	local client_ref = nil
	local session_entry = nil
	local session_closed = false
	local pending_requests = {}
	local complete_cfg = config.current.complete or {}
	local reuse_cfg = _completion_session_reuse_config(complete_cfg)
	local session_cache_key = _completion_session_key(request, complete_cfg)
	local prompt_timeout_ms = complete_cfg.prompt_timeout_ms
	local new_session_request_id = nil
	local prompt_request_id = nil
	local started_ms = now_ms()
	local chunk_count = 0
	local streamed_chars = 0
	local update_count = 0

	local scope = request.scope or {}
	completion_debug(
		"stream start provider=%s command=%s model=%s cwd=%s prompt_timeout_ms=%s prefix_chars=%d suffix_chars=%d scope=%s:%s-%s",
		provider_label(provider),
		command_summary(provider),
		tostring(request.model or ""),
		tostring(request.cwd or ""),
		tostring(prompt_timeout_ms),
		#tostring(request.prefix or ""),
		#tostring(request.suffix or ""),
		tostring(scope.type or "none"),
		tostring(scope.start_line or ""),
		tostring(scope.end_line or "")
	)

	local function track_request(id)
		if id then
			pending_requests[id] = true
			completion_debug(
				"track request id=%s session=%s pending=%s",
				tostring(id),
				tostring(session_id or ""),
				pending_summary(pending_requests)
			)
		end
		return id
	end

	local function untrack_request(id)
		if id and pending_requests[id] then
			pending_requests[id] = nil
			completion_debug(
				"untrack request id=%s session=%s pending=%s",
				tostring(id),
				tostring(session_id or ""),
				pending_summary(pending_requests)
			)
			return
		end
		pending_requests[id] = nil
	end

	local function forget_pending_requests(skip_id)
		if client_ref then
			for id in pairs(pending_requests) do
				if id ~= skip_id then
					client_ref:forget_request(id)
				end
			end
		end
		if skip_id then
			pending_requests = { [skip_id] = pending_requests[skip_id] }
		else
			pending_requests = {}
		end
	end

	local function close_session()
		if session_closed or not session_id or not client_ref then
			return
		end
		session_closed = true
		completion_debug("session close requested session=%s", tostring(session_id))
		client_ref:close_session(session_id)
	end

	local function finish(err)
		if done then
			return
		end
		local prompt_timed_out = _is_prompt_timeout(err)
		local transport_closed = _is_transport_closed(err)
		done = true
		active = false
		completion_debug(
			"stream finish status=%s elapsed_ms=%d session=%s chunks=%d streamed_chars=%d updates=%d pending=%s err=%s",
			err and "error" or "ok",
			elapsed_ms(started_ms),
			tostring(session_id or ""),
			chunk_count,
			streamed_chars,
			update_count,
			pending_summary(pending_requests),
			err_summary(err)
		)
		forget_pending_requests()
		if session_id and client_ref then
			if prompt_timed_out then
				client_ref:cancel(session_id)
			end
			client_ref:unsubscribe(session_id)
			if session_entry then
				session_entry.in_use = false
				session_entry.last_used_ms = now_ms()
				if transport_closed then
					session_entry.closing = true
					_remove_cached_session(provider, client_ref, session_entry)
					session_entry = nil
				elseif err then
					_retire_completion_session(provider, client_ref, session_entry, err_summary(err))
					session_entry = nil
				else
					local reusable, reason = _session_is_reusable(session_entry, reuse_cfg)
					if reusable then
						completion_debug(
							"session cached session=%s prompts=%d cache_key=%s",
							tostring(session_entry.id or ""),
							tonumber(session_entry.prompt_count) or 0,
							display_key(session_cache_key)
						)
					else
						_retire_completion_session(provider, client_ref, session_entry, reason)
						session_entry = nil
					end
				end
			elseif not transport_closed then
				close_session()
			end
		end
		if (prompt_timed_out or transport_closed) and client_ref then
			_discard_completion_client(
				provider,
				client_ref,
				prompt_timed_out and "session/prompt timeout" or "transport closed"
			)
		end
		vim.schedule(function()
			on_done(err)
		end)
	end

	_get_completion_client(provider, function(client, ready_err)
		if not active then
			return
		end
		if ready_err or not client then
			finish(ready_err or { message = "completion client unavailable" })
			return
		end
		client_ref = client
		completion_debug(
			"client ready provider=%s state=%s agent=%s protocol=%s elapsed_ms=%d",
			provider_label(provider),
			tostring(client.state or ""),
			tostring(client.agent_info and client.agent_info.name or ""),
			tostring(client.protocol_version or ""),
			elapsed_ms(started_ms)
		)
		local entry = _completion_entry(provider, client)
		if entry and not entry.sessions then
			entry.sessions = {}
		end

		local function subscribe_session()
			client:subscribe(session_id, {
				on_update = function(update)
					if not active then
						return
					end
					update_count = update_count + 1
					completion_debug(
						"session/update session=%s update=%s",
						tostring(session_id),
						tostring(update.sessionUpdate or "")
					)
					if update.sessionUpdate ~= "agent_message_chunk" then
						return
					end
					local content = update.content
					if type(content) == "table" and content.type == "text" and content.text then
						chunk_count = chunk_count + 1
						streamed_chars = streamed_chars + #content.text
						completion_debug(
							"chunk recv session=%s chunk=%d chars=%d total_chars=%d",
							tostring(session_id),
							chunk_count,
							#content.text,
							streamed_chars
						)
						vim.schedule(function()
							if active then
								on_chunk(content.text)
							end
						end)
					end
				end,
			})
			completion_debug("session subscribed session=%s", tostring(session_id))
		end

		local function send_prompt()
			local prompt_opts = nil
			if prompt_timeout_ms ~= nil then
				prompt_opts = { timeout_ms = prompt_timeout_ms }
			end
			local prompt_text = _completion_prompt(request)
			local prompt_started_ms = now_ms()
			if session_entry then
				session_entry.prompt_count = (tonumber(session_entry.prompt_count) or 0) + 1
				session_entry.in_use = true
			end
			completion_debug(
				"send prompt provider=%s session=%s model=%s prompt_chars=%d prefix_chars=%d suffix_chars=%d timeout_ms=%s scope=%s:%s-%s",
				tostring(provider.name or provider.command),
				tostring(session_id),
				tostring(request.model or ""),
				#prompt_text,
				#tostring(request.prefix or ""),
				#tostring(request.suffix or ""),
				tostring(prompt_timeout_ms),
				tostring(scope.type or "none"),
				tostring(scope.start_line or ""),
				tostring(scope.end_line or "")
			)
			prompt_request_id = track_request(client:prompt(session_id, {
				{ type = "text", text = prompt_text },
			}, function(_, prompt_err)
				untrack_request(prompt_request_id)
				completion_debug(
					"prompt done session=%s id=%s elapsed_ms=%d chunks=%d streamed_chars=%d err=%s",
					tostring(session_id),
					tostring(prompt_request_id or ""),
					elapsed_ms(prompt_started_ms),
					chunk_count,
					streamed_chars,
					err_summary(prompt_err)
				)
				if done then
					if session_entry and session_entry.cancelling then
						session_entry.cancelling = false
						session_entry.in_use = false
						session_entry.last_used_ms = now_ms()
						if prompt_err then
							_retire_completion_session(provider, client_ref, session_entry, err_summary(prompt_err))
							session_entry = nil
						else
							local reusable, reason = _session_is_reusable(session_entry, reuse_cfg)
							if not reusable then
								_retire_completion_session(provider, client_ref, session_entry, reason)
								session_entry = nil
							end
						end
					end
					return
				end
				finish(prompt_err)
			end, prompt_opts))
			completion_debug(
				"prompt request sent session=%s id=%s timeout_ms=%s",
				tostring(session_id),
				tostring(prompt_request_id or ""),
				tostring(prompt_timeout_ms)
			)
		end

		local function configure_session(config_options, callback)
			local roles = { "model", "effort", "temperature", "max_tokens" }
			local function configure_next(index, options)
				if not active then
					return
				end
				local role = roles[index]
				if not role then
					callback(nil)
					return
				end
				local option, value, choice_err, skip_reason =
					_completion_config_choice(role, options, request, complete_cfg)
				if choice_err then
					completion_debug(
						"config %s failed session=%s reason=%s err=%s",
						role,
						tostring(session_id),
						tostring(skip_reason or ""),
						err_summary(choice_err)
					)
					callback(choice_err)
					return
				end
				if not option or not value then
					completion_debug(
						"config %s skipped session=%s reason=%s",
						role,
						tostring(session_id),
						tostring(skip_reason or "no_option")
					)
					configure_next(index + 1, options)
					return
				end
				if option.currentValue == value then
					completion_debug(
						"config %s already selected session=%s value=%s option=%s",
						role,
						tostring(session_id),
						tostring(value),
						tostring(option.id or "")
					)
					configure_next(index + 1, options)
					return
				end

				local config_request_id
				local config_started_ms = now_ms()
				completion_debug(
					"config %s set start session=%s value=%s option=%s",
					role,
					tostring(session_id),
					tostring(value),
					tostring(option.id or "")
				)
				config_request_id =
					track_request(client:set_config_option(session_id, option.id, value, function(result, config_err)
						untrack_request(config_request_id)
						completion_debug(
							"config %s set done session=%s id=%s elapsed_ms=%d err=%s",
							role,
							tostring(session_id),
							tostring(config_request_id or ""),
							elapsed_ms(config_started_ms),
							err_summary(config_err)
						)
						if config_err then
							callback(config_err)
							return
						end
						local next_options = options
						if
							type(result) == "table"
							and type(result.configOptions) == "table"
							and #result.configOptions > 0
						then
							next_options = result.configOptions
						end
						configure_next(index + 1, next_options)
					end))
			end
			configure_next(1, config_options or {})
		end

		local function start_session(result, reused)
			session_id = result.sessionId
			subscribe_session()
			if reused then
				completion_debug(
					"session reuse session=%s prompts=%d cache_key=%s",
					tostring(session_id),
					tonumber(session_entry and session_entry.prompt_count) or 0,
					display_key(session_cache_key)
				)
				send_prompt()
				return
			end
			configure_session(result.configOptions or {}, function(config_err)
				if config_err then
					finish(config_err)
					return
				end
				send_prompt()
			end)
		end

		local cached = entry and entry.sessions and entry.sessions[session_cache_key] or nil
		local reusable, reuse_reason = _session_is_reusable(cached, reuse_cfg)
		if cached and not reusable then
			if reuse_reason ~= "in_use" and reuse_reason ~= "closing" then
				_retire_completion_session(provider, client, cached, reuse_reason)
			end
			cached = nil
		end
		if cached and reusable then
			session_entry = cached
			session_entry.in_use = true
			start_session({ sessionId = cached.id, configOptions = cached.config_options or {} }, true)
			return
		end

		local session_started_ms = now_ms()
		completion_debug("session/new start cwd=%s", tostring(request.cwd or vim.fn.getcwd()))
		new_session_request_id = track_request(client:new_session(request.cwd or vim.fn.getcwd(), function(result, err)
			untrack_request(new_session_request_id)
			if not active then
				if result and result.sessionId then
					_retire_completion_session(provider, client, {
						id = result.sessionId,
						prompt_count = 0,
						created_ms = now_ms(),
						last_used_ms = now_ms(),
					}, "aborted before session ready")
				end
				return
			end
			if err or not result or not result.sessionId then
				completion_debug(
					"session/new failed elapsed_ms=%d err=%s",
					elapsed_ms(session_started_ms),
					err_summary(err)
				)
				finish(err or "session/new returned no sessionId")
				return
			end
			session_entry = {
				id = result.sessionId,
				config_options = result.configOptions or {},
				prompt_count = 0,
				created_ms = now_ms(),
				last_used_ms = now_ms(),
				in_use = true,
			}
			if entry and entry.sessions and reuse_cfg.enabled then
				entry.sessions[session_cache_key] = session_entry
			end
			completion_debug(
				"session/new done session=%s elapsed_ms=%d config_options=%d model_option=%s reuse=%s cache_key=%s",
				tostring(result.sessionId),
				elapsed_ms(session_started_ms),
				#(result.configOptions or {}),
				_model_option_summary(_model_config_option(result.configOptions)),
				tostring(reuse_cfg.enabled),
				display_key(session_cache_key)
			)
			start_session(result, false)
		end))
	end)

	return function()
		if done or not active then
			return
		end
		done = true
		active = false
		if session_id and client_ref then
			client_ref:cancel(session_id)
			client_ref:unsubscribe(session_id)
			if session_entry and prompt_request_id and reuse_cfg.enabled then
				session_entry.cancelling = true
				completion_debug("session cancel pending session=%s", tostring(session_id))
				forget_pending_requests(prompt_request_id)
				return
			end
			if session_entry then
				_retire_completion_session(provider, client_ref, session_entry, "aborted before prompt completed")
				session_entry = nil
			else
				close_session()
			end
		end
		if not session_id and new_session_request_id then
			forget_pending_requests(new_session_request_id)
			return
		end
		forget_pending_requests()
	end
end

---Stop all singleton completion provider subprocesses.
function M.stop_all_completion_clients()
	for key, entry in pairs(_completion_clients) do
		if entry.client then
			pcall(function()
				entry.client:stop()
			end)
		end
		_completion_clients[key] = nil
	end
end

return M
