local uv = vim.uv or vim.loop
local log = require("zxz.core.log")

local M = {}

local function build_env(overrides)
	local env_map = {}
	for k, v in pairs(vim.fn.environ()) do
		env_map[k] = v
	end
	env_map.NODE_NO_WARNINGS = "1"
	if overrides then
		for k, v in pairs(overrides) do
			env_map[k] = v
		end
	end
	local list = {}
	for k, v in pairs(env_map) do
		list[#list + 1] = k .. "=" .. v
	end
	return list
end

---@param config { command: string, args?: string[], env?: table<string, string> }
---@param callbacks { on_state: fun(state: string), on_message: fun(msg: table), on_exit?: fun(code: integer, stderr: string[]), on_idle?: fun(ms: integer) }
---@param opts? { idle_kill_ms?: integer }
function M.create(config, callbacks, opts)
	opts = opts or {}
	local idle_kill_ms = opts.idle_kill_ms or 0
	local self = {
		stdin = nil,
		stdout = nil,
		process = nil,
		process_pid = nil,
		idle_timer = nil,
		idle_armed = false,
	}

	local function stop_idle_timer()
		if self.idle_timer then
			self.idle_timer:stop()
			self.idle_timer:close()
			self.idle_timer = nil
		end
	end

	local function bump_idle()
		if not self.idle_armed or idle_kill_ms <= 0 then
			return
		end
		if not self.idle_timer then
			self.idle_timer = uv.new_timer()
		end
		self.idle_timer:stop()
		self.idle_timer:start(
			idle_kill_ms,
			0,
			vim.schedule_wrap(function()
				log.warn(
					("completion-server[%s]: no I/O for %d ms — killing subprocess"):format(
						config.command,
						idle_kill_ms
					)
				)
				if callbacks.on_idle then
					callbacks.on_idle(idle_kill_ms)
				end
				if self.stop then
					self:stop()
				end
			end)
		)
	end

	---@param armed boolean true while a request is in flight; arms the idle timer
	function self:set_idle_armed(armed)
		self.idle_armed = armed and true or false
		if not self.idle_armed then
			stop_idle_timer()
		else
			bump_idle()
		end
	end

	function self:send(data)
		if self.stdin and not self.stdin:is_closing() then
			self.stdin:write(data .. "\n")
			bump_idle()
			return true
		end
		return false
	end

	function self:start()
		callbacks.on_state("connecting")

		local stdin = uv.new_pipe(false)
		local stdout = uv.new_pipe(false)
		local stderr = uv.new_pipe(false)
		if not stdin or not stdout or not stderr then
			callbacks.on_state("error")
			error("completion-server: failed to create pipes")
		end

		local stderr_buffer = {}
		local args = vim.deepcopy(config.args or {})

		local ok, handle, pid_or_err = pcall(uv.spawn, config.command, {
			args = args,
			env = build_env(config.env),
			stdio = { stdin, stdout, stderr },
			detached = false,
		}, function(code, _signal)
			stop_idle_timer()
			if callbacks.on_exit then
				vim.schedule(function()
					callbacks.on_exit(code, stderr_buffer)
				end)
			end
			callbacks.on_state("disconnected")
			if self.process then
				self.process:close()
				self.process = nil
				self.process_pid = nil
			end
		end)

		if not ok or not handle then
			stdin:close()
			stdout:close()
			stderr:close()
			callbacks.on_state("error")
			log.error(
				("completion-server: spawn failed for '%s': %s"):format(config.command, tostring(handle or pid_or_err))
			)
			vim.schedule(function()
				vim.notify(
					("0x0 completion: failed to spawn '%s': %s"):format(config.command, tostring(handle or pid_or_err)),
					vim.log.levels.ERROR
				)
			end)
			return
		end

		self.process = handle
		self.process_pid = pid_or_err
		self.stdin = stdin
		self.stdout = stdout

		callbacks.on_state("connected")

		local buffered = ""
		stdout:read_start(function(err, data)
			if err then
				log.error("completion-server stdout error: " .. err)
				callbacks.on_state("error")
				return
			end
			if not data then
				callbacks.on_state("disconnected")
				return
			end
			bump_idle()
			buffered = buffered .. data
			local lines = vim.split(buffered, "\n", { plain = true })
			buffered = lines[#lines]
			for i = 1, #lines - 1 do
				local line = vim.trim(lines[i])
				if line ~= "" then
					local decode_ok, message = pcall(vim.json.decode, line)
					if decode_ok then
						callbacks.on_message(message)
					else
						log.warn("completion-server: failed to decode JSON line: " .. line)
					end
				end
			end
		end)

		stderr:read_start(function(_, data)
			if not data then
				return
			end
			bump_idle()
			local trimmed = vim.trim(data)
			if trimmed == "" then
				return
			end
			stderr_buffer[#stderr_buffer + 1] = trimmed
			log.debug("completion-server stderr: " .. trimmed)
		end)
	end

	function self:stop()
		stop_idle_timer()
		if self.process and not self.process:is_closing() then
			local p = self.process
			self.process = nil
			pcall(function()
				p:kill(15)
			end)
			pcall(function()
				p:kill(9)
			end)
			p:close()
		end
		self.process_pid = nil
		if self.stdin then
			self.stdin:close()
			self.stdin = nil
		end
		if self.stdout then
			self.stdout:close()
			self.stdout = nil
		end
		callbacks.on_state("disconnected")
	end

	return self
end

return M
