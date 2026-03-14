local api = require("zeroxzero.api")

local M = {}

---Format a relative time string from a timestamp (ms)
---@param timestamp number milliseconds since epoch
---@return string
local function relative_time(timestamp)
  local diff = (os.time() * 1000 - timestamp) / 1000
  if diff < 60 then
    return "just now"
  end
  local minutes = math.floor(diff / 60)
  if minutes < 60 then
    return minutes .. "m ago"
  end
  local hours = math.floor(minutes / 60)
  if hours < 24 then
    return hours .. "h ago"
  end
  local days = math.floor(hours / 24)
  return days .. "d ago"
end

---Show a session picker filtered by cwd, with a "New session" option.
---@param callback fun(session_id: string, title: string)
function M.pick_session(callback)
  local cwd = vim.fn.getcwd()
  local encoded_cwd = cwd:gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)

  api.get("/session?directory=" .. encoded_cwd, function(err, response)
    if err then
      vim.notify("0x0: failed to list sessions: " .. err, vim.log.levels.ERROR)
      return
    end

    if not response or response.status ~= 200 then
      vim.notify("0x0: unexpected response listing sessions", vim.log.levels.ERROR)
      return
    end

    local sessions = response.body or {}

    ---@type {label: string, session_id: string?, title: string}[]
    local items = {}

    table.insert(items, {
      label = "+ New session",
      session_id = nil,
      title = "",
    })

    for _, session in ipairs(sessions) do
      local title = session.title or session.id
      local updated = session.time and session.time.updated
      local time_str = updated and relative_time(updated) or ""
      table.insert(items, {
        label = title .. "  " .. time_str,
        session_id = session.id,
        title = title,
      })
    end

    local labels = {}
    for _, item in ipairs(items) do
      table.insert(labels, item.label)
    end

    vim.ui.select(labels, { prompt = "0x0 Session:" }, function(choice, idx)
      if not choice or not idx then
        return
      end

      local selected = items[idx]
      if not selected then
        return
      end

      if selected.session_id then
        callback(selected.session_id, selected.title)
        return
      end

      -- Create new session
      api.create_session(nil, function(create_err, session_id)
        if create_err then
          vim.notify("0x0: failed to create session: " .. create_err, vim.log.levels.ERROR)
          return
        end
        if not session_id then
          vim.notify("0x0: failed to create session", vim.log.levels.ERROR)
          return
        end
        callback(session_id, "New session")
      end)
    end)
  end)
end

return M
