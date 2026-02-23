local api = require("zeroxzero.api")

local M = {}

---Handle a permission.asked SSE event
---@param props table {id, sessionID, permission, patterns, metadata, always}
function M.handle(props)
  local id = props.id
  if not id then
    return
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
