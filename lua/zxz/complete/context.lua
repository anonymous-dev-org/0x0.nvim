--- Buffer context gathering for code completion.
--- Extracts prefix (before cursor) and suffix (after cursor) from the current buffer.

local M = {}

--- Maximum context to include around the cursor. Inline completion has to stay
--- fast; large prompts make ACP providers miss the short prompt timeout.
local MAX_PREFIX_LINES = 120
local MAX_SUFFIX_LINES = 80
local MAX_SCOPE_LINES = 120
local MAX_PREFIX_CHARS = 4000
local MAX_SUFFIX_CHARS = 2000
local MAX_SCOPE_CHARS = 4000
local MAX_HEADER_LINES = 30
local MAX_HEADER_CHARS = 1200
local MAX_IMPORT_LINES = 40
local MAX_IMPORT_CHARS = 1200

local IMPORT_LINE_PATTERNS = {
	"^%s*import%s",
	"^%s*from%s.+%simport%s",
	"^%s*require%(",
	"^%s*local%s.-%s*=%s*require%(",
	"^%s*use%s",
	"^%s*#include%s",
	"^%s*package%s",
	"^%s*using%s",
	"^%s*extern%s",
}

local SCOPE_TYPE_MARKERS = {
	"function",
	"method",
	"class",
	"struct",
	"interface",
	"impl",
	"object",
	"block",
	"chunk",
	"program",
	"source_file",
}

local function is_scope_node(node_type)
	if type(node_type) ~= "string" or node_type == "" then
		return false
	end
	for _, marker in ipairs(SCOPE_TYPE_MARKERS) do
		if node_type == marker or node_type:find(marker, 1, true) then
			return true
		end
	end
	return false
end

local function trim_start(text, max_chars)
	text = text or ""
	if #text <= max_chars then
		return text
	end
	return text:sub(#text - max_chars + 1)
end

local function trim_end(text, max_chars)
	text = text or ""
	if #text <= max_chars then
		return text
	end
	return text:sub(1, max_chars)
end

local function looks_like_import(line)
	for _, pattern in ipairs(IMPORT_LINE_PATTERNS) do
		if line:match(pattern) then
			return true
		end
	end
	return false
end

local function gather_imports(bufnr, cursor_row)
	local total = vim.api.nvim_buf_line_count(bufnr)
	local scan_end = math.min(total, math.max(cursor_row, MAX_IMPORT_LINES))
	if scan_end <= 0 then
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, scan_end, false)
	local imports = {}
	for _, line in ipairs(lines) do
		if looks_like_import(line) then
			imports[#imports + 1] = line
		end
	end
	if #imports == 0 then
		return nil
	end

	return trim_end(table.concat(imports, "\n"), MAX_IMPORT_CHARS)
end

local function gather_header(bufnr, cursor_row)
	if cursor_row <= MAX_HEADER_LINES then
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(MAX_HEADER_LINES, cursor_row - 1), false)
	if #lines == 0 then
		return nil
	end

	return trim_end(table.concat(lines, "\n"), MAX_HEADER_CHARS)
end

local function gather_scope(bufnr, row, col)
	if not vim.treesitter or not vim.treesitter.get_node then
		return nil
	end

	local ok, node = pcall(vim.treesitter.get_node, {
		bufnr = bufnr,
		pos = { row - 1, math.max(col - 1, 0) },
	})
	if not ok or not node then
		return nil
	end

	local scope = nil
	local n = node
	while n do
		local node_type = n:type()
		if is_scope_node(node_type) then
			scope = n
			break
		end
		n = n:parent()
	end
	if not scope then
		return nil
	end

	local start_row, _, end_row = scope:range()
	local total = vim.api.nvim_buf_line_count(bufnr)
	start_row = math.max(0, start_row)
	end_row = math.min(total - 1, end_row)
	if end_row < start_row then
		return nil
	end

	local line_count = end_row - start_row + 1
	if line_count > MAX_SCOPE_LINES then
		local half = math.floor(MAX_SCOPE_LINES / 2)
		start_row = math.max(0, row - 1 - half)
		end_row = math.min(total - 1, start_row + MAX_SCOPE_LINES - 1)
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
	if #lines == 0 then
		return nil
	end
	local text = trim_start(table.concat(lines, "\n"), MAX_SCOPE_CHARS)

	return {
		type = scope:type(),
		start_line = start_row + 1,
		end_line = end_row + 1,
		text = text,
	}
end

--- Gather context from the current buffer at the cursor position.
---@return { prefix: string, suffix: string, language: string, filepath: string, cursor: table, scope: table|nil, header: string|nil, imports: string|nil, indent: string }
function M.gather()
	local bufnr = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1] -- 1-indexed
	local col = cursor[2] -- 0-indexed

	local total = vim.api.nvim_buf_line_count(bufnr)

	local current_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
	local before_cursor = current_line:sub(1, col)
	local after_cursor = current_line:sub(col + 1)

	local prefix_start = math.max(0, row - 1 - MAX_PREFIX_LINES)
	local prefix_lines = vim.api.nvim_buf_get_lines(bufnr, prefix_start, row - 1, false)
	local prefix_parts = {}
	for i = 1, #prefix_lines do
		prefix_parts[i] = prefix_lines[i]
	end
	prefix_parts[#prefix_parts + 1] = before_cursor
	local prefix = trim_start(table.concat(prefix_parts, "\n"), MAX_PREFIX_CHARS)

	local suffix_end = math.min(total, row + MAX_SUFFIX_LINES)
	local suffix_parts = { after_cursor }
	if row < suffix_end then
		local tail = vim.api.nvim_buf_get_lines(bufnr, row, suffix_end, false)
		for i = 1, #tail do
			suffix_parts[#suffix_parts + 1] = tail[i]
		end
	end
	local suffix = trim_end(table.concat(suffix_parts, "\n"), MAX_SUFFIX_CHARS)

	local filetype = vim.bo[bufnr].filetype
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath == "" then
		filepath = "untitled." .. (filetype ~= "" and filetype or "txt")
	end

	local imports = gather_imports(bufnr, row)
	local header = imports and nil or gather_header(bufnr, row)

	return {
		prefix = prefix,
		suffix = suffix,
		language = filetype,
		filepath = filepath,
		cursor = {
			line = row,
			column = col,
		},
		scope = gather_scope(bufnr, row, col),
		header = header,
		imports = imports,
		indent = before_cursor:match("^(%s*)") or "",
	}
end

return M
