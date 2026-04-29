local root_mod = require("jls.root")
local util = require("jls.util")

local M = {}

local function normalize(path)
  if vim.fs.abspath then
    return vim.fs.normalize(vim.fs.abspath(path))
  end
  if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(util.joinpath(vim.fn.getcwd(), path))
end

local function cache_home()
  local xdg = vim.env.XDG_CACHE_HOME
  if xdg and xdg ~= "" then
    return vim.fs.normalize(xdg)
  end
  return util.joinpath(vim.loop.os_homedir(), ".cache")
end

local function first_line(cmd, input)
  local out = vim.fn.systemlist(cmd, input)
  if vim.v.shell_error ~= 0 or not out or not out[1] then
    return nil
  end
  return out[1]
end

local function md5_hex(value)
  if vim.fn.executable("md5sum") == 1 then
    local line = first_line({ "md5sum", "-" }, value)
    return line and line:match("^%s*([0-9a-fA-F]+)")
  end

  if vim.fn.executable("md5") == 1 then
    local line = first_line({ "md5", "-q", "-s", value })
    return line and line:match("^%s*([0-9a-fA-F]+)")
  end

  if vim.fn.executable("openssl") == 1 then
    local line = first_line({ "openssl", "dgst", "-md5", "-r" }, value)
    return line and line:match("^%s*([0-9a-fA-F]+)")
  end

  return nil
end

local function workspace_cache_dir(workspace_root)
  local normalized = normalize(workspace_root)
  local name = vim.fs.basename(normalized)
  if not name or name == "" then
    name = "workspace"
  end

  local hash = md5_hex(normalized)
  if not hash then
    return nil, "No md5 tool found. Install md5sum, md5, or openssl."
  end

  return util.joinpath(cache_home(), "jls", name .. "-" .. hash:sub(1, 8))
end

local function is_direct_child(parent, child)
  local parent_norm = normalize(parent)
  local child_norm = normalize(child)
  return vim.fs.dirname(child_norm) == parent_norm
end

---@param cfg JlsConfig
---@return string|nil
---@return string|nil
function M.clear(cfg)
  local details = root_mod.resolve_root_details(nil, cfg)
  local target, err = workspace_cache_dir(details.root_dir)
  if err then
    return nil, err
  end

  local root = util.joinpath(cache_home(), "jls")
  if not is_direct_child(root, target) then
    return nil, "Refusing to delete cache outside " .. root
  end

  if vim.fn.isdirectory(target) == 0 then
    return target, nil
  end

  local ok = vim.fn.delete(target, "rf") == 0
  if not ok then
    return nil, "Failed to delete " .. target
  end

  return target, nil
end

return M
