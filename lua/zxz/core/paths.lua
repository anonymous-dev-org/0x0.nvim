local M = {}

local function join(...)
	if vim.fs and vim.fs.joinpath then
		return vim.fs.joinpath(...)
	end
	return table.concat({ ... }, "/")
end

function M.state_dir()
	return join(vim.fn.stdpath("state"), "0x0")
end

function M.log_path()
	return join(M.state_dir(), "debug.log")
end

function M.plugin_root()
	for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
		local server = join(path, "server", "dist", "completion-server.js")
		if vim.fn.filereadable(server) == 1 then
			return path
		end
	end
	return join(vim.fn.stdpath("data"), "0x0")
end

function M.gateway_models_path()
	return join(M.state_dir(), "models.json")
end

function M.gateway_key_path()
	return join(M.state_dir(), "gateway.json")
end

function M.rag_index_path()
	return join(M.state_dir(), "rag.msp")
end

function M.transformers_cache_path()
	return join(M.state_dir(), "transformers-cache")
end

function M.completion_server()
	return join(M.plugin_root(), "server", "dist", "completion-server.js")
end

local _migrated = false

function M.migrate_legacy()
	if _migrated then
		return
	end
	_migrated = true
	local legacy = join(vim.fn.stdpath("state"), "zeroxzero")
	local target = M.state_dir()
	if vim.fn.isdirectory(legacy) ~= 1 then
		return
	end
	if vim.fn.isdirectory(target) == 1 then
		return
	end
	local parent = vim.fn.fnamemodify(target, ":h")
	vim.fn.mkdir(parent, "p")
	local ok, err = pcall(vim.fn.rename, legacy, target)
	if not ok then
		vim.notify("0x0: state migration failed: " .. tostring(err), vim.log.levels.WARN)
	end
end

return M
