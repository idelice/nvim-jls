local config = require("jls.config")
local util = require("jls.util")
local client_mod = require("jls.client")
local cache = require("jls.cache")
local lsp = require("jls.lsp")

---@class JlsModule
local M = {}

local state = {
  config = config.default(),
  _last_resolved_cfg = nil,
}

---@type JlsConfig
M.config = state.config

--- Accept user configuration opts (called automatically by lazy.nvim with `opts = {...}`).
--- Store them so ftplugin/java.lua's `jls.start()` picks them up.
---@param opts JlsConfig|nil
function M.setup(opts)
  if opts then
    state.config = config.merge(state.config, opts)
    M.config = state.config
  end
end

---@param opts JlsConfig|nil
function M.make_lsp_config(opts)
  return lsp.make_lsp_config(state, opts)
end

local NOT_FOUND = "JLS not found. Install it with :MasonInstall jls or set jls_dir."
local INSTALLED = "JLS installed via Mason. Restart Neovim to start it."

local mason_installing = false

local function install_with_mason(err)
  if mason_installing then
    return
  end
  local ok, registry = pcall(require, "mason-registry")
  if not ok then
    util.notify(NOT_FOUND .. " (mason.nvim is not installed)", vim.log.levels.ERROR)
    return
  end
  mason_installing = true
  local started, start_err = pcall(registry.refresh, function()
    local ok_run, run_err = pcall(function()
      if not registry.has_package("jls") then
        mason_installing = false
        util.notify(NOT_FOUND .. " (package `jls` not found in mason-registry)", vim.log.levels.ERROR)
        return
      end
      local pkg = registry.get_package("jls")
      if pkg:is_installed() then
        mason_installing = false
        util.notify(
          err .. " (Mason package `jls` is installed but its launcher is missing — reinstall with :MasonInstall jls)",
          vim.log.levels.ERROR
        )
        return
      end
      if pkg:is_installing() then
        mason_installing = false
        return
      end
      util.notify("JLS not found — installing latest jls via Mason...", vim.log.levels.INFO)
      local handle = pkg:install()
      handle:once(
        "closed",
        vim.schedule_wrap(function()
          mason_installing = false
          if pkg:is_installed() then
            util.notify(INSTALLED, vim.log.levels.INFO)
          else
            util.notify(NOT_FOUND .. " (Mason install failed, see :Mason)", vim.log.levels.ERROR)
          end
        end)
      )
    end)
    if not ok_run then
      mason_installing = false
      util.notify(NOT_FOUND .. " (" .. tostring(run_err) .. ")", vim.log.levels.ERROR)
    end
  end)
  if not started then
    mason_installing = false
    util.notify(NOT_FOUND .. " (" .. tostring(start_err) .. ")", vim.log.levels.ERROR)
  end
end

---@param opts JlsConfig|nil
function M.start(opts)
  local _, err = lsp.start(state, opts, { notify = true })
  if err then
    local cfg = config.merge(state.config, opts or {})
    if vim.fn.expand(cfg.jls_dir or "") == config.mason_jls_dir() then
      install_with_mason(err)
    else
      util.notify(err, vim.log.levels.ERROR)
    end
  end
end

function M.stop()
  lsp.stop(state)
end

---@param opts JlsConfig|nil
function M.restart(opts)
  lsp.restart(state, opts, { notify = true })
end

function M.log()
  lsp.open_log()
end

function M.clear_cache()
  local client = vim.lsp.get_clients({ name = "jls" })[1]
  if not client then
    util.notify("[jls] not running", vim.log.levels.WARN)
    return
  end
  local root_dir = client.root_dir or (client.config and client.config.root_dir)
  if not root_dir then
    util.notify("Could not determine the JLS workspace root", vim.log.levels.ERROR)
    return
  end
  lsp.restart(state, nil, { notify = true }, function()
    local path, err = cache.clear(root_dir)
    if err then
      util.notify(err, vim.log.levels.ERROR)
    else
      util.notify("Cleared JLS cache: " .. path .. " — restarting JLS")
    end
  end)
end

---@param args JlsConfig|nil
function M.setup(args)
  state.config = config.merge(state.config, args or {})
  M.config = state.config
  client_mod.setup_autocmds(state.config)
end

return M
