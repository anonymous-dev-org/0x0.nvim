describe("completion server client", function()
	local completion_client
	local transport_factory
	local fake_transport

	local function make_fake_transport()
		local callbacks
		local sent = {}
		local transport = {
			start = function()
				callbacks.on_state("connected")
				vim.schedule(function()
					callbacks.on_message({ id = 1, event = "pong" })
				end)
			end,
			stop = function()
				callbacks.on_state("disconnected")
			end,
			send = function(_, data)
				sent[#sent + 1] = data
				local message = vim.json.decode(data)
				if message.method == "complete" then
					vim.schedule(function()
						callbacks.on_message({ id = message.id, event = "chunk", text = "42" })
						callbacks.on_message({ id = message.id, event = "done" })
					end)
				elseif message.method == "cancel" then
					vim.schedule(function()
						callbacks.on_message({ id = message.id, event = "done" })
					end)
				end
				return true
			end,
			set_idle_armed = function() end,
		}

		transport_factory = function(_, cbs)
			callbacks = cbs
			return transport
		end

		return transport, sent
	end

	before_each(function()
		require("zxz.core.config").setup({
			complete = {
				gateway = { api_key = "test-key" },
				prompt_timeout_ms = 0,
			},
		})
		package.loaded["zxz.core.completion_client"] = nil
		completion_client = require("zxz.core.completion_client")
		completion_client._reset_transport_factory()
		fake_transport, _ = make_fake_transport()
		completion_client._set_transport_factory(transport_factory)
	end)

	after_each(function()
		completion_client._reset_transport_factory()
	end)

	it("streams completion chunks and finishes cleanly", function()
		local chunks = {}
		local done_err = "pending"
		local abort = completion_client.stream_completion(nil, {
			prefix = "local x = ",
			suffix = "",
			model = "mistral/codestral",
		}, function(text)
			chunks[#chunks + 1] = text
		end, function(err)
			done_err = err
		end)

		assert.is_true(vim.wait(500, function()
			return done_err ~= "pending"
		end))
		abort()

		assert.are.same({ "42" }, chunks)
		assert.is_nil(done_err)
	end)

	it("aborts an in-flight completion", function()
		local done_count = 0
		completion_client._set_transport_factory(function(_, callbacks)
			return {
				start = function()
					callbacks.on_state("connected")
					vim.schedule(function()
						callbacks.on_message({ id = 1, event = "pong" })
					end)
				end,
				stop = function() end,
				send = function(_, data)
					local message = vim.json.decode(data)
					if message.method == "complete" then
						vim.defer_fn(function()
							callbacks.on_message({ id = message.id, event = "chunk", text = "slow" })
						end, 200)
					end
					return true
				end,
				set_idle_armed = function() end,
			}
		end)

		local abort = completion_client.stream_completion(nil, {
			prefix = "local x = ",
			suffix = "",
			model = "mistral/codestral",
		}, function() end, function()
			done_count = done_count + 1
		end)

		assert.is_true(vim.wait(500, function()
			return fake_transport ~= nil
		end))
		abort()
		assert.are.equal(0, done_count)
	end)

	it("fails immediately when the gateway key is missing", function()
		require("zxz.core.config").setup({ complete = { gateway = {} } })
		local done_err = "pending"
		completion_client.stream_completion(nil, {
			prefix = "local x = ",
			suffix = "",
			model = "mistral/codestral",
		}, function() end, function(err)
			done_err = err
		end)

		assert.is_true(vim.wait(500, function()
			return done_err ~= "pending"
		end))
		assert.are.equal("AI Gateway API key required", done_err.message)
	end)

	it("recycles the singleton after transport disconnect", function()
		local factory_calls = 0
		completion_client._set_transport_factory(function(_, callbacks)
			factory_calls = factory_calls + 1
			return {
				start = function()
					if factory_calls == 1 then
						callbacks.on_state("error")
						return
					end
					callbacks.on_state("connected")
					vim.schedule(function()
						callbacks.on_message({ id = 1, event = "pong" })
					end)
				end,
				stop = function() end,
				send = function(_, data)
					local message = vim.json.decode(data)
					if message.method == "complete" then
						vim.schedule(function()
							callbacks.on_message({ id = message.id, event = "chunk", text = "42" })
							callbacks.on_message({ id = message.id, event = "done" })
						end)
					end
					return true
				end,
				set_idle_armed = function() end,
			}
		end)

		local first_err = "pending"
		completion_client.stream_completion(nil, {
			prefix = "local x = ",
			suffix = "",
			model = "mistral/codestral",
		}, function() end, function(err)
			first_err = err
		end)
		assert.is_true(vim.wait(500, function()
			return first_err ~= "pending"
		end))
		assert.are.equal("transport error", first_err.message)

		local second_err = "pending"
		completion_client.stream_completion(nil, {
			prefix = "local y = ",
			suffix = "",
			model = "mistral/codestral",
		}, function() end, function(err)
			second_err = err
		end)
		assert.is_true(vim.wait(500, function()
			return second_err ~= "pending"
		end))
		assert.is_nil(second_err)
		assert.are.equal(2, factory_calls)
	end)
end)
