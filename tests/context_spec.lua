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

  it("uses an untitled filepath for unnamed buffers", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "lua"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = " })
    vim.api.nvim_win_set_cursor(0, { 1, #"local x = " })

    local ctx = context.gather()

    assert.are.equal("untitled.lua", ctx.filepath)
  end)
end)
