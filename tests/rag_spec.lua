describe("completion rag", function()
	local rag

	before_each(function()
		package.loaded["zxz.complete.rag"] = nil
		rag = require("zxz.complete.rag")
		rag.clear()
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
end)
