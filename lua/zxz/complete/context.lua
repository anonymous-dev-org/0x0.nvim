--- Buffer context gathering for code completion.
--- Extracts prefix (before cursor) and suffix (after cursor) from the current buffer.

local M = {}

--- Maximum lines to include in prefix/suffix.
local MAX_PREFIX_LINES = 1500
local MAX_SUFFIX_LINES = 500

--- Gather context from the current buffer at the cursor position.
---@return { prefix: string, suffix: string, language: string, filepath: string }
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
  local prefix = table.concat(prefix_parts, "\n")

  local suffix_end = math.min(total, row + MAX_SUFFIX_LINES)
  local suffix_parts = { after_cursor }
  if row < suffix_end then
    local tail = vim.api.nvim_buf_get_lines(bufnr, row, suffix_end, false)
    for i = 1, #tail do
      suffix_parts[#suffix_parts + 1] = tail[i]
    end
  end
  local suffix = table.concat(suffix_parts, "\n")

  local filetype = vim.bo[bufnr].filetype
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    filepath = "untitled." .. (filetype ~= "" and filetype or "txt")
  end

  return {
    prefix = prefix,
    suffix = suffix,
    language = filetype,
    filepath = filepath,
  }
end

return M
