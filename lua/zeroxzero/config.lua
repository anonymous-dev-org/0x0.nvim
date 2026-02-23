local M = {}

---@class zeroxzero.Config
---@field cmd string
---@field args string[]
---@field port number 0 = random
---@field hostname string
---@field auto_start boolean
---@field terminal zeroxzero.TerminalConfig
---@field keymaps zeroxzero.KeymapConfig
---@field auth? {username: string, password: string}

---@class zeroxzero.TerminalConfig
---@field position "vsplit"|"split"|"float"|"tab"
---@field size number
---@field float_opts? {width: number, height: number, border: string}

---@class zeroxzero.KeymapConfig
---@field toggle string
---@field ask string
---@field add_file string
---@field add_selection string
---@field session_list string
---@field session_new string
---@field session_interrupt string
---@field model_list string
---@field command_picker string
---@field agent_picker string

---@type zeroxzero.Config
M.defaults = {
  cmd = "0x0",
  args = {},
  port = 0,
  hostname = "127.0.0.1",
  auto_start = true,
  terminal = {
    position = "vsplit",
    size = 80,
    float_opts = {
      width = 0.8,
      height = 0.8,
      border = "rounded",
    },
  },
  keymaps = {
    toggle = "<leader>0",
    ask = "<leader>0a",
    add_file = "<leader>0f",
    add_selection = "<leader>0s",
    session_list = "<leader>0l",
    session_new = "<leader>0n",
    session_interrupt = "<leader>0i",
    model_list = "<leader>0m",
    command_picker = "<leader>0c",
    agent_picker = "<leader>0g",
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
