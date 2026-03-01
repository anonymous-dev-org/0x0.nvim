local M = {}

---@class zeroxzero.Config
---@field cmd string server binary name or path
---@field port number server port (0 = auto-detect running server)
---@field hostname string
---@field auto_start boolean start server if not running
---@field chat zeroxzero.ChatConfig
---@field keymaps zeroxzero.KeymapConfig
---@field auth? {username: string, password: string}

---@class zeroxzero.ChatConfig
---@field width number|float fraction of editor width (0-1) or absolute columns
---@field height number|float fraction of editor height (0-1) or absolute rows
---@field border string nvim border style
---@field fold_tools boolean auto-fold tool output blocks
---@field show_thinking boolean show reasoning/thinking blocks

---@class zeroxzero.KeymapConfig
---@field toggle string
---@field context string
---@field session string
---@field interrupt string
---@field model string
---@field inline_edit string

---@type zeroxzero.Config
M.defaults = {
  cmd = "0x0-server",
  port = 4096,
  hostname = "127.0.0.1",
  auto_start = true,
  chat = {
    width = 0.5,
    height = 0.8,
    border = "rounded",
    fold_tools = true,
    show_thinking = false,
  },
  keymaps = {
    toggle = "<leader>0",
    context = "<leader>0f",
    session = "<leader>0s",
    interrupt = "<leader>0i",
    model = "<leader>0m",
    inline_edit = "<leader>0e",
  },
  auth = nil,
}

---@type zeroxzero.Config
M.current = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
