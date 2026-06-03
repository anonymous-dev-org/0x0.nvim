describe("completion rag", function()
	local rag

	before_each(function()
		package.loaded["zxz.complete.rag"] = nil
		rag = require("zxz.complete.rag")
		rag.clear()
		require("zxz.core.completion_client").rag_record = function() end
	end)

	it("stores recent accepted completions in the session hot ring", function()
		rag.record("local a = ", "", "lua", "1")
		rag.record("local b = ", "", "lua", "2")

		local hit = rag.lookup_session({
			prefix = "local b = ",
			suffix = "",
			language = "lua",
		})

		assert.are.equal("2", hit)
	end)

	it("keeps session entries bounded", function()
		local config = require("zxz.core.config")
		config.setup({
			complete = {
				rag = {
					enabled = true,
					session_entries = 2,
					max_field_chars = 5,
				},
			},
		})
		package.loaded["zxz.complete.rag"] = nil
		rag = require("zxz.complete.rag")

		rag.record("0123456789", "suffix-long", "lua", "completion-long")
		local hash = rag.context_hash("0123456789", "suffix-long", "lua")
		local stored = rag.lookup_session({
			prefix = "0123456789",
			suffix = "suffix-long",
			language = "lua",
		})

		assert.are.equal("...ng", stored)

		rag.record("a", "", "lua", "1")
		rag.record("b", "", "lua", "2")
		rag.record("c", "", "lua", "3")

		assert.is_nil(rag.lookup_session({ prefix = "a", suffix = "", language = "lua" }))
		assert.are.equal("3", rag.lookup_session({ prefix = "c", suffix = "", language = "lua" }))
		assert.is_not_nil(hash)
	end)

	it("returns recent accepted completions for prompt history", function()
		local config = require("zxz.core.config")
		config.setup({
			complete = {
				rag = {
					enabled = true,
					session_entries = 5,
					recent_examples = 2,
				},
			},
		})
		package.loaded["zxz.complete.rag"] = nil
		rag = require("zxz.complete.rag")
		require("zxz.core.completion_client").rag_record = function() end

		rag.record("local a = ", "", "lua", "1")
		rag.record("local b = ", "", "lua", "2")
		rag.record("const c = ", "", "javascript", "3")

		local examples = rag.recent_examples({
			prefix = "local z = ",
			suffix = "",
			language = "lua",
		})

		assert.are.equal(2, #examples)
		assert.are.equal("2", examples[1].completion)
		assert.are.equal("1", examples[2].completion)
		assert.are.equal("recent", examples[1].kind)
	end)
end)
