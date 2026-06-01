--- 0x0-completion: Inline ghost text code completions.
--- Dispatches to an ACP provider over stdio. Cursor is supported via
--- `cursor-agent acp`, not the one-shot CLI path.

local config = require("zxz.core.config")
local context = require("zxz.complete.context")
local client = require("zxz.core.acp_client")
local ghost = require("zxz.complete.ghost")
local debounce = require("zxz.complete.debounce")
local cache = require("zxz.complete.cache")
local log = require("zxz.core.log")

local function format_err(err)
	if err == nil then
		return "unknown error"
	end
	if type(err) == "string" then
		return err
	end
	if type(err) == "table" then
		if err.message and err.message ~= "" then
			return tostring(err.message)
		end
		return vim.inspect(err)
	end
	return tostring(err)
end

local function project_cwd()
	if vim.fn.has("nvim-0.10") == 1 then
		return vim.fn.getcwd(-1, 0)
	end
	return vim.fn.getcwd()
end

local function line_before_cursor(line, col)
	if col <= 0 then
		return ""
	end
	if vim.str_byteindex then
		local ok, byte_end = pcall(vim.str_byteindex, line, col, false)
		if ok and byte_end then
			return line:sub(1, byte_end)
		end
	end
	return line:sub(1, col)
end

local function line_after_cursor(line, col)
	if vim.str_byteindex then
		local ok, byte_start = pcall(vim.str_byteindex, line, col, false)
		if ok and byte_start then
			return line:sub(byte_start + 1)
		end
	end
	return line:sub(col + 1)
end

local function debug_enabled()
	local complete = config.current.complete or {}
	return complete.debug == true
end

local function debug_log(message)
	if debug_enabled() then
		log.debug("complete: " .. message)
	end
end

local function preview(text, max_len)
	text = tostring(text or ""):gsub("\n", "\\n")
	max_len = max_len or 120
	if #text <= max_len then
		return text
	end
	return text:sub(1, max_len) .. "..."
end

local function scope_summary(scope)
	if type(scope) ~= "table" then
		return "none"
	end
	return ("%s:%s-%s chars=%d"):format(
		tostring(scope.type or "scope"),
		tostring(scope.start_line or "?"),
		tostring(scope.end_line or "?"),
		#tostring(scope.text or "")
	)
end

local function extract_tagged_completion(text)
	local open_start, open_end = text:find("<completion[^>]*>")
	if open_start then
		local content = text:sub(open_end + 1)
		local close_start = content:find("</completion>", 1, true)
		if close_start then
			content = content:sub(1, close_start - 1)
		end
		content = content:gsub("^\r?\n", ""):gsub("\r?\n%s*$", "")
		return content, true
	end

	local trimmed = vim.trim(text)
	if trimmed:match("^<[^>]*$") or trimmed:match("^</?completion") then
		return "", true
	end

	return text, false
end

local function looks_like_agent_chatter(first_line)
	local lower = vim.trim(first_line or ""):lower()
	if lower == "" then
		return false
	end
	local patterns = {
		"^checking%s",
		"^looking%s",
		"^inspecting%s",
		"^searching%s",
		"^reading%s",
		"^i%s+can't",
		"^i%s+cannot",
		"^i%s+am%s",
		"^i'm%s",
		"^there%s+is%s+nothing",
		"^no%s+inferable",
		"^%(empty",
	}
	for _, pattern in ipairs(patterns) do
		if lower:find(pattern) then
			return true
		end
	end
	return false
end

local M = {}

---@type fun()? Current request abort function
local _abort_fn = nil

---@type string Accumulated completion text from streaming
local _streaming_text = ""

---@type string Last displayable completion text from streaming
local _visible_text = ""

---@type integer Active request generation; used to ignore late async chunks.
local _request_id = 0

