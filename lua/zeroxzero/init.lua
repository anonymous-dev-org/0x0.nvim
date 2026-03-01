local M = {}

---@param opts? table
function M.setup(opts)
  local config = require("zeroxzero.config")
  config.setup(opts)

  local cfg = config.current
  local km = cfg.keymaps

  -- Statusline setup
  require("zeroxzero.ui.statusline")._setup()

  -- Highlights
  require("zeroxzero.render").setup_highlights()
  vim.api.nvim_set_hl(0, "ZeroInlineWorking", { link = "DiffChange", default = true })

  -- Keymaps
  if km.toggle and km.toggle ~= "" then
    vim.keymap.set("n", km.toggle, function()
      M.toggle()
    end, { desc = "0x0: Toggle chat" })
  end

  if km.ask and km.ask ~= "" then
    vim.keymap.set("n", km.ask, function()
      M.ask()
    end, { desc = "0x0: Ask" })
    vim.keymap.set("v", km.ask, function()
      M.ask_with_selection()
    end, { desc = "0x0: Ask with selection" })
  end

  if km.add_file and km.add_file ~= "" then
    vim.keymap.set("n", km.add_file, function()
      M.add_file()
    end, { desc = "0x0: Add file to context" })
  end

  if km.add_selection and km.add_selection ~= "" then
    vim.keymap.set("v", km.add_selection, function()
      M.add_selection()
    end, { desc = "0x0: Add selection to context" })
  end

  if km.session_list and km.session_list ~= "" then
    vim.keymap.set("n", km.session_list, function()
      M.session_list()
    end, { desc = "0x0: List sessions" })
  end

  if km.session_new and km.session_new ~= "" then
    vim.keymap.set("n", km.session_new, function()
      M.session_new()
    end, { desc = "0x0: New session" })
  end

  if km.session_interrupt and km.session_interrupt ~= "" then
    vim.keymap.set("n", km.session_interrupt, function()
      M.session_interrupt()
    end, { desc = "0x0: Interrupt session" })
  end

  if km.model_list and km.model_list ~= "" then
    vim.keymap.set("n", km.model_list, function()
      M.model_list()
    end, { desc = "0x0: List models" })
  end

  if km.command_picker and km.command_picker ~= "" then
    vim.keymap.set("n", km.command_picker, function()
      M.command_picker()
    end, { desc = "0x0: Command picker" })
    vim.keymap.set("v", km.command_picker, function()
      M.command_picker()
    end, { desc = "0x0: Command picker" })
  end

  if km.agent_picker and km.agent_picker ~= "" then
    vim.keymap.set("n", km.agent_picker, function()
      M.agent_picker()
    end, { desc = "0x0: Agent picker" })
  end

  if km.inline_edit and km.inline_edit ~= "" then
    vim.keymap.set("n", km.inline_edit, function()
      M.inline_edit()
    end, { desc = "0x0: Inline edit" })
    vim.keymap.set("v", km.inline_edit, function()
      M.inline_edit_visual()
    end, { desc = "0x0: Inline edit with selection" })
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

-- Chat window management

function M.open()
  require("zeroxzero.chat").open()
end

function M.toggle()
  require("zeroxzero.chat").toggle()
end

function M.close()
  require("zeroxzero.chat").close()
end

-- Ask (opens prompt, sends to chat)

---@param opts? {default?: string}
function M.ask(opts)
  require("zeroxzero.chat").prompt(opts)
end

function M.ask_with_selection()
  local context = require("zeroxzero.context")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  local ref = context.file_ref()
  local prefix = ref and ("In " .. ref .. " ") or ""
  M.ask({ default = prefix })
end

-- Context injection

function M.add_file()
  local context = require("zeroxzero.context")
  local ref = context.file_ref()
  if not ref then
    vim.notify("0x0: no file open", vim.log.levels.WARN)
    return
  end
  require("zeroxzero.chat").add_context(ref)
end

function M.add_selection()
  local context = require("zeroxzero.context")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  local ref = context.file_ref()
  if not ref then
    vim.notify("0x0: no file open", vim.log.levels.WARN)
    return
  end
  require("zeroxzero.chat").add_context(ref)
end

-- Session management

function M.session_list()
  require("zeroxzero.ui.picker").session_picker()
end

function M.session_new()
  require("zeroxzero.chat").new_session()
end

function M.session_interrupt()
  require("zeroxzero.chat").interrupt()
end

-- Model

function M.model_list()
  require("zeroxzero.ui.picker").model_picker()
end

-- Commands & Agents

function M.command_picker()
  require("zeroxzero.ui.picker").command_picker()
end

function M.agent_picker()
  require("zeroxzero.ui.picker").agent_picker()
end

-- Inline edit

function M.inline_edit()
  require("zeroxzero.inline_edit").edit()
end

function M.inline_edit_visual()
  require("zeroxzero.inline_edit").edit_visual()
end

-- Statusline

---@return string
function M.statusline()
  return require("zeroxzero.ui.statusline").get()
end

return M
