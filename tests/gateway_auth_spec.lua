describe("gateway auth", function()
	local gateway_auth
	local paths
	local original_gateway_env
	local original_custom_env

	before_each(function()
		original_gateway_env = vim.env.AI_GATEWAY_API_KEY
		original_custom_env = vim.env.ZXZ_TEST_GATEWAY_KEY
		vim.env.AI_GATEWAY_API_KEY = nil
		vim.env.ZXZ_TEST_GATEWAY_KEY = nil
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

	after_each(function()
		vim.env.AI_GATEWAY_API_KEY = original_gateway_env
		vim.env.ZXZ_TEST_GATEWAY_KEY = original_custom_env
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

	it("promotes saved keys to global environment for future use", function()
		gateway_auth.set_api_key("stored-key")
		assert.are.equal("stored-key", vim.env.AI_GATEWAY_API_KEY)

		require("zxz.core.config").setup({
			complete = {
				gateway = {},
			},
		})
		vim.env.AI_GATEWAY_API_KEY = nil

		assert.are.equal("stored-key", gateway_auth.get_api_key())
		assert.are.equal("stored-key", vim.env.AI_GATEWAY_API_KEY)
		assert.are.equal("stored-key", require("zxz.core.config").current.complete.gateway.api_key)
	end)

	it("sets custom and canonical env names when saving a key", function()
		require("zxz.core.config").setup({
			complete = {
				gateway = { api_key_env = "ZXZ_TEST_GATEWAY_KEY" },
			},
		})

		gateway_auth.set_api_key("global-key")

		assert.are.equal("global-key", vim.env.ZXZ_TEST_GATEWAY_KEY)
		assert.are.equal("global-key", vim.env.AI_GATEWAY_API_KEY)
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