local function resolve_provider()
	local provider, err = config.resolve_completion_provider()
	if not provider then
		vim.notify("0x0 completion: " .. tostring(err or "provider not configured"), vim.log.levels.ERROR)
		return nil, nil
	end
	local model = config.resolve_completion_model(provider, config.current.complete and config.current.complete.model)
	if not model then
		vim.notify("0x0 completion: no non-thinking model configured", vim.log.levels.ERROR)
		return nil, nil
	end
	return provider, model
end

local function visible_completion(text, before)
	text = (text or ""):gsub("^%s*```[%w_-]*\n?", ""):gsub("\n?```%s*$", "")
	text = text:gsub("^[\r\n]+", "")
	text = text:gsub("[%z\1-\8\11\12\14-\31\127]", "")
	local tagged
	text, tagged = extract_tagged_completion(text)
	if before and before ~= "" and text:sub(1, #before) == before then
		text = text:sub(#before + 1)
	end
	local first_line = vim.split(text, "\n", { plain = true })[1] or ""
	if vim.trim(first_line) == "" then
		return nil
	end
	if vim.trim(first_line):lower():find("^let me think") then
		return nil
	end
	if not tagged and looks_like_agent_chatter(first_line) then
		return nil
	end
	return text
end

function M._mode()
	return vim.fn.mode()
end

--- Set up the completion plugin.
---@param opts? table
function M.setup(opts)
	if opts then
		config.current.complete = vim.tbl_deep_extend("force", vim.deepcopy(config.current.complete), opts)
	end
	local cfg = config.current.complete

	if cfg.cache.enabled then
		cache.init(cfg.cache.max_entries)
	end

	-- Set up autocommands
	local group = vim.api.nvim_create_augroup("zxz_complete", { clear = true })

	local trigger_events = { "TextChangedI" }
	if cfg.trigger_on_cursor_moved then
		trigger_events[#trigger_events + 1] = "CursorMovedI"
	end

	vim.api.nvim_create_autocmd(trigger_events, {
		group = group,
		callback = function()
			if not config.current.complete.enabled then
				return
			end
			M._on_text_changed()
		end,
	})

	vim.api.nvim_create_autocmd("InsertLeave", {
		group = group,
		callback = function()
			M.dismiss()
		end,
	})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			M._cancel()
			if client.stop_all_completion_clients then
				client.stop_all_completion_clients()
			end
		end,
	})

	-- Set up keymaps
	M._setup_keymaps()
end

--- Handle text change in insert mode.
function M._on_text_changed()
	local cfg = config.current.complete
	local bufnr = vim.api.nvim_get_current_buf()
	local ft = vim.bo[bufnr].filetype

	-- Explicit per-buffer opt-out. Set by buffers that don't want ambient AI
	-- completion (e.g. chat input/transcript via disable_ambient_completion).
	if vim.b[bufnr].zxz_complete_disable then
		debug_log("skip: buffer disabled")
		return
	end

	-- Fallback safety net: only run in regular file buffers. Catches terminal,
	-- prompt, nofile scratch buffers, and anything that forgot to set the flag.
	if vim.bo[bufnr].buftype ~= "" then
		debug_log("skip: buftype=" .. tostring(vim.bo[bufnr].buftype))
		return
	end

	-- Check filetype exclusion
	for _, excluded in ipairs(cfg.filetypes.exclude) do
		if ft == excluded then
			debug_log("skip: excluded filetype=" .. tostring(ft))
			return
		end
	end

	-- Check minimum content on current line
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1]
	local col = cursor[2]
	local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
	local before = line_before_cursor(line, col)
	local after = line_after_cursor(line, col)

	-- Don't trigger on empty lines or very short prefixes
	if before:match("^%s*$") then
		debug_log("skip: empty prefix")
		M.dismiss()
		return
	end
	if after ~= "" then
		debug_log("skip: cursor is not at end of line")
		M.dismiss()
		return
	end

	-- Treesitter-gated suppression: skip completion inside comments and string
	-- literals. Best-effort — only runs when a parser is attached.
	if cfg.suppress_in_strings_and_comments ~= false then
		local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row - 1, math.max(col - 1, 0) } })
		if ok and node then
			local n = node
			while n do
				local t = n:type()
				if t:match("comment") or t == "string" or t:match("string_") or t:match("_string") then
					debug_log("skip: treesitter node=" .. tostring(t))
					M.dismiss()
					return
				end
				n = n:parent()
			end
		end
	end

	if cfg.cache.enabled then
		local ctx = context.gather()
		local cached = cache.get_or_shift(ctx.prefix, ctx.suffix, ctx.language)
		if cached then
			debug_log("cache hit")
			M._cancel_request_only()
			ghost.show(bufnr, row - 1, col, cached)
			return
		end
	end

	M._cancel()

	-- Debounce the completion request
	debug_log("schedule request debounce_ms=" .. tostring(cfg.debounce_ms))
	debounce.start(cfg.debounce_ms, function()
		M._request_completion()
	end)
