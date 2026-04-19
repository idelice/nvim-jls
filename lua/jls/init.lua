local config = require("jls.config")
local util = require("jls.util")
local client_mod = require("jls.client")
local lsp = require("jls.lsp")

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

---@param args JlsConfig|nil
function M.setup(args)
  state.config = config.merge(state.config, args or {})
  M.config = state.config
  client_mod.setup_autocmds(state.config)
end

return M
