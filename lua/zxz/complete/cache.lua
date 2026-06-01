--- LRU cache for completion results with prefix-match shifting.
--- When the user types a character that matches the start of a cached completion,
--- the completion is shifted by one character and reused without a server round-trip.

local M = {}

---@class zxz.complete.CacheEntry
---@field key string
---@field completion string
---@field timestamp number

---@type zxz.complete.CacheEntry[]
local _entries = {}
local _max_entries = 100

--- Initialize the cache with a max size.
---@param max_entries integer
function M.init(max_entries)
	_max_entries = max_entries or 100
	_entries = {}
end

--- Generate a cache key from context.
---@param prefix string
---@param suffix string
---@param language string
---@return string
function M.make_key(prefix, suffix, language)
	-- Use last 200 chars of prefix + first 200 chars of suffix + language
	local p = prefix:sub(-200)
	local s = suffix:sub(1, 200)
	return p .. "\0" .. s .. "\0" .. language
end

--- Get a cached completion.
---@param key string
---@return string?
function M.get(key)
	for _, entry in ipairs(_entries) do
		if entry.key == key then
			entry.timestamp = vim.uv.now()
			return entry.completion
		end
	end
	return nil
end

--- Store a completion in the cache.
---@param key string
---@param completion string
function M.set(key, completion)
	-- Check if key already exists
	for i, entry in ipairs(_entries) do
		if entry.key == key then
			entry.completion = completion
			entry.timestamp = vim.uv.now()
			return
		end
	end

	-- Add new entry
	table.insert(_entries, {
		key = key,
		completion = completion,
		timestamp = vim.uv.now(),
	})

	-- Evict oldest if over max
	if #_entries > _max_entries then
		local oldest_idx = 1
		local oldest_time = _entries[1].timestamp
		for i = 2, #_entries do
			if _entries[i].timestamp < oldest_time then
				oldest_idx = i
				oldest_time = _entries[i].timestamp
			end
		end
		table.remove(_entries, oldest_idx)
	end
end

local function split_key(key)
	local first = key:find("\0", 1, true)
	if not first then
		return nil
	end
	local second = key:find("\0", first + 1, true)
	if not second then
		return nil
	end
	return key:sub(1, first - 1), key:sub(first + 1, second - 1), key:sub(second + 1)
end

--- Get a cached completion, or shift a prior entry when the user typed one
--- matching character.
---@param prefix string
---@param suffix string
---@param language string
---@return string? completion
---@return string? matched_key
function M.get_or_shift(prefix, suffix, language)
	local key = M.make_key(prefix, suffix, language)
	local hit = M.get(key)
	if hit then
		return hit, key
	end

	local new_p = prefix:sub(-200)
	local new_s = suffix:sub(1, 200)

	for _, entry in ipairs(_entries) do
		local old_p, old_s, old_lang = split_key(entry.key)
		if old_p and old_s == new_s and old_lang == language then
			if #new_p == #old_p + 1 and new_p:sub(1, #old_p) == old_p then
				local typed = new_p:sub(#old_p + 1, #old_p + 1)
				if entry.completion:sub(1, 1) == typed then
					local shifted = entry.completion:sub(2)
					if shifted ~= "" then
						M.set(key, shifted)
						return shifted, key
					end
				end
			end
		end
	end

	return nil, nil
end

--- Clear all cached entries.
function M.clear()
	_entries = {}
end

return M
