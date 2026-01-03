local M = {}

---@param fname string|nil
---@param cfg JlsConfig
---@return string
---@return boolean
function M.resolve_root_info(fname, cfg)
  local path = fname or vim.api.nvim_buf_get_name(0)
  local cwd = vim.fn.getcwd()
  if path == "" then
    return cwd, true
  end

  if vim.fs and vim.fs.find then
    local found = vim.fs.find(cfg.root_markers, { path = path, upward = true })
    if found and found[1] then
      return vim.fs.dirname(found[1]), false
    end
  end

  local ok, util = pcall(require, "lspconfig.util")
  if ok then
    local root = util.root_pattern(unpack(cfg.root_markers))(path)
    if root then
      return root, false
    end
  end

  return cwd, true
end

---@param fname string|nil
---@param cfg JlsConfig
---@return string
function M.resolve_root(fname, cfg)
  local root = M.resolve_root_info(fname, cfg)
  return root
end

return M
