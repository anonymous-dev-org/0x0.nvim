--- Persistent RAG for accepted completions via the Node completion server.
--- Keeps a sync session hot ring for immediate same-session recall.

local config = require("zxz.core.config")
local client = require("zxz.core.completion_client")
local cache = require("zxz.complete.cache")

local M = {}

---@class zxz.complete.RagResult
---@field direct? string
---@field examples? { prefix: string, suffix: string, completion: string }[]

---@type { hash: string, prefix: string, suffix: string, language: string, completion: string }[]
local _session = {}

local function cfg()
	return (config.current.complete or {}).rag or {}
end

local function enabled()
	local settings = cfg()
	return settings.enabled ~= false
end

function M.context_hash(prefix, suffix, language)
	return cache.make_key(prefix or "", suffix or "", language or "")
end

local function trim_field(text, max_chars)
	text = tostring(text or "")
	if #text <= max_chars then
		return text
	end
	if max_chars <= 3 then
		return text:sub(-max_chars)
	end
	return "..." .. text:sub(#text - max_chars + 4)
end

--- Sync session hot-ring lookup.
---@param ctx table
---@return string|nil completion
function M.lookup_session(ctx)
	if not enabled() then
		return nil
	end
	local hash = M.context_hash(ctx.prefix, ctx.suffix, ctx.language)
	for i = 1, #_session do
		if _session[i].hash == hash then
			return _session[i].completion
		end
	end
	return nil
end

local function remember_session(prefix, suffix, language, completion)
	local settings = cfg()
	local max_entries = settings.session_entries or 3
	local max_field_chars = settings.max_field_chars or 300
	local hash = M.context_hash(prefix, suffix, language)

	table.insert(_session, 1, {
		hash = hash,
		prefix = trim_field(prefix, max_field_chars),
		suffix = trim_field(suffix, max_field_chars),
		language = language,
		completion = trim_field(completion, max_field_chars),
	})

	while #_session > max_entries do
		table.remove(_session)
	end
end

--- Async lookup via the Node RAG index.
---@param ctx table
---@param on_result fun(result: zxz.complete.RagResult|nil, err?: any)
function M.lookup(ctx, on_result)
	if not enabled() then
		if on_result then
			on_result({})
		end
		return
	end

	local settings = cfg()
	client.rag_lookup({
		prefix = ctx.prefix,
		suffix = ctx.suffix,
		language = ctx.language,
		filepath = ctx.filepath,
		scope = ctx.scope,
		direct_hit_threshold = settings.direct_hit_threshold,
		example_threshold = settings.example_threshold,
		max_examples = settings.max_examples,
	}, function(result, err)
		if on_result then
			on_result(result, err)
		end
	end)
end

--- Record an accepted completion (session ring + async persist).
---@param prefix string
---@param suffix string
---@param language string
---@param completion string
---@param scope? table
---@param filepath? string
function M.record(prefix, suffix, language, completion, scope, filepath)
	if not enabled() then
		return
	end
	if type(completion) ~= "string" or completion == "" then
		return
	end
	if type(language) ~= "string" or language == "" then
		return
	end

	remember_session(prefix, suffix, language, completion)

	local settings = cfg()
	client.rag_record({
		prefix = prefix,
		suffix = suffix,
		language = language,
		filepath = filepath,
		completion = completion,
		scope = scope,
		max_entries = settings.max_entries,
		max_field_chars = settings.max_field_chars,
	})
end

function M.clear()
	_session = {}
end

return M
