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
			stop = 0,
			subscribe = {},
			unsubscribe = {},
			prompt_blocks = {},
			prompt_opts = {},
			prompt_session_ids = {},
			new_session = 0,
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
					calls.new_session = calls.new_session + 1
					local result = overrides.new_session_result or { sessionId = "sess-test", configOptions = {} }
					if type(overrides.new_session_results) == "table" then
						result = overrides.new_session_results[calls.new_session] or result
					end
					vim.schedule(function()
						callback(result, nil)
					end)
				end
				return id
			end,
			new_session = function(self, cwd, callback)
				return self:request("session/new", { cwd = cwd }, callback)
			end,
			prompt = function(self, session_id, blocks, callback, opts)
				calls.prompt_session_ids[#calls.prompt_session_ids + 1] = session_id
				calls.prompt_blocks[#calls.prompt_blocks + 1] = blocks
				calls.prompt_opts[#calls.prompt_opts + 1] = opts
				if overrides.prompt_hangs then
					return self:request("session/prompt", { sessionId = session_id, prompt = blocks }, callback, opts)
				end
				if overrides.prompt_error then
					vim.schedule(function()
						callback(nil, overrides.prompt_error)
					end)
					return 99
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
			subscribe = function(_, sid, handlers)
				calls.subscribe[#calls.subscribe + 1] = { session_id = sid, handlers = handlers }
			end,
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
			stop = function(self)
				calls.stop = calls.stop + 1
				self.state = "disconnected"
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
				session_reuse = { enabled = false },
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
				return true
			end,
		}
		client.agent_capabilities = { sessionCapabilities = { close = {} } }
		client.state = "ready"

		local request_id = client:close_session("sess-1")

		assert.are.equal(1, request_id)
		assert.are.equal("session/close", sends[1].method)
		assert.are.equal(1, sends[1].id)
		assert.are.equal("sess-1", sends[1].params.sessionId)
	end)

	it("close_session skips disconnected clients", function()
		local sends = {}
		local client = acp_client.new({ command = "fake", name = "fake" })
		client.transport = {
			set_idle_armed = function() end,
			send = function(_, data)
				sends[#sends + 1] = vim.json.decode(data)
				return true
			end,
		}
		client.agent_capabilities = { sessionCapabilities = { close = {} } }
		client.state = "disconnected"

		local callback_called = false
		client:close_session("sess-1", function(_, err)
			callback_called = err == nil
		end)

		assert.are.equal(0, #sends)
		assert.is_true(vim.wait(500, function()
			return callback_called
		end))
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

	it("sets advertised effort, temperature, and max token options before prompting", function()
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
					{
						id = "thought",
						name = "Thought Level",
						category = "thought_level",
						type = "select",
						currentValue = "medium",
						options = {
							{ value = "medium", name = "Medium" },
							{ value = "none", name = "None" },
						},
					},
					{
						id = "temperature",
						name = "Temperature",
						type = "select",
						currentValue = "1",
						options = {
							{ value = "1", name = "One" },
							{ value = "0", name = "Zero" },
						},
					},
					{
						id = "max_output_tokens",
						name = "Max output tokens",
						type = "select",
						currentValue = "512",
						options = {
							{ value = "64", name = "64" },
							{ value = "128", name = "128" },
							{ value = "256", name = "256" },
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
		assert.are.same({ session_id = "sess-test", config_id = "model", value = "sonnet" }, calls.set_config[1])
		assert.are.same({ session_id = "sess-test", config_id = "thought", value = "none" }, calls.set_config[2])
		assert.are.same({ session_id = "sess-test", config_id = "temperature", value = "0" }, calls.set_config[3])
		assert.are.same(
			{ session_id = "sess-test", config_id = "max_output_tokens", value = "128" },
			calls.set_config[4]
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

	it("prompts for raw insert-only completion with focused scope", function()
		local fake_client, calls = make_fake_client()
		acp_client._set_client_factory(function()
			return fake_client
		end)

		local done_err = "pending"
		local abort = acp_client.stream_completion({ command = "fake", name = "Fake ACP" }, {
			prefix = "local value = ",
			suffix = "\nprint(value)",
			cwd = "/tmp",
			filepath = "/tmp/example.lua",
			language = "lua",
			cursor = { line = 2, column = 14 },
			scope = {
				type = "function_declaration",
				start_line = 1,
				end_line = 4,
				text = "local function example()\n  local value = \n  print(value)\nend",
			},
		}, function() end, function(err)
			done_err = err
		end)

		assert.is_true(vim.wait(500, function()
			return done_err ~= "pending"
		end))
		abort()

		assert.is_nil(done_err)
		local prompt = calls.prompt_blocks[1][1].text
		assert.is_truthy(prompt:find("Return only the lua text to insert after this cursor.", 1, true))
		assert.is_truthy(prompt:find("No tools. No search. No explanation. No markdown.", 1, true))
		assert.is_truthy(prompt:find("Relevant surrounding code", 1, true))
		assert.is_truthy(prompt:find("function_declaration", 1, true))
		assert.is_truthy(prompt:find("Code before cursor: local value = ", 1, true))
		assert.is_truthy(prompt:find("Code after cursor: \nprint(value)", 1, true))
		assert.is_truthy(prompt:find("Text to insert:", 1, true))
	end)

	it("does not install permission handlers for completion sessions", function()
		local fake_client, calls = make_fake_client({ prompt_hangs = true })
		acp_client._set_client_factory(function()
			return fake_client
		end)

		local abort = acp_client.stream_completion({ command = "fake" }, {
			prefix = "local value = ",
			suffix = "",
			cwd = "/tmp",
		}, function() end, function() end)

		assert.is_true(vim.wait(500, function()
			return #calls.subscribe > 0
		end))
		abort()

		assert.are.equal("sess-test", calls.subscribe[1].session_id)
		assert.is_nil(calls.subscribe[1].handlers.on_request_permission)
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

	it("uses a bounded default timeout for session/prompt requests", function()
		config.setup({})
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

		assert.are.same({ timeout_ms = 10000 }, calls.prompt_opts[1])
	end)

	it("reuses a completion session within the configured budget", function()
		config.setup({
			request_timeout_ms = 0,
			complete = {
				prompt_timeout_ms = 50,
				session_reuse = {
					enabled = true,
					max_prompts = 3,
					max_age_ms = 30000,
					max_idle_ms = 30000,
				},
			},
		})
		local fake_client, calls = make_fake_client({
			new_session_results = {
				{ sessionId = "sess-1", configOptions = {} },
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
			model = "fast",
		}, function() end, function(err)
			done_err = err
		end)
		assert.is_true(vim.wait(500, function()
			return done_err ~= "pending"
		end))
		abort()

		done_err = "pending"
		abort = acp_client.stream_completion({ command = "fake" }, {
			prefix = "local y = ",
			suffix = "",
			cwd = "/tmp",
			model = "fast",
		}, function() end, function(err)
			done_err = err
		end)
		assert.is_true(vim.wait(500, function()
			return done_err ~= "pending"
		end))
		abort()

		assert.is_nil(done_err)
		assert.are.equal(1, calls.new_session)
		assert.are.same({ "sess-1", "sess-1" }, calls.prompt_session_ids)
		assert.are.equal(0, #calls.close)
	end)

	it("rotates cached completion sessions after the prompt budget", function()
		config.setup({
			request_timeout_ms = 0,
			complete = {
				prompt_timeout_ms = 50,
				session_reuse = {
					enabled = true,
					max_prompts = 1,
					max_age_ms = 30000,
					max_idle_ms = 30000,
				},
			},
		})
		local fake_client, calls = make_fake_client({
			new_session_results = {
				{ sessionId = "sess-1", configOptions = {} },
				{ sessionId = "sess-2", configOptions = {} },
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
			model = "fast",
		}, function() end, function(err)
			done_err = err
		end)
		assert.is_true(vim.wait(500, function()
			return done_err ~= "pending"
		end))
		abort()

		done_err = "pending"
		abort = acp_client.stream_completion({ command = "fake" }, {
			prefix = "local y = ",
			suffix = "",
			cwd = "/tmp",
			model = "fast",
		}, function() end, function(err)
			done_err = err
		end)
		assert.is_true(vim.wait(500, function()
			return done_err ~= "pending"
		end))
		abort()

		assert.is_nil(done_err)
		assert.are.equal(2, calls.new_session)
		assert.are.same({ "sess-1", "sess-2" }, calls.prompt_session_ids)
		assert.are.equal("sess-1", calls.close[1])
	end)

	it("uses the longer default session reuse budget", function()
		config.setup({
			request_timeout_ms = 0,
			complete = {
				prompt_timeout_ms = 50,
			},
		})
		local fake_client, calls = make_fake_client({
			new_session_results = {
				{ sessionId = "sess-1", configOptions = {} },
				{ sessionId = "sess-2", configOptions = {} },
			},
		})
		acp_client._set_client_factory(function()
			return fake_client
		end)

		for i = 1, 13 do
			local done_err = "pending"
			local abort = acp_client.stream_completion({ command = "fake" }, {
				prefix = "local value" .. tostring(i) .. " = ",
				suffix = "",
				cwd = "/tmp",
				model = "fast",
			}, function() end, function(err)
				done_err = err
			end)
			assert.is_true(vim.wait(500, function()
				return done_err ~= "pending"
			end))
			abort()
			assert.is_nil(done_err)
		end

		assert.are.equal(2, calls.new_session)
		for i = 1, 12 do
			assert.are.equal("sess-1", calls.prompt_session_ids[i])
		end
		assert.are.equal("sess-2", calls.prompt_session_ids[13])
		assert.are.equal("sess-1", calls.close[1])
	end)

	it("does not discard the provider client when a cached session is still cancelling", function()
		config.setup({
			request_timeout_ms = 0,
			complete = {
				prompt_timeout_ms = 50,
				session_reuse = {
					enabled = true,
					max_prompts = 3,
					max_age_ms = 30000,
					max_idle_ms = 30000,
				},
			},
		})
		local fake_client, calls = make_fake_client({
			prompt_hangs = true,
			supports_close = false,
			new_session_results = {
				{ sessionId = "sess-1", configOptions = {} },
				{ sessionId = "sess-2", configOptions = {} },
			},
		})
		acp_client._set_client_factory(function()
			return fake_client
		end)

		local abort = acp_client.stream_completion({ command = "fake" }, {
			prefix = "local x = ",
			suffix = "",
			cwd = "/tmp",
			model = "fast",
		}, function() end, function() end)
		assert.is_true(vim.wait(500, function()
			return #calls.prompt_opts == 1
		end))
		abort()

		abort = acp_client.stream_completion({ command = "fake" }, {
			prefix = "local y = ",
			suffix = "",
			cwd = "/tmp",
			model = "fast",
		}, function() end, function() end)
		assert.is_true(vim.wait(500, function()
			return #calls.prompt_opts == 2
		end))
		abort()

		assert.are.equal(2, calls.new_session)
		assert.are.same({ "sess-1", "sess-2" }, calls.prompt_session_ids)
		assert.are.equal(0, calls.stop)
	end)

	it("recycles the singleton client after a prompt timeout", function()
		local timeout_err = {
			code = -32001,
			message = "request timed out",
			data = { method = "session/prompt" },
		}
		local first_client, first_calls = make_fake_client({ prompt_error = timeout_err })
		local second_client, second_calls = make_fake_client()
		local factory_calls = 0
		acp_client._set_client_factory(function()
			factory_calls = factory_calls + 1
			if factory_calls == 1 then
				return first_client
			end
			return second_client
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

		assert.are.same(timeout_err, done_err)
		assert.are.equal(1, first_calls.stop)

		done_err = "pending"
		abort = acp_client.stream_completion({ command = "fake" }, {
			prefix = "local y = ",
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
		assert.are.equal(2, factory_calls)
		assert.are.equal(1, #second_calls.prompt_opts)
	end)

	it("fails stream completion immediately when session/prompt cannot be sent", function()
		config.setup({
			request_timeout_ms = 0,
			complete = {
				prompt_timeout_ms = 5000,
			},
		})

		local sent_methods = {}
		local unsubscribed
		local stopped = 0
		local fake_client = acp_client.new({ command = "fake-disconnected", name = "fake" })
		fake_client.state = "ready"
		fake_client.agent_capabilities = { sessionCapabilities = { close = {} } }
		fake_client.transport = {
			set_idle_armed = function() end,
			send = function(_, data)
				local message = vim.json.decode(data)
				sent_methods[#sent_methods + 1] = message.method
				return message.method ~= "session/prompt"
			end,
			stop = function()
				stopped = stopped + 1
				fake_client.state = "disconnected"
			end,
		}
		fake_client.start = function(self, on_ready)
			vim.schedule(function()
				on_ready(self)
			end)
		end
		fake_client.new_session = function(_, _, callback)
			vim.schedule(function()
				callback({ sessionId = "sess-dead", configOptions = {} }, nil)
			end)
			return 1
		end
		fake_client.unsubscribe = function(_, sid)
			unsubscribed = sid
		end

		acp_client._set_client_factory(function()
			return fake_client
		end)

		local done_err = "pending"
		local started = vim.uv.hrtime()
		local abort = acp_client.stream_completion({ command = "fake-disconnected" }, {
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

		local elapsed_ms = math.floor((vim.uv.hrtime() - started) / 1000000)
		assert.is_true(elapsed_ms < 1000)
		assert.are.equal(-32000, done_err.code)
		assert.are.equal("session/prompt", done_err.data.method)
		assert.are.same({ "session/prompt" }, sent_methods)
		assert.are.equal("sess-dead", unsubscribed)
		assert.are.equal(1, stopped)
	end)

	it("times out hung session/prompt requests", function()
		config.setup({
			complete = {
				prompt_timeout_ms = 50,
			},
		})

		local client = acp_client.new({ command = "fake-timeout", name = "fake" })
		client.state = "ready"
		client.transport = {
			set_idle_armed = function() end,
			send = function()
				return true
			end,
		}

		local timed_out = false
		client:request("session/prompt", { sessionId = "sess-timeout", prompt = {} }, function(_, err)
			timed_out = err ~= nil
		end, { timeout_ms = 50 })

		assert.is_true(vim.wait(500, function()
			return timed_out
		end))
	end)

	it("fails immediately when a request cannot be sent", function()
		local client = acp_client.new({ command = "fake-disconnected", name = "fake" })
		local idle_armed = false
		client.state = "disconnected"
		client.transport = {
			set_idle_armed = function(_, armed)
				idle_armed = armed
			end,
			send = function()
				return false
			end,
		}

		local err_result
		local calls = 0
		local request_id = client:request("session/prompt", { sessionId = "sess-dead", prompt = {} }, function(_, err)
			calls = calls + 1
			err_result = err
		end, { timeout_ms = 50 })

		assert.are.equal(1, request_id)
		assert.is_nil(client.callbacks[request_id])
		assert.is_false(idle_armed)
		assert.is_true(vim.wait(500, function()
			return err_result ~= nil
		end))
		assert.are.equal(1, calls)
		assert.are.equal(-32000, err_result.code)
		assert.are.equal("session/prompt", err_result.data.method)
	end)
end)
