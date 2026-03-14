local config = require("zeroxzero.config")

local M = {}

---@param method string
---@param path string
---@param opts? {body?: table, timeout?: number}
---@param callback fun(err?: string, response?: {status: number, body: any})
function M.request(method, path, opts, callback)
  opts = opts or {}
  local cfg = config.current
  local url = string.format("http://%s:%d%s", cfg.hostname, cfg.port, path)

  local cmd = { "curl", "-s", "-w", "\n%{http_code}", "-X", method }

  table.insert(cmd, "-H")
  table.insert(cmd, "x-zeroxzero-directory: " .. vim.fn.getcwd())

  if cfg.auth then
    table.insert(cmd, "-u")
    table.insert(cmd, cfg.auth.username .. ":" .. cfg.auth.password)
  end

  if opts.body then
    table.insert(cmd, "-H")
    table.insert(cmd, "Content-Type: application/json")
    table.insert(cmd, "-d")
    table.insert(cmd, vim.json.encode(opts.body))
  end

  if opts.timeout then
    table.insert(cmd, "--max-time")
    table.insert(cmd, tostring(opts.timeout))
  end

  table.insert(cmd, url)

  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback("curl failed (exit " .. result.code .. "): " .. (result.stderr or ""))
        return
      end

      local output = result.stdout or ""
      local lines = vim.split(output, "\n", { trimempty = true })
      if #lines == 0 then
        callback("empty response")
        return
      end

      local status_code = tonumber(lines[#lines])
      table.remove(lines, #lines)
      local body_str = table.concat(lines, "\n")

      local body
      if body_str ~= "" then
        local ok, decoded = pcall(vim.json.decode, body_str)
        body = ok and decoded or body_str
      end

      callback(nil, { status = status_code or 0, body = body })
    end)
  end)
end

---@param method string
---@param path string
---@param opts? {body?: table, timeout?: number}
---@return string? err
---@return {status: number, body: any}? response
function M.request_sync(method, path, opts)
  opts = opts or {}
  local cfg = config.current
  local url = string.format("http://%s:%d%s", cfg.hostname, cfg.port, path)

  local cmd = { "curl", "-s", "-w", "\n%{http_code}", "-X", method }

  table.insert(cmd, "-H")
  table.insert(cmd, "x-zeroxzero-directory: " .. vim.fn.getcwd())

  if cfg.auth then
    table.insert(cmd, "-u")
    table.insert(cmd, cfg.auth.username .. ":" .. cfg.auth.password)
  end

  if opts.body then
    table.insert(cmd, "-H")
    table.insert(cmd, "Content-Type: application/json")
    table.insert(cmd, "-d")
    table.insert(cmd, vim.json.encode(opts.body))
  end

  if opts.timeout then
    table.insert(cmd, "--max-time")
    table.insert(cmd, tostring(opts.timeout))
  end

  table.insert(cmd, url)

  local result = vim.system(cmd, { text = true }):wait()

  if result.code ~= 0 then
    return "curl failed (exit " .. result.code .. "): " .. (result.stderr or "")
  end

  local output = result.stdout or ""
  local lines = vim.split(output, "\n", { trimempty = true })
  if #lines == 0 then
    return "empty response"
  end

  local status_code = tonumber(lines[#lines])
  table.remove(lines, #lines)
  local body_str = table.concat(lines, "\n")

  local body
  if body_str ~= "" then
    local ok, decoded = pcall(vim.json.decode, body_str)
    body = ok and decoded or body_str
  end

  return nil, { status = status_code or 0, body = body }
end

-- Convenience wrappers

function M.get(path, callback)
  M.request("GET", path, nil, callback)
end

function M.post(path, body, callback)
  M.request("POST", path, { body = body }, callback)
end

function M.delete(path, callback)
  M.request("DELETE", path, nil, callback)
end

-- Domain-specific wrappers

function M.health(callback)
  M.request("GET", "/global/health", { timeout = 2 }, callback)
end

function M.get_sessions(callback)
  M.get("/session", callback)
end

function M.get_session(session_id, callback)
  M.get("/session/" .. session_id, callback)
end

---Create a new session
---@param opts? {title?: string}
---@param callback fun(err?: string, session_id?: string)
function M.create_session(opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  M.request("POST", "/session", { body = opts }, function(err, response)
    if err then
      callback(err)
      return
    end
    if not response or response.status ~= 200 or not response.body or not response.body.id then
      callback("unexpected response from /session: " .. vim.inspect(response))
      return
    end
    callback(nil, response.body.id)
  end)
end

-- Prompt stash endpoints

---Append text to a session's prompt stash
---@param session_id string
---@param text string
---@param callback fun(err?: string)
function M.append_stash(session_id, text, callback)
  M.post("/session/" .. session_id .. "/prompt/stash", { text = text }, function(err, response)
    if err then
      callback(err)
      return
    end
    if not response or response.status ~= 200 then
      callback("server error: " .. tostring(response and response.status))
      return
    end
    callback(nil)
  end)
end

---Get a session's prompt stash
---@param session_id string
---@param callback fun(err?: string, text?: string)
function M.get_stash(session_id, callback)
  M.get("/session/" .. session_id .. "/prompt/stash", function(err, response)
    if err then
      callback(err)
      return
    end
    if not response or response.status ~= 200 then
      callback("server error: " .. tostring(response and response.status))
      return
    end
    callback(nil, response.body and response.body.text or "")
  end)
end

---Clear a session's prompt stash
---@param session_id string
---@param callback fun(err?: string)
function M.clear_stash(session_id, callback)
  M.delete("/session/" .. session_id .. "/prompt/stash", function(err, response)
    if err then
      callback(err)
      return
    end
    callback(nil)
  end)
end

return M
