describe("acp inline completion lifecycle", function()
	local acp_client
	local config

	local function make_fake_client(overrides)
		overrides = overrides or {}
		local calls = {
			cancel = {},
			close = {},
			set_config = {},
			set_model = {},
			unsubscribe = {},
			prompt_opts = {},
		}

		local client
		client = {
			state = "ready",
			agent_capabilities = overrides.supports_close == false and { sessionCapabilities = {} }
				or { sessionCapabilities = { close = {} } },
			callbacks = {},
			id_counter = 0,
			is_ready = function()
				return true
			end,
			start = function(self, on_ready)
				vim.schedule(function()
					on_ready(self)
				end)
			end,
			request = function(self, method, params, callback, opts)
				self.id_counter = self.id_counter + 1
				local id = self.id_counter
				self.callbacks[id] = { cb = callback, method = method, opts = opts }
				if method == "session/new" then
					vim.schedule(function()
						callback(overrides.new_session_result or { sessionId = "sess-test" }, nil)
					end)
				end
				return id
			end,
			new_session = function(self, cwd, callback)
				return self:request("session/new", { cwd = cwd }, callback)
			end,
			prompt = function(self, session_id, blocks, callback, opts)
				calls.prompt_opts[#calls.prompt_opts + 1] = opts
				if overrides.prompt_hangs then
					return self:request("session/prompt", { sessionId = session_id, prompt = blocks }, callback, opts)
				end
				vim.schedule(function()
					callback({}, nil)
				end)
				return 99
			end,
			set_model = function(_, _, callback)
				calls.set_model[#calls.set_model + 1] = true
				vim.schedule(function()
					callback(nil, nil)
				end)
				return nil
			end,
			set_config_option = function(_, sid, config_id, value, callback)
				calls.set_config[#calls.set_config + 1] = { session_id = sid, config_id = config_id, value = value }
				vim.schedule(function()
					callback(overrides.set_config_result or { configOptions = {} }, overrides.set_config_error)
				end)
				return 100 + #calls.set_config
			end,
			subscribe = function() end,
			unsubscribe = function(_, sid)
				calls.unsubscribe[#calls.unsubscribe + 1] = sid
			end,
			cancel = function(_, sid)
				calls.cancel[#calls.cancel + 1] = sid
			end,
			supports_session_close = function(self)
				local capabilities = self.agent_capabilities or {}
				local session_capabilities = capabilities.sessionCapabilities or {}
				return session_capabilities.close ~= nil
			end,
			close_session = function(_, sid)
				if client:supports_session_close() then
					calls.close[#calls.close + 1] = sid
				end
			end,
			forget_request = function(self, id)
				self.callbacks[id] = nil
			end,
		}

		return client, calls
	end

	before_each(function()
		config = require("zxz.core.config")
		config.setup({
			request_timeout_ms = 0,
			complete = {
				prompt_timeout_ms = 50,
			},
		})
		package.loaded["zxz.core.acp_client"] = nil
		acp_client = require("zxz.core.acp_client")
		acp_client._reset_client_factory()
	end)

	after_each(function()
		acp_client._reset_client_factory()
		if acp_client.stop_all_completion_clients then
			acp_client.stop_all_completion_clients()
		end
	end)

	it("close_session skips agents that do not advertise close support", function()
		local sends = {}
		local client = acp_client.new({ command = "fake", name = "fake" })
		client.transport = {
			set_idle_armed = function() end,
			send = function(_, data)
				sends[#sends + 1] = vim.json.decode(data)
			end,
		}
		client.agent_capabilities = { sessionCapabilities = {} }

		local callback_called = false
		client:close_session("sess-1", function(_, err)
			callback_called = err == nil
		end)

		assert.are.equal(0, #sends)
		assert.is_true(vim.wait(500, function()
			return callback_called
		end))
	end)

	it("close_session sends session/close request when advertised", function()
		local sends = {}
		local client = acp_client.new({ command = "fake", name = "fake" })
		client.transport = {
			set_idle_armed = function() end,
			send = function(_, data)
				sends[#sends + 1] = vim.json.decode(data)
			end,
		}
		client.agent_capabilities = { sessionCapabilities = { close = {} } }

		local request_id = client:close_session("sess-1")

		assert.are.equal(1, request_id)
		assert.are.equal("session/close", sends[1].method)
		assert.are.equal(1, sends[1].id)
		assert.are.equal("sess-1", sends[1].params.sessionId)
	end)

	it("finish closes the session after a successful prompt when advertised", function()
		local fake_client, calls = make_fake_client()
		acp_client._set_client_factory(function()
			return fake_client
		end)

		local done_err = "pending"
		local abort = acp_client.stream_completion({ command = "fake" }, {
			prefix = "local x = ",
			suffix = "",
			cwd = "/tmp",
		}, function() end, function(err)
			done_err = err
		end)

		assert.is_true(vim.wait(500, function()
			return done_err ~= "pending"
		end))
		abort()

		assert.is_nil(done_err)
		assert.are.equal("sess-test", calls.close[1])
		assert.are.equal("sess-test", calls.unsubscribe[1])
	end)

	it("finish skips session close when the agent does not advertise support", function()
		local fake_client, calls = make_fake_client({ supports_close = false })
		acp_client._set_client_factory(function()
			return fake_client
		end)

		local done_err = "pending"
		local abort = acp_client.stream_completion({ command = "fake" }, {
			prefix = "local x = ",
			suffix = "",
			cwd = "/tmp",
		}, function() end, function(err)
			done_err = err
		end)

		assert.is_true(vim.wait(500, function()
			return done_err ~= "pending"
		end))
		abort()

		assert.is_nil(done_err)
		assert.are.equal(0, #calls.close)
		assert.are.equal("sess-test", calls.unsubscribe[1])
	end)

	it("abort cancels and closes the session when advertised", function()
		local fake_client, calls = make_fake_client({ prompt_hangs = true })
		acp_client._set_client_factory(function()
			return fake_client
		end)

		local abort = acp_client.stream_completion({ command = "fake" }, {
			prefix = "local x = ",
			suffix = "",
			cwd = "/tmp",
		}, function() end, function() end)

		assert.is_true(vim.wait(500, function()
			return #calls.prompt_opts > 0
		end))

		abort()

		assert.are.equal("sess-test", calls.cancel[1])
		assert.are.equal("sess-test", calls.close[1])
		assert.are.equal("sess-test", calls.unsubscribe[1])
	end)

	it("sets the advertised model config option by value before prompting", function()
		local fake_client, calls = make_fake_client({
			new_session_result = {
				sessionId = "sess-test",
				configOptions = {
					{
						id = "model",
						name = "Model",
						category = "model",
						type = "select",
						currentValue = "fast",
						options = {
							{ value = "fast", name = "Fast" },
							{ value = "sonnet", name = "Claude Sonnet" },
						},
					},
				},
			},
		})
		acp_client._set_client_factory(function()
			return fake_client
		end)

		local done_err = "pending"
		local abort = acp_client.stream_completion({ command = "fake" }, {
			prefix = "local x = ",
			suffix = "",
			cwd = "/tmp",
			model = "Claude Sonnet",
		}, function() end, function(err)
			done_err = err
		end)

		assert.is_true(vim.wait(500, function()
			return done_err ~= "pending"
		end))
		abort()

		assert.is_nil(done_err)
		assert.are.equal(0, #calls.set_model)
		assert.are.same({ session_id = "sess-test", config_id = "model", value = "sonnet" }, calls.set_config[1])
		assert.are.equal(1, #calls.prompt_opts)
	end)

	it("maps Cursor fast model names to advertised config values", function()
		local fake_client, calls = make_fake_client({
			new_session_result = {
				sessionId = "sess-test",
				configOptions = {
					{
						id = "model",
						name = "Model",
						category = "model",
						type = "select",
						currentValue = "default[]",
						options = {
							{ value = "default[]", name = "Auto" },
							{ value = "composer-2.5[fast=true]", name = "composer-2.5" },
						},
					},
				},
			},
		})
		acp_client._set_client_factory(function()
			return fake_client
		end)

		local done_err = "pending"
		local abort = acp_client.stream_completion({ command = "fake" }, {
			prefix = "local x = ",
			suffix = "",
			cwd = "/tmp",
			model = "composer-2.5-fast",
		}, function() end, function(err)
			done_err = err
		end)

		assert.is_true(vim.wait(500, function()
			return done_err ~= "pending"
		end))
		abort()

		assert.is_nil(done_err)
		assert.are.same(
			{ session_id = "sess-test", config_id = "model", value = "composer-2.5[fast=true]" },
			calls.set_config[1]
		)
		assert.are.equal(1, #calls.prompt_opts)
	end)

	it("fails before prompting when the requested model is not advertised", function()
		local fake_client, calls = make_fake_client({
			new_session_result = {
				sessionId = "sess-test",
				configOptions = {
					{
						id = "model",
						name = "Model",
						category = "model",
						type = "select",
						currentValue = "fast",
						options = {
							{ value = "fast", name = "Fast" },
						},
					},
				},
			},
		})
		acp_client._set_client_factory(function()
			return fake_client
		end)

		local done_err = "pending"
		acp_client.stream_completion({ command = "fake" }, {
			prefix = "local x = ",
			suffix = "",
			cwd = "/tmp",
			model = "missing-model",
		}, function() end, function(err)
			done_err = err
		end)

		assert.is_true(vim.wait(500, function()
			return done_err ~= "pending"
		end))

		assert.are.equal(-32602, done_err.code)
		assert.are.equal(0, #calls.set_model)
		assert.are.equal(0, #calls.set_config)
		assert.are.equal(0, #calls.prompt_opts)
		assert.are.same({ "fast" }, done_err.data.availableModels)
	end)

	it("passes prompt_timeout_ms to session/prompt requests", function()
		local fake_client, calls = make_fake_client()
		acp_client._set_client_factory(function()
			return fake_client
		end)

		local abort = acp_client.stream_completion({ command = "fake" }, {
			prefix = "local x = ",
			suffix = "",
			cwd = "/tmp",
		}, function() end, function() end)

		assert.is_true(vim.wait(500, function()
			return #calls.prompt_opts > 0
		end))
		abort()

		assert.are.same({ timeout_ms = 50 }, calls.prompt_opts[1])
	end)

	it("times out hung session/prompt requests", function()
		config.setup({
			complete = {
				prompt_timeout_ms = 50,
			},
		})

		local client = acp_client.new({ command = "fake-timeout", name = "fake" })
		client.transport = { set_idle_armed = function() end, send = function() end }

		local timed_out = false
		client:request("session/prompt", { sessionId = "sess-timeout", prompt = {} }, function(_, err)
			timed_out = err ~= nil
		end, { timeout_ms = 50 })

		assert.is_true(vim.wait(500, function()
			return timed_out
		end))
	end)
end)
