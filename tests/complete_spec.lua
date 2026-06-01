describe("inline completion", function()
	local config

	before_each(function()
		config = require("zxz.core.config")
		config.setup({
			complete = {
				cache = { enabled = false },
				gateway = { api_key = "test-key" },
			},
		})
		package.loaded["zxz.complete"] = nil
		package.loaded["zxz.complete.ghost"] = nil
		pcall(function()
			require("zxz.core.model_catalog")._reset()
		end)
		vim.wo.virtualedit = ""
	end)

	it("sanitizes ghost text before rendering and accepting", function()
		local ghost = require("zxz.complete.ghost")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })

		ghost.show(bufnr, 0, 14, "```lua\n42" .. string.char(14) .. "\n```")

		assert.are.equal("42", ghost.get_text())
		assert.is_true(ghost.accept())
		assert.are.equal("local value = 42", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
	end)

	it("renders and accepts multiline ghost text", function()
		local ghost = require("zxz.complete.ghost")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })

		ghost.show(bufnr, 0, 14, "function()\n  return 42\nend")

		assert.are.equal("function()\n  return 42\nend", ghost.get_text())

		local ns = vim.api.nvim_get_namespaces().zxz_complete
		local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
		local has_inline = false
		local has_virtual_lines = false
		for _, mark in ipairs(marks) do
			local details = mark[4] or {}
			if details.virt_text then
				has_inline = true
				assert.are.equal("function()", details.virt_text[1][1])
			end
			if details.virt_lines then
				has_virtual_lines = true
				assert.are.equal("  return 42", details.virt_lines[1][1][1])
				assert.are.equal("end", details.virt_lines[2][1][1])
			end
		end
		assert.is_true(has_inline)
		assert.is_true(has_virtual_lines)

		assert.is_true(ghost.accept())
		assert.are.same(
			{ "local value = function()", "  return 42", "end" },
			vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		)
		assert.are.same({ 3, 2 }, vim.api.nvim_win_get_cursor(0))
	end)

	it("does not render ghost text in the middle of a line", function()
		local ghost = require("zxz.complete.ghost")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = done" })

		ghost.show(bufnr, 0, 8, "name")

		assert.is_nil(ghost.get_text())
		local ns = vim.api.nvim_get_namespaces().zxz_complete
		local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
		assert.are.equal(0, #marks)
	end)

	it("does not request completions for nofile buffers", function()
		local completion_client = require("zxz.core.completion_client")
		local original = completion_client.stream_completion
		local called = false
		completion_client.stream_completion = function()
			called = true
			return function() end
		end

		local complete = require("zxz.complete")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].buftype = "nofile"
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })

		complete._on_text_changed()

		completion_client.stream_completion = original
		assert.is_false(called)
	end)

	it("uses the resolved model and drops repeated prefix text", function()
		local completion_client = require("zxz.core.completion_client")
		local original = completion_client.stream_completion
		local captured
		completion_client.stream_completion = function(_provider, request, on_chunk, on_done)
			captured = { request = request }
			on_chunk((request.prefix or "") .. "42" .. string.char(14))
			on_done()
			return function() end
		end

		local complete = require("zxz.complete")
		local ghost = require("zxz.complete.ghost")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_name(bufnr, "/tmp/complete-test-multiline.lua")
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })
		vim.wo.virtualedit = "onemore"
		vim.api.nvim_win_set_cursor(0, { 1, 14 })
		complete._mode = function()
			return "i"
		end

		complete._request_completion()

		completion_client.stream_completion = original

		assert.is_truthy(captured)
		assert.are.equal("mistral/codestral", captured.request.model)
		assert.are.equal(vim.fn.getcwd(), captured.request.cwd)
		assert.are.equal("42", ghost.get_text())
	end)

	it("routes the selected gateway model", function()
		config.setup({
			complete = {
				cache = { enabled = false },
				gateway = { api_key = "test-key" },
				model = "anthropic/claude-sonnet-4.6",
			},
		})
		package.loaded["zxz.complete"] = nil

		local completion_client = require("zxz.core.completion_client")
		local original = completion_client.stream_completion
		local captured
		completion_client.stream_completion = function(_provider, request, on_chunk, on_done)
			captured = { request = request }
			on_chunk("42")
			on_done()
			return function() end
		end

		local complete = require("zxz.complete")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_name(bufnr, "/tmp/complete-test-gateway-model.lua")
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })
		vim.wo.virtualedit = "onemore"
		vim.api.nvim_win_set_cursor(0, { 1, 14 })
		complete._mode = function()
			return "i"
		end

		complete._request_completion()

		completion_client.stream_completion = original

		assert.is_truthy(captured)
		assert.are.equal("anthropic/claude-sonnet-4.6", captured.request.model)
	end)

	it("filters thinking models from completion choices", function()
		config.setup({
			complete = {
				models = { "composer-2.5-thinking", "gpt-5.5", "o3", "claude-reasoning-test" },
			},
		})

		assert.are.same({ "gpt-5.5" }, config.completion_model_choices())
	end)

	it("does not render thinking preambles as ghost text", function()
		local completion_client = require("zxz.core.completion_client")
		local original = completion_client.stream_completion
		completion_client.stream_completion = function(provider, request, on_chunk, on_done)
			on_chunk("Let me think about this")
			on_done()
			return function() end
		end

		local complete = require("zxz.complete")
		local ghost = require("zxz.complete.ghost")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_name(bufnr, "/tmp/complete-test-thinking-preamble.lua")
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })
		vim.wo.virtualedit = "onemore"
		vim.api.nvim_win_set_cursor(0, { 1, 14 })
		complete._mode = function()
			return "i"
		end

		complete._request_completion()

		completion_client.stream_completion = original

		assert.is_nil(ghost.get_text())
	end)

	it("unwraps tagged completions before rendering", function()
		local completion_client = require("zxz.core.completion_client")
		local original = completion_client.stream_completion
		completion_client.stream_completion = function(provider, request, on_chunk, on_done)
			on_chunk("<completion>\n42\n</completion>")
			on_done()
			return function() end
		end

		local complete = require("zxz.complete")
		local ghost = require("zxz.complete.ghost")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_name(bufnr, "/tmp/complete-test-tagged.lua")
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })
		vim.wo.virtualedit = "onemore"
		vim.api.nvim_win_set_cursor(0, { 1, 14 })
		complete._mode = function()
			return "i"
		end

		complete._request_completion()

		completion_client.stream_completion = original

		assert.are.equal("42", ghost.get_text())
	end)

	it("does not render obvious agent chatter as ghost text", function()
		local completion_client = require("zxz.core.completion_client")
		local original = completion_client.stream_completion
		completion_client.stream_completion = function(provider, request, on_chunk, on_done)
			on_chunk("Checking the repo for context before answering.")
			on_done()
			return function() end
		end

		local complete = require("zxz.complete")
		local ghost = require("zxz.complete.ghost")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_name(bufnr, "/tmp/complete-test-chatter.lua")
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })
		vim.wo.virtualedit = "onemore"
		vim.api.nvim_win_set_cursor(0, { 1, 14 })
		complete._mode = function()
			return "i"
		end

		complete._request_completion()

		completion_client.stream_completion = original

		assert.is_nil(ghost.get_text())
	end)

	it("falls back from thinking model names before requesting", function()
		config.setup({
			complete = {
				cache = { enabled = false },
				gateway = { api_key = "test-key" },
				model = "anthropic/claude-sonnet-4.6-thinking",
				models = { "anthropic/claude-sonnet-4.6-thinking", "anthropic/claude-sonnet-4.6" },
			},
		})
		package.loaded["zxz.complete"] = nil

		local completion_client = require("zxz.core.completion_client")
		local original = completion_client.stream_completion
		local captured
		completion_client.stream_completion = function(_provider, request, on_chunk, on_done)
			captured = { request = request }
			on_chunk("42")
			on_done()
			return function() end
		end

		local complete = require("zxz.complete")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_name(bufnr, "/tmp/complete-test-thinking-fallback.lua")
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })
		vim.wo.virtualedit = "onemore"
		vim.api.nvim_win_set_cursor(0, { 1, 14 })
		complete._mode = function()
			return "i"
		end

		complete._request_completion()

		completion_client.stream_completion = original

		assert.is_truthy(captured)
		assert.are.equal("anthropic/claude-sonnet-4.6", captured.request.model)
	end)

	it("settings exposes only completion toggle and model selection", function()
		local original_select = vim.ui.select
		local captured
		vim.ui.select = function(items)
			captured = items
		end

		local complete = require("zxz.complete")
		complete.settings()

		vim.ui.select = original_select

		assert.are.equal(3, #captured)
		assert.is_truthy(captured[1].label:match("^Enabled:"))
		assert.is_truthy(captured[2].label:match("^API key:"))
		assert.is_truthy(captured[3].label:match("^Model:"))
	end)

	it("model choices expose gateway model ids", function()
		config.setup({
			complete = {
				gateway = { api_key = "test-key" },
				models = {
					"mistral/codestral",
					"anthropic/claude-sonnet-4.6",
					"openai/gpt-5.4-mini",
				},
			},
		})
		local choices = config.completion_model_choices()
		local seen = {}
		for _, choice in ipairs(choices) do
			seen[choice] = true
			assert.is_truthy(choice:match("/"))
		end

		assert.is_true(seen["mistral/codestral"])
		assert.is_true(seen["anthropic/claude-sonnet-4.6"])
		assert.is_true(seen["openai/gpt-5.4-mini"])
	end)

	it("does not request completions in the middle of a line", function()
		local completion_client = require("zxz.core.completion_client")
		local original = completion_client.stream_completion
		local called = false
		completion_client.stream_completion = function()
			called = true
			return function() end
		end

		local complete = require("zxz.complete")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_name(bufnr, "/tmp/complete-test-midline.lua")
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = done" })
		vim.api.nvim_win_set_cursor(0, { 1, 8 })
		complete._mode = function()
			return "i"
		end

		complete._request_completion()

		completion_client.stream_completion = original

		assert.is_false(called)
	end)

	it("keeps multiline streamed completions displayable", function()
		local completion_client = require("zxz.core.completion_client")
		local original = completion_client.stream_completion
		completion_client.stream_completion = function(provider, request, on_chunk, on_done)
			on_chunk((request.prefix or "") .. "function()\n  return 42\nend")
			on_done()
			return function() end
		end

		local complete = require("zxz.complete")
		local ghost = require("zxz.complete.ghost")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_name(bufnr, "/tmp/complete-test.lua")
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })
		vim.wo.virtualedit = "onemore"
		vim.api.nvim_win_set_cursor(0, { 1, 14 })
		complete._mode = function()
			return "i"
		end

		complete._request_completion()

		completion_client.stream_completion = original

		assert.are.equal("function()\n  return 42\nend", ghost.get_text())
	end)

	it("notifies the user when a streamed completion fails", function()
		local completion_client = require("zxz.core.completion_client")
		local original = completion_client.stream_completion
		completion_client.stream_completion = function(provider, request, on_chunk, on_done)
			on_done({ code = -32000, message = "model not supported on this plan" })
			return function() end
		end

		local notifications = {}
		local original_notify = vim.notify
		vim.notify = function(msg, level)
			notifications[#notifications + 1] = { msg = msg, level = level }
		end

		local complete = require("zxz.complete")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_name(bufnr, "/tmp/complete-test-error.lua")
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })
		vim.wo.virtualedit = "onemore"
		vim.api.nvim_win_set_cursor(0, { 1, 14 })
		complete._mode = function()
			return "i"
		end

		complete._request_completion()
		vim.wait(50, function()
			return #notifications > 0
		end)

		completion_client.stream_completion = original
		vim.notify = original_notify

		local saw_error = false
		for _, entry in ipairs(notifications) do
			if
				entry.level == vim.log.levels.WARN
				and entry.msg:match("0x0 completion failed")
				and entry.msg:match("model not supported on this plan")
			then
				saw_error = true
				break
			end
		end
		assert.is_true(saw_error)
	end)

	it("does not abort in-flight completion when TextChangedI leaves the prefix unchanged", function()
		local completion_client = require("zxz.core.completion_client")
		local original = completion_client.stream_completion
		local abort_count = 0
		completion_client.stream_completion = function(_, _, _, _)
			return function()
				abort_count = abort_count + 1
			end
		end

		local complete = require("zxz.complete")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_name(bufnr, "/tmp/complete-test-inflight.lua")
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })
		vim.wo.virtualedit = "onemore"
		vim.api.nvim_win_set_cursor(0, { 1, 14 })
		complete._mode = function()
			return "i"
		end

		complete._request_completion()
		assert.are.equal(0, abort_count)

		complete._on_text_changed()

		assert.are.equal(0, abort_count)

		completion_client.stream_completion = original
	end)

	it("aborts in-flight completion when the typed prefix changes", function()
		local completion_client = require("zxz.core.completion_client")
		local original = completion_client.stream_completion
		local abort_count = 0
		completion_client.stream_completion = function(_, _, _, _)
			return function()
				abort_count = abort_count + 1
			end
		end

		local complete = require("zxz.complete")
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_name(bufnr, "/tmp/complete-test-inflight-changed.lua")
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })
		vim.wo.virtualedit = "onemore"
		vim.api.nvim_win_set_cursor(0, { 1, 14 })
		complete._mode = function()
			return "i"
		end

		complete._request_completion()
		complete._cancel()

		assert.are.equal(1, abort_count)

		completion_client.stream_completion = original
	end)
end)