end

--- Request a completion from the server.
function M._request_completion()
	local cfg = config.current.complete
	local bufnr = vim.api.nvim_get_current_buf()

	-- Check we're still in insert mode
	if M._mode() ~= "i" then
		debug_log("request aborted: mode=" .. tostring(M._mode()))
		return
	end

	local ctx = context.gather()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1] - 1 -- 0-based
	local col = cursor[2] -- 0-based
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	local before = line_before_cursor(line, col)
	local after = line_after_cursor(line, col)
	if after ~= "" then
		debug_log("request aborted: cursor is not at end of line")
		M.dismiss()
		return
	end
	local cwd = project_cwd()
	local provider, model = resolve_provider()
	if not provider then
		debug_log("request aborted: provider resolution failed")
		return
	end
	debug_log(
		("request start provider=%s model=%s file=%s line=%s col=%s prefix_chars=%d suffix_chars=%d scope=%s"):format(
			tostring(provider.name or provider.command),
			tostring(model),
			tostring(ctx.filepath),
			tostring(ctx.cursor and ctx.cursor.line or "?"),
			tostring(ctx.cursor and ctx.cursor.column or "?"),
			#tostring(ctx.prefix or ""),
			#tostring(ctx.suffix or ""),
			scope_summary(ctx.scope)
		)
	)

	-- Check cache
	if cfg.cache.enabled then
		local cached = cache.get_or_shift(ctx.prefix, ctx.suffix, ctx.language)
		if cached then
			debug_log("request cache hit")
			ghost.show(bufnr, row, col, cached)
			return
		end
	end

	_request_id = _request_id + 1
	local request_id = _request_id
	_streaming_text = ""
	_visible_text = ""
	local first_chunk_logged = false

	_abort_fn = client.stream_completion(provider, {
		prefix = ctx.prefix,
		suffix = ctx.suffix,
		language = ctx.language,
		filepath = ctx.filepath,
		cursor = ctx.cursor,
		scope = ctx.scope,
		cwd = cwd,
		max_tokens = cfg.max_tokens,
		temperature = cfg.temperature,
		model = model,
	}, function(chunk)
		if request_id ~= _request_id then
			return
		end
		-- On each text chunk
		_streaming_text = _streaming_text .. chunk
		if not first_chunk_logged then
			first_chunk_logged = true
			debug_log("first chunk request_id=" .. tostring(request_id) .. " text=" .. preview(chunk, 160))
		end

		-- Check we're still in insert mode in the same buffer and position.
		if M._mode() ~= "i" or vim.api.nvim_get_current_buf() ~= bufnr then
			debug_log("cancel: mode/buffer changed during stream")
			M._cancel()
			return
		end

		local cur = vim.api.nvim_win_get_cursor(0)
		if cur[1] - 1 ~= row or cur[2] ~= col then
			debug_log("cancel: cursor moved during stream")
			M._cancel()
			return
		end

		local display = visible_completion(_streaming_text, before)
		if not display then
			return
		end
		_visible_text = display
		ghost.show(bufnr, row, col, display)
	end, function(err)
		if request_id ~= _request_id then
			return
		end
		_abort_fn = nil

		if err then
			local msg = format_err(err)
			log.warn("complete: stream failed: " .. msg)
			vim.schedule(function()
				vim.notify("0x0 completion failed: " .. msg, vim.log.levels.WARN)
			end)
			return
		end
		debug_log(
			("request done request_id=%s streamed_chars=%d visible_chars=%d visible=%s"):format(
				tostring(request_id),
				#_streaming_text,
				#_visible_text,
				preview(_visible_text, 120)
			)
		)

		-- Cache the result
		if cfg.cache.enabled and _visible_text ~= "" then
			local key = cache.make_key(ctx.prefix, ctx.suffix, ctx.language)
			cache.set(key, _visible_text)
		end
	end)
