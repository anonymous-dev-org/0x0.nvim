local M = {}

---@type string
M._status = ""

---@type string?
M._session_title = nil

---Update status from SSE events
function M._setup()
  local ok, sse = pcall(require, "zeroxzero.sse")
  if not ok then
    return
  end

  sse.on("server.connected", function()
    M._status = "connected"
  end)

  sse.on("session.updated", function(props)
    if props and props.title then
      M._session_title = props.title
    end
  end)
end

---Get statusline string
---@return string
function M.get()
  local process = require("zeroxzero.process")
  if not process.connected then
    return ""
  end

  local parts = { "0x0" }

  if M._status ~= "" then
    table.insert(parts, M._status)
  end

  if M._session_title then
    table.insert(parts, M._session_title)
  end

  return table.concat(parts, " | ")
end

return M
