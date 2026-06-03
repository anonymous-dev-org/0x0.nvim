describe("model catalog", function()
	local model_catalog
	local completion_client

	before_each(function()
		require("zxz.core.config").setup({
			complete = {
				gateway = { api_key = "test-key" },
				models = { "mistral/codestral" },
			},
		})
		package.loaded["zxz.core.model_catalog"] = nil
		package.loaded["zxz.core.completion_client"] = nil
		model_catalog = require("zxz.core.model_catalog")
		completion_client = require("zxz.core.completion_client")
		model_catalog._reset()
	end)

	it("stores gateway language models for selection", function()
		local original = completion_client.list_models
		completion_client.list_models = function(on_done)
			on_done({
				"anthropic/claude-sonnet-4.6",
				"anthropic/claude-sonnet-4.6-thinking",
				"alibaba/qwen3-coder",
				"mistral/codestral",
			})
		end

		local done = false
		model_catalog.refresh(function(models)
			assert.are.same({
				"mistral/codestral",
				"alibaba/qwen3-coder",
				"anthropic/claude-sonnet-4.6",
			}, models)
			done = true
		end)

		assert.is_true(vim.wait(500, function()
			return done
		end))
		assert.are.same({
			"mistral/codestral",
			"alibaba/qwen3-coder",
			"anthropic/claude-sonnet-4.6",
		}, model_catalog.get_models())

		completion_client.list_models = original
	end)
end)
