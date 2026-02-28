local api = require("zeroxzero.api")

local M = {}

---Map of session_id → absolute file path for auto-approved inline edit sessions
---@type table<string, string>
local _inline_sessions = {}

---@param session_id string
---@param file_path string absolute path of the file being edited
function M.register_inline_session(session_id, file_path)
  _inline_sessions[session_id] = file_path
end

---@param session_id string
function M.unregister_inline_session(session_id)
  _inline_sessions[session_id] = nil
end

---Handle a permission.asked SSE event
---@param props table {id, sessionID, permission, patterns, metadata, always}
function M.handle(props)
  local id = props.id
  if not id then
    return
  end

  -- Auto-approve writes to the inline edit target file
  local trusted_file = _inline_sessions[props.sessionID]
  if trusted_file then
    local patterns = props.patterns or {}
    for _, pattern in ipairs(patterns) do
      if trusted_file:sub(-#pattern) == pattern then
        api.reply_permission(id, "once", function() end)
        return
      end
    end
  end

  local permission = props.permission or "unknown"
  local patterns = props.patterns or {}
  local pattern_str = #patterns > 0 and table.concat(patterns, ", ") or ""

  local title = "Permission: " .. permission
  if pattern_str ~= "" then
    title = title .. " (" .. pattern_str .. ")"
  end

  vim.ui.select({ "Allow once", "Allow always", "Reject" }, {
    prompt = title,
  }, function(choice)
    if not choice then
      -- Dialog dismissed — reject
      api.reply_permission(id, "reject", function() end)
      return
    end

    local reply_map = {
      ["Allow once"] = "once",
      ["Allow always"] = "always",
      ["Reject"] = "reject",
    }

    local reply = reply_map[choice] or "reject"
    api.reply_permission(id, reply, function(err)
      if err then
        vim.notify("Failed to reply to permission: " .. err, vim.log.levels.ERROR)
      end
    end)
  end)
end

return M
