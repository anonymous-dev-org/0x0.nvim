local api = require("zeroxzero.api")
local process = require("zeroxzero.process")

local M = {}

---Open prompt input and submit to TUI
---@param opts? {prompt?: string, default?: string}
function M.ask(opts)
  opts = opts or {}

  process.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    vim.ui.input({
      prompt = opts.prompt or "0x0> ",
      default = opts.default or "",
    }, function(input)
      if not input or input == "" then
        return
      end

      api.clear_prompt(function()
        api.append_prompt(input, function(append_err)
          if append_err then
            vim.notify("0x0: failed to send prompt: " .. append_err, vim.log.levels.ERROR)
            return
          end
          api.submit_prompt(function(submit_err)
            if submit_err then
              vim.notify("0x0: failed to submit: " .. submit_err, vim.log.levels.ERROR)
            end
          end)
        end)
      end)
    end)
  end)
end

return M
