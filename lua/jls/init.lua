local config = require("jls.config")
local util = require("jls.util")
local client_mod = require("jls.client")
local cache = require("jls.cache")
local lsp = require("jls.lsp")
local installer = require("jls.installer")

---@class JlsModule
local M = {}

local state = {
  config = config.default(),
  _last_resolved_cfg = nil,
}

---@type JlsConfig
M.config = state.config

---@param opts JlsConfig|nil
function M.make_lsp_config(opts)
  return lsp.make_lsp_config(state, opts)
end

---@param opts JlsConfig|nil
function M.start(opts)
  lsp.start(state, opts, { notify = true })
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
  local path, err = cache.clear(state.config)
  if err then
    util.notify(err, vim.log.levels.ERROR)
    return
  end
  util.notify("Cleared JLS cache: " .. path)
end

---Async: download and install the latest JLS release, or a specific version tag.
---@param version string|nil  e.g. "v1.2.3"; nil means latest
function M.install(version)
  if version then
    -- Pin to exact requested tag
    local current = installer.installed_version()
    if current == version then
      util.notify("JLS: already on version " .. version, vim.log.levels.INFO)
      return
    end
    util.notify("JLS: installing " .. version .. " ...", vim.log.levels.INFO)
    installer.install(version, function(install_err)
      if install_err then
        util.notify("JLS: install failed — " .. install_err, vim.log.levels.ERROR)
      end
    end)
    return
  end
  installer.latest_tag(function(err, tag)
    if err or not tag then
      util.notify("JLS: could not fetch latest version — " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    local current = installer.installed_version()
    if current == tag then
      util.notify("JLS: already on latest version " .. tag, vim.log.levels.INFO)
      return
    end
    installer.install(tag, function(install_err)
      if install_err then
        util.notify("JLS: install failed — " .. install_err, vim.log.levels.ERROR)
      end
    end)
  end)
end

---Async: update JLS to the latest release.
function M.update()
  installer.latest_tag(function(err, tag)
    if err or not tag then
      util.notify("JLS: could not fetch latest version — " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    local current = installer.installed_version()
    if current == tag then
      util.notify("JLS: already up to date " .. tag, vim.log.levels.INFO)
      return
    end
    local msg = current
      and ("JLS: updating " .. current .. " → " .. tag .. " ...")
      or ("JLS: installing " .. tag .. " ...")
    util.notify(msg, vim.log.levels.INFO)
    installer.install(tag, function(install_err)
      if install_err then
        util.notify("JLS: update failed — " .. install_err, vim.log.levels.ERROR)
      end
    end)
  end)
end

---@return string|nil
function M.installed_version()
  return installer.installed_version()
end

---@param args JlsConfig|nil
function M.setup(args)
  state.config = config.merge(state.config, args or {})
  M.config = state.config
  client_mod.setup_autocmds(state.config)
end

return M