end

--- Cancel pending request and clear ghost text.
function M._cancel()
	debounce.stop()
	_request_id = _request_id + 1
	if _abort_fn then
		_abort_fn()
		_abort_fn = nil
	end
	ghost.clear()
	_streaming_text = ""
	_visible_text = ""
end

--- Dismiss the current completion suggestion.
function M.dismiss()
	M._cancel()
end

---@return boolean
function M.is_visible()
	return ghost.is_visible()
end

--- Accept the current completion.
---@return boolean
function M.accept()
	if ghost.is_visible() then
		M._cancel_request_only()
		return ghost.accept()
	end
	return false
end

--- Cancel request without clearing ghost text.
function M._cancel_request_only()
	debounce.stop()
	_request_id = _request_id + 1
	if _abort_fn then
		_abort_fn()
		_abort_fn = nil
	end
end

--- Toggle completion on/off.
function M.toggle()
	config.current.complete.enabled = not config.current.complete.enabled
	if not config.current.complete.enabled then
		M.dismiss()
	end
end

local function choose_model()
	local choices = config.completion_model_choices()
	vim.ui.select(choices, {
		prompt = "0x0 completion model",
		format_item = function(model)
			return model
		end,
	}, function(choice)
		if not choice then
			return
		end
		config.current.complete.model = choice
		M.dismiss()
	end)
end

function M.settings()
	local actions = {
		{
			label = "Enabled: " .. tostring(config.current.complete.enabled),
			run = M.toggle,
		},
		{
			label = "Model: " .. tostring(config.current.complete.model or "provider default"),
			run = choose_model,
		},
	}

	vim.ui.select(actions, {
		prompt = "0x0 completion settings",
		format_item = function(action)
			return action.label
		end,
	}, function(action)
		if action then
			action.run()
		end
	end)
end

--- Set up insert-mode keymaps.
function M._setup_keymaps()
	local cfg = config.current.complete
	local km = cfg.keymaps or {}

	pcall(vim.keymap.del, "i", km.accept or "", { buffer = false })
	pcall(vim.keymap.del, "i", km.dismiss or "", { buffer = false })

	if km.enabled == false then
		return
	end

	local function fall_through(key)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
	end

	if km.accept and km.accept ~= "" then
		vim.keymap.set("i", km.accept, function()
			if not M.accept() then
				if km.accept_fallback ~= false then
					fall_through(km.accept)
				end
			end
		end, { silent = true, desc = "0x0: Accept completion", noremap = true })
	end

	if km.dismiss and km.dismiss ~= "" then
		vim.keymap.set("i", km.dismiss, function()
			if ghost.is_visible() then
				M.dismiss()
				return
			end
			if km.accept_fallback ~= false then
				fall_through(km.dismiss)
			end
		end, { silent = true, desc = "0x0: Dismiss completion", noremap = true })
	end
end

return M
