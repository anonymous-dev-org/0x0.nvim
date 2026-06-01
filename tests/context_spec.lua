describe("completion context", function()
	local context

	before_each(function()
		package.loaded["zxz.complete.context"] = nil
		context = require("zxz.complete.context")
	end)

	it("reads bounded prefix lines on large buffers", function()
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		local lines = {}
		for i = 1, 5000 do
			lines[i] = "LINE" .. i
		end
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.api.nvim_win_set_cursor(0, { 4000, #"LINE4000" })

		local ctx = context.gather()

		assert.is_nil(ctx.prefix:find("LINE1\n", 1, true))
		assert.is_not_nil(ctx.prefix:find("LINE3999", 1, true))
	end)

	it("keeps suffix context small for inline prompts", function()
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		local lines = { "local x = " }
		for i = 1, 500 do
			lines[#lines + 1] = "SUFFIX" .. i
		end
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.api.nvim_win_set_cursor(0, { 1, #"local x = " })

		local ctx = context.gather()

		assert.is_not_nil(ctx.suffix:find("SUFFIX80", 1, true))
		assert.is_nil(ctx.suffix:find("SUFFIX200", 1, true))
	end)

	it("uses an untitled filepath for unnamed buffers", function()
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = " })
		vim.api.nvim_win_set_cursor(0, { 1, #"local x = " })

		local ctx = context.gather()

		assert.are.equal("untitled.lua", ctx.filepath)
	end)

	it("collects import lines from the top of the file", function()
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
			'local M = require("mod")',
			"",
			"function foo()",
			"  local x = ",
		})
		vim.api.nvim_win_set_cursor(0, { 4, #"  local x = " })

		local ctx = context.gather()

		assert.is_not_nil(ctx.imports:find('require("mod")', 1, true))
		assert.is_nil(ctx.header)
	end)

	it("includes a bounded file header when cursor is below it", function()
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "python"
		local lines = { '"""Module doc"""', "", "def foo():" }
		for i = 1, 40 do
			lines[#lines + 1] = "    pass"
		end
		lines[#lines + 1] = "    value = "
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.api.nvim_win_set_cursor(0, { #lines, #"    value = " })

		local ctx = context.gather()

		assert.is_nil(ctx.imports)
		assert.is_not_nil(ctx.header:find('"""Module doc"""', 1, true))
	end)

	it("captures current line indentation", function()
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "  local x = " })
		vim.api.nvim_win_set_cursor(0, { 1, #"  local x = " })

		local ctx = context.gather()

		assert.are.equal("  ", ctx.indent)
	end)
end)
