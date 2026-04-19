local M = {}

---@param fname string|nil
---@param cfg JlsConfig
---@return { root_dir: string, fallback: boolean, marker: string|nil }
function M.resolve_root_details(fname, cfg)
  local path = fname or vim.api.nvim_buf_get_name(0)
  local cwd = vim.fn.getcwd()
  if path == "" then
    return { root_dir = cwd, fallback = true, marker = nil }
  end

  if vim.fs and vim.fs.find then
    local found = vim.fs.find(cfg.root_markers, { path = path, upward = true })
    if found and found[1] then
      return {
        root_dir = vim.fs.dirname(found[1]),
        fallback = false,
        marker = vim.fs.basename(found[1]),
      }
    end
  end

  local ok, util = pcall(require, "lspconfig.util")
  if ok then
    local root = util.root_pattern(unpack(cfg.root_markers))(path)
    if root then
      local marker = nil
      for _, candidate in ipairs(cfg.root_markers or {}) do
        local marker_path = (vim.fs and vim.fs.joinpath)
            and vim.fs.joinpath(root, candidate)
          or (root .. "/" .. candidate)
        if vim.fn.filereadable(marker_path) == 1 or vim.fn.isdirectory(marker_path) == 1 then
          marker = candidate
          break
        end
      end
      return { root_dir = root, fallback = false, marker = marker }
    end
  end

  return { root_dir = cwd, fallback = true, marker = nil }
end

---@param fname string|nil
---@param cfg JlsConfig
---@return string
---@return boolean
function M.resolve_root_info(fname, cfg)
  local details = M.resolve_root_details(fname, cfg)
  return details.root_dir, details.fallback
end

---@param fname string|nil
---@param cfg JlsConfig
---@return string
function M.resolve_root(fname, cfg)
  local root = M.resolve_root_info(fname, cfg)
  return root
end

return M
