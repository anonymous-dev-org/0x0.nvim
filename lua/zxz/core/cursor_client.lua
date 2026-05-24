--- Cursor CLI completion client.
--- Drives `cursor-agent -p --output-format stream-json --stream-partial-output`
--- and exposes a `stream_completion` matching the ACP client's signature so the
--- inline-ghost pipeline can dispatch to either backend.
---
--- Cursor's headless CLI is an agent loop, not a raw completion endpoint —
--- expect ~1-3s first-token latency. Best used as an opt-in alternative to
--- codex-acp via `<Leader>ip`.

local log = require("zxz.core.log")

local M = {}

local function build_prompt(request)
  return table.concat({
    "You are an inline code completion engine.",
    "Predict the short fragment the user is most likely to type next at the cursor,",
    "inferring intent from the surrounding code in <prefix> and <suffix>.",
    "",
    "Rules:",
    "- Return ONLY the raw text to insert at the cursor. No prose, no explanations.",
    "- No markdown fences, no language tags, no tool calls, no questions.",
    "- Do not repeat any text from <prefix> or <suffix>.",
    "- Prefer a single line. Stop at the end of the current phrase, expression,",
    "  statement, or call — whichever ends first. Shortest useful completion.",
    "- If the cursor is mid-identifier, complete that identifier only.",
    "- If nothing useful can be added, return an empty string.",
    "",
    "File: " .. tostring(request.filepath or ""),
    "Language: " .. tostring(request.language or ""),
    "",
    "<prefix>",
    request.prefix or "",
    "</prefix>",
    "<suffix>",
    request.suffix or "",
    "</suffix>",
  }, "\n")
end

--- Walk a decoded stream-json event and extract any text payload contributed
--- by the assistant. cursor-agent's exact wire shape isn't strictly versioned,
--- so we probe the common locations defensively.
local function extract_assistant_text(event)
  if type(event) ~= "table" then
    return nil
  end
  if event.type ~= "assistant" and event.type ~= "message" then
    return nil
  end

  local message = event.message or event
  local content = message.content or message.delta or message.text
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return nil
  end

  local parts = {}
  for _, block in ipairs(content) do
    if type(block) == "string" then
      parts[#parts + 1] = block
    elseif type(block) == "table" then
      local t = block.type or ""
      if (t == "text" or t == "output_text" or t == "") and type(block.text) == "string" then
        parts[#parts + 1] = block.text
      end
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts)
end

---@param provider { command?: string, args?: string[], model?: string, name?: string, env?: table<string, string> }
---@param request { prefix: string, suffix: string, language?: string, filepath?: string, cwd?: string, model?: string }
---@param on_chunk fun(text: string)
---@param on_done fun(err?: any)
---@return fun() abort
function M.stream_completion(provider, request, on_chunk, on_done)
  local command = provider.command or "cursor-agent"
  if vim.fn.executable(command) ~= 1 then
    vim.schedule(function()
      on_done({ message = "cursor-agent not on PATH (set provider.command)" })
    end)
    return function() end
  end

  local model = request.model or provider.model
  local args = { "-p", "--output-format", "stream-json", "--stream-partial-output" }
  if model and model ~= "" then
    table.insert(args, "--model")
    table.insert(args, model)
  end
  for _, extra in ipairs(provider.args or {}) do
    table.insert(args, extra)
  end
  table.insert(args, build_prompt(request))

  local active = true
  local done = false
  local handle
  local stdout_buf = ""
  local emitted = "" -- running total of text we've already pushed to the caller
  local stderr_lines = {}

  local function finish(err)
    if done then
      return
    end
    done = true
    active = false
    vim.schedule(function()
      on_done(err)
    end)
  end

  local function handle_event(event)
    if event.type == "result" or event.subtype == "completed" then
      -- terminal event; on_exit will fire finish()
      return
    end
    if event.type == "error" then
      finish(event.error or event)
      return
    end
    local text = extract_assistant_text(event)
    if not text or text == "" then
      return
    end
    -- stream-partial-output usually emits running totals. Treat any text that
    -- starts with what we've already emitted as a running total; otherwise
    -- treat it as a fresh delta (some events legitimately are deltas).
    local delta
    if #text > #emitted and text:sub(1, #emitted) == emitted then
      delta = text:sub(#emitted + 1)
      emitted = text
    else
      delta = text
      emitted = emitted .. text
    end
    if delta ~= "" and active then
      vim.schedule(function()
        if active then
          on_chunk(delta)
        end
      end)
    end
  end

  local function flush_stdout(chunk, is_final)
    if chunk and chunk ~= "" then
      stdout_buf = stdout_buf .. chunk
    end
    while true do
      local nl = stdout_buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = stdout_buf:sub(1, nl - 1)
      stdout_buf = stdout_buf:sub(nl + 1)
      if line ~= "" then
        local ok, decoded = pcall(vim.json.decode, line)
        if ok and type(decoded) == "table" then
          handle_event(decoded)
        end
      end
    end
    if is_final and stdout_buf ~= "" then
      local ok, decoded = pcall(vim.json.decode, stdout_buf)
      if ok and type(decoded) == "table" then
        handle_event(decoded)
      end
      stdout_buf = ""
    end
  end

  handle = vim.system({ command, unpack(args) }, {
    cwd = request.cwd,
    env = provider.env,
    text = true,
    stdout = function(_, data)
      if data then
        flush_stdout(data, false)
      end
    end,
    stderr = function(_, data)
      if data and data ~= "" then
        stderr_lines[#stderr_lines + 1] = data
      end
    end,
  }, function(result)
    flush_stdout(nil, true)
    if result.code ~= 0 and #emitted == 0 then
      local err_msg = table.concat(stderr_lines, "") ~= "" and table.concat(stderr_lines, "")
        or ("cursor-agent exited " .. tostring(result.code))
      log.error("cursor-agent: " .. err_msg)
      finish({ message = err_msg })
      return
    end
    finish(nil)
  end)

  return function()
    if done or not active then
      return
    end
    active = false
    done = true
    if handle then
      pcall(function()
        handle:kill(9)
      end)
    end
  end
end

return M
