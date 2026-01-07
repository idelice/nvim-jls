local config = require("jls.config")
local util = require("jls.util")
local client_mod = require("jls.client")
local lsp = require("jls.lsp")
local actions = require("jls.actions")
local codelens = require("jls.ui.codelens")

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
  lsp.start(state, opts)
end

function M.stop()
  lsp.stop(state)
end

---@param opts JlsConfig|nil
function M.restart(opts)
  lsp.restart(state, opts)
end

function M.info()
  lsp.info(state)
end

function M.doctor()
  lsp.doctor(state)
end

function M.cache_clear()
  lsp.cache_clear(state)
end

function M.cache_clear_restart()
  lsp.cache_clear_restart(state)
end

function M.logs()
  lsp.logs()
end

function M.statusline()
  return status.statusline()
end

function M.code_actions()
  actions.code_actions()
end

---@param args JlsConfig|nil
function M.setup(args)
  state.config = config.merge(state.config, args or {})
  M.config = state.config
  client_mod.setup_autocmds(state.config)
  codelens.setup(state.config)
end

return M
