local config = require("zeroxzero.config")
local api = require("zeroxzero.api")

local M = {}

---@type integer? terminal buffer number
M.buf = nil
---@type integer? terminal window id
M.win = nil
---@type integer? terminal job id
M.job_id = nil
---@type boolean
M.connected = false

local function random_port()
  math.randomseed(os.time() + os.clock() * 1000)
  return math.random(16384, 65535)
end

local function open_window(buf)
  local cfg = config.current.terminal
  local pos = cfg.position

  if pos == "float" then
    local fo = cfg.float_opts or {}
    local width = fo.width or 0.8
    local height = fo.height or 0.8
    local ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
    local w = math.floor(width < 1 and ui.width * width or width)
    local h = math.floor(height < 1 and ui.height * height or height)
    local row = math.floor((ui.height - h) / 2)
    local col = math.floor((ui.width - w) / 2)
    return vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = w,
      height = h,
      row = row,
      col = col,
      style = "minimal",
      border = fo.border or "rounded",
    })
  elseif pos == "tab" then
    vim.cmd("tabnew")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    return win
  elseif pos == "split" then
    vim.cmd("botright " .. cfg.size .. "split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    return win
  else -- vsplit (default)
    vim.cmd("botright " .. cfg.size .. "vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    return win
  end
end

function M.start(callback)
  callback = callback or function() end
  local cfg = config.current
  local port = cfg.port > 0 and cfg.port or random_port()
  config.current.port = port

  -- Create terminal buffer
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].filetype = "zeroxzero"

  -- Open window
  M.win = open_window(M.buf)

  -- Build command
  local cmd = cfg.cmd .. " --port " .. port
  for _, arg in ipairs(cfg.args) do
    cmd = cmd .. " " .. arg
  end

  -- Start terminal
  M.job_id = vim.fn.termopen(cmd, {
    env = { ZEROXZERO_CALLER = "neovim" },
    on_exit = function()
      M.job_id = nil
      M.connected = false
      M.buf = nil
      M.win = nil
    end,
  })

  vim.cmd("startinsert")

  -- Poll for readiness
  local tries = 0
  local max_tries = 10
  local timer = vim.uv.new_timer()
  timer:start(200, 200, function()
    tries = tries + 1
    vim.schedule(function()
      api.health(function(err)
        if not err then
          timer:stop()
          timer:close()
          M.connected = true
          -- Start SSE after connection
          local ok, sse = pcall(require, "zeroxzero.sse")
          if ok then
            sse.connect()
          end
          callback(nil)
        elseif tries >= max_tries then
          timer:stop()
          timer:close()
          callback("failed to connect after " .. max_tries .. " attempts")
        end
      end)
    end)
  end)
end

function M.ensure(callback)
  callback = callback or function() end
  if M.connected and M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    callback(nil)
    return
  end
  M.start(callback)
end

function M.show()
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return false
  end

  -- Already visible
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_set_current_win(M.win)
    vim.cmd("startinsert")
    return true
  end

  -- Reopen window with existing buffer
  M.win = open_window(M.buf)
  vim.cmd("startinsert")
  return true
end

function M.hide()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, false)
    M.win = nil
    return true
  end
  return false
end

function M.toggle()
  -- If window is visible, hide it
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    M.hide()
    return
  end

  -- If buffer exists but window is hidden, show it
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    M.show()
    return
  end

  -- No process running, start one
  M.start()
end

function M.stop()
  local ok, sse = pcall(require, "zeroxzero.sse")
  if ok then
    sse.disconnect()
  end

  if M.job_id then
    vim.fn.jobstop(M.job_id)
    M.job_id = nil
  end

  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
    M.win = nil
  end

  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    vim.api.nvim_buf_delete(M.buf, { force = true })
    M.buf = nil
  end

  M.connected = false
end

return M
