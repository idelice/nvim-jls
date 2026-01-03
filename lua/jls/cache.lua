local util = require("jls.util")

local M = {}

local function cache_home()
  return os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")
end

function M.workspace_cache_root()
  return util.joinpath(cache_home(), "nvim-jls")
end

function M.workspace_cache_dir(root)
  local name = vim.fn.fnamemodify(root, ":t")
  if name == nil or name == "" then
    name = root:gsub("[/%s]", "_")
  end
  return util.joinpath(M.workspace_cache_root(), name)
end

function M.workspace_cache_path(root)
  return util.joinpath(M.workspace_cache_dir(root), "config.json")
end

function M.read_workspace_cache(root)
  local path = M.workspace_cache_path(root)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  local ok, data = pcall(vim.fn.readfile, path)
  if not ok or not data then
    return {}
  end
  local decoded = vim.fn.json_decode(table.concat(data, "\n"))
  if type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

function M.write_workspace_cache(root, cache)
  local path = M.workspace_cache_path(root)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local ok, encoded = pcall(vim.fn.json_encode, cache)
  if not ok or not encoded then
    return
  end
  pcall(vim.fn.writefile, { encoded }, path)
end

function M.apply_workspace_cache(cfg, root)
  local entry = M.read_workspace_cache(root)
  if type(entry) ~= "table" or next(entry) == nil then
    return cfg
  end
  if (not cfg.jls_dir or cfg.jls_dir == "") and entry.jls_dir then
    cfg.jls_dir = entry.jls_dir
  end
  if (not cfg.java_home or cfg.java_home == "") and entry.java_home then
    cfg.java_home = entry.java_home
  end
  cfg.lombok = cfg.lombok or {}
  if (not cfg.lombok.path or cfg.lombok.path == "") and entry.lombok_path then
    cfg.lombok.path = entry.lombok_path
  end
  if (not cfg.lombok.javaagent or cfg.lombok.javaagent == "") and entry.lombok_javaagent then
    cfg.lombok.javaagent = entry.lombok_javaagent
  end
  return cfg
end

function M.update_workspace_cache(root, cfg)
  local entry = {
    jls_dir = cfg.jls_dir,
    java_home = cfg.java_home,
    lombok_path = cfg.lombok and cfg.lombok.path or nil,
    lombok_javaagent = cfg.lombok and cfg.lombok.javaagent or nil,
  }
  M.write_workspace_cache(root, entry)
end

function M.server_cache_dir(root)
  local safe = root:gsub("[/%s]", "_")
  return util.joinpath(cache_home(), "jls", safe)
end

function M.remove_dir(path)
  return pcall(vim.fn.delete, path, "rf")
end

return M
