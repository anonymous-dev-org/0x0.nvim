local M = {}

---@param opts? table
function M.setup(opts)
  local config = require("zeroxzero.config")
  config.setup(opts)

  local cfg = config.current
  local km = cfg.keymaps

  -- Statusline setup
  require("zeroxzero.ui.statusline")._setup()

  -- Keymaps

  if km.send and km.send ~= "" then
    vim.keymap.set("n", km.send, function()
      M.send()
    end, { desc = "0x0: Send file to TUI" })
    vim.keymap.set("v", km.send, function()
      M.send_visual()
    end, { desc = "0x0: Send selection to TUI" })
  end

  if km.switch_session and km.switch_session ~= "" then
    vim.keymap.set("n", km.switch_session, function()
      M.switch_session()
    end, { desc = "0x0: Switch pinned session" })
  end

  -- Autocommands
  local group = vim.api.nvim_create_augroup("zeroxzero", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("zeroxzero.server").stop()
    end,
  })
end

-- TUI bridge

function M.send()
  require("zeroxzero.tui").send_file()
end

function M.send_visual()
  require("zeroxzero.tui").send_selection()
end

function M.switch_session()
  require("zeroxzero.tui").switch_session()
end

-- Statusline

---@return string
function M.statusline()
  return require("zeroxzero.ui.statusline").get()
end

return M
