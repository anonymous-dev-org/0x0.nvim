local M = {}

---Map toast level to vim.log.levels
local level_map = {
  info = vim.log.levels.INFO,
  success = vim.log.levels.INFO,
  warning = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

---Handle a toast.show event
---@param props table {message: string, level?: string, title?: string}
function M.handle(props)
  local message = props.message or props.title or ""
  if message == "" then
    return
  end

  local level = level_map[props.level] or vim.log.levels.INFO
  vim.notify(message, level, { title = "0x0" })
end

return M
