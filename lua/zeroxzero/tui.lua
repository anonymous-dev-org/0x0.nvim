local api = require("zeroxzero.api")
local server = require("zeroxzero.server")
local context = require("zeroxzero.context")
local picker = require("zeroxzero.ui.picker")

local M = {}

---@type table<string, {session_id: string, title: string}>
local _pinned = {}

---Get the pinned session for the current cwd
---@return {session_id: string, title: string}?
function M.pinned()
  return _pinned[vim.fn.getcwd()]
end

---Pin a session to the current cwd
---@param session_id string
---@param title string
function M.pin(session_id, title)
  _pinned[vim.fn.getcwd()] = { session_id = session_id, title = title }
end

---Unpin the session for the current cwd
function M.unpin()
  _pinned[vim.fn.getcwd()] = nil
end

---Ensure a pinned session exists and is valid, then call back with its ID.
---If no session is pinned, opens the picker. If the pinned session is gone, shows error and re-opens picker.
---@param callback fun(session_id: string)
function M.ensure_session(callback)
  local pinned = M.pinned()
  if pinned then
    -- Validate the session still exists
    api.get_session(pinned.session_id, function(err, response)
      if err or not response or response.status ~= 200 then
        vim.notify("0x0: pinned session no longer exists, pick a new one", vim.log.levels.WARN)
        M.unpin()
        M.ensure_session(callback)
        return
      end
      callback(pinned.session_id)
    end)
    return
  end

  picker.pick_session(function(session_id, title)
    M.pin(session_id, title)
    vim.notify("0x0: pinned → " .. title, vim.log.levels.INFO)
    callback(session_id)
  end)
end

---Send text to the pinned session's prompt stash
---@param session_id string
---@param text string
---@param display_ref string short ref for the notification
local function send_to_stash(session_id, text, display_ref)
  local pinned = M.pinned()
  local session_title = pinned and pinned.title or session_id
  api.append_stash(session_id, text, function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("0x0: sent " .. display_ref .. " → " .. session_title, vim.log.levels.INFO)
  end)
end

---Send file reference for current buffer to the pinned session
function M.send_file()
  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    local ref = context.file_ref()
    if not ref then
      vim.notify("0x0: no file open", vim.log.levels.WARN)
      return
    end

    M.ensure_session(function(session_id)
      send_to_stash(session_id, ref, ref)
    end)
  end)
end

---Send visual selection with file reference to the pinned session
function M.send_selection()
  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)

    local ref = context.file_ref(nil, { include_selection = true })
    if not ref then
      vim.notify("0x0: no file open", vim.log.levels.WARN)
      return
    end

    local selection = context.selection_text()
    local text = ref
    if selection then
      text = text .. "\n```\n" .. selection .. "\n```"
    end

    M.ensure_session(function(session_id)
      send_to_stash(session_id, text, ref)
    end)
  end)
end

---Switch pinned session (unpin and re-open picker)
function M.switch_session()
  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    M.unpin()
    picker.pick_session(function(session_id, title)
      M.pin(session_id, title)
      vim.notify("0x0: pinned → " .. title, vim.log.levels.INFO)
    end)
  end)
end

return M
