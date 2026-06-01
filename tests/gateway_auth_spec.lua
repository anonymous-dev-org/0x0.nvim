describe("gateway auth", function()
	local gateway_auth
	local paths

	before_each(function()
		paths = require("zxz.core.paths")
		require("zxz.core.config").setup({
			complete = {
				gateway = {},
			},
		})
		package.loaded["zxz.core.gateway_auth"] = nil
		gateway_auth = require("zxz.core.gateway_auth")
		gateway_auth._reset_prompt_state()
		local key_file = paths.gateway_key_path()
		if vim.fn.filereadable(key_file) == 1 then
			vim.fn.delete(key_file)
		end
	end)

	it("reads configured and persisted keys", function()
		assert.is_false(gateway_auth.configured())

		require("zxz.core.config").setup({
			complete = {
				gateway = { api_key = "session-key" },
			},
		})
		assert.are.equal("session-key", gateway_auth.get_api_key())

		require("zxz.core.config").setup({
			complete = {
				gateway = {},
			},
		})
		gateway_auth.set_api_key("stored-key")
		assert.are.equal("stored-key", gateway_auth.get_api_key())
		assert.is_true(vim.fn.filereadable(paths.gateway_key_path()) == 1)
	end)

	it("prompts for an api key and saves it", function()
		local original_input = vim.ui.input
		local captured
		vim.ui.input = function(opts, on_confirm)
			captured = opts
			on_confirm("vck_test_key")
		end

		local saved
		gateway_auth.prompt(function(ok)
			saved = ok
		end)

		vim.ui.input = original_input

		assert.is_true(saved)
		assert.are.equal("vck_test_key", gateway_auth.get_api_key())
		assert.is_true(captured.secret)
	end)

	it("auto prompt runs only once per session", function()
		local prompt_count = 0
		local original_input = vim.ui.input
		vim.ui.input = function(_, on_confirm)
			prompt_count = prompt_count + 1
			on_confirm("")
		end

		assert.is_false(gateway_auth.ensure_auto())
		assert.is_false(gateway_auth.ensure_auto())
		assert.are.equal(1, prompt_count)

		vim.ui.input = original_input
	end)
end)
