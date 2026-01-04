local cache = require("jls.cache")
local cmd = require("jls.cmd")
local config = require("jls.config")
local lombok = require("jls.lombok")
local root = require("jls.root")
local util = require("jls.util")
local client_mod = require("jls.client")

local M = {}

local warned_roots = {}

---@param state table
---@param opts JlsConfig|nil
---@return table|nil
---@return string|nil
function M.make_lsp_config(state, opts)
  local cfg = config.merge(state.config, opts or {})
  local root_dir, _ = root.resolve_root_info(vim.api.nvim_buf_get_name(0), cfg)
  cfg = cache.apply_workspace_cache(cfg, root_dir)
  cfg = lombok.detect(cfg)
  local cmdline, err = cmd.build_cmd(cfg)
  if not cmdline then
    return nil, err
  end

  state._last_resolved_cfg = cfg
  return {
    name = "jls",
    cmd = cmdline,
    filetypes = cfg.filetypes,
    root_dir = function(fname)
      return root.resolve_root(fname, cfg)
    end,
    settings = cfg.settings,
    init_options = cfg.init_options,
    cmd_env = cmd.build_env(cfg),
  }
end

---@param state table
---@param opts JlsConfig|nil
function M.start(state, opts)
  local lsp_config, err = M.make_lsp_config(state, opts)
  if not lsp_config then
    util.notify(err or "JLS configuration failed", vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  -- Prefer any running JLS client and just attach this buffer (avoids spawning
  -- a new client when jumping into jars in ~/.m2)
  local existing = client_mod.get(nil)
  if existing then
    pcall(vim.lsp.buf_attach_client, bufnr, existing.id)
    return
  end

  local root_dir = lsp_config.root_dir
  if type(root_dir) == "function" then
    root_dir = root_dir(vim.api.nvim_buf_get_name(0)) or vim.fn.getcwd()
  end

  local _, fallback = root.resolve_root_info(vim.api.nvim_buf_get_name(0), state.config)
  if fallback and not warned_roots[root_dir] then
    warned_roots[root_dir] = true
    util.notify("JLS: root markers not found; using cwd: " .. root_dir, vim.log.levels.WARN)
  end

  cache.update_workspace_cache(root_dir, state._last_resolved_cfg or config.merge(state.config, opts or {}))
  util.notify("JLS: starting...", vim.log.levels.INFO)
  local ok, lspconfig = pcall(require, "lspconfig")
  local ok_configs, configs = pcall(require, "lspconfig.configs")
  if ok and ok_configs and configs and configs.jls then
    lspconfig.jls.setup(lsp_config)
    if lspconfig.jls.manager and lspconfig.jls.manager.try_add_wrapper then
      lspconfig.jls.manager.try_add_wrapper()
    end
  else
    if type(lsp_config.root_dir) == "function" then
      lsp_config.root_dir = lsp_config.root_dir(vim.api.nvim_buf_get_name(0)) or vim.fn.getcwd()
    end
    vim.lsp.start(lsp_config)
  end

  local group = vim.api.nvim_create_augroup("JlsAttachOnce", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and client.name == "jls" then
        vim.api.nvim_del_augroup_by_id(group)
        util.notify("JLS: started", vim.log.levels.INFO)
      end
    end,
    once = true,
  })
  vim.defer_fn(function()
    local ok_ac, ac = pcall(vim.api.nvim_get_autocmds, { group = group })
    if not ok_ac or not ac or #ac == 0 then
      return
    end
    pcall(vim.api.nvim_del_augroup_by_id, group)
    util.notify("JLS: start timed out (no attach)", vim.log.levels.WARN)
  end, 30000)
end

---@param _state table
function M.stop(_state)
  local client = client_mod.get(nil)
  if not client then
    util.notify("JLS: no running clients", vim.log.levels.WARN)
    return
  end
  client:stop(true)
  util.notify("JLS: stopped", vim.log.levels.INFO)
end

---@param state table
---@param opts JlsConfig|nil
function M.restart(state, opts)
  util.notify("JLS: restarting...", vim.log.levels.INFO)
  M.stop(state)
  M.start(state, opts)
end

---@param state table
function M.info(state)
  local cfg = config.merge(state.config)
  local cmdline, err = cmd.build_cmd(cfg)
  if not cmdline then
    util.notify(err or "JLS command resolution failed", vim.log.levels.ERROR)
    return
  end

  local root_dir, fallback = root.resolve_root_info(vim.api.nvim_buf_get_name(0), cfg)
  local lines = {
    "JLS",
    "root: " .. root_dir,
    fallback and "root-warning: markers not found, using cwd" or "root-warning: none",
    "cmd: " .. table.concat(cmdline, " "),
  }
  util.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

---@param state table
function M.doctor(state)
  local cfg = config.merge(state.config)
  local root_dir, fallback = root.resolve_root_info(vim.api.nvim_buf_get_name(0), cfg)
  cfg = cache.apply_workspace_cache(cfg, root_dir)
  cfg = lombok.detect(cfg)
  local cmdline, err = cmd.build_cmd(cfg)
  local lines = {
    "JLS Doctor",
    "root: " .. root_dir,
    fallback and "root-warning: markers not found, using cwd" or "root-warning: none",
    "jls_dir: " .. tostring(cfg.jls_dir),
    "java_home: " .. tostring(cfg.java_home),
    "lombok.path: " .. tostring(cfg.lombok and cfg.lombok.path or nil),
    "lombok.javaagent: " .. tostring(cfg.lombok and cfg.lombok.javaagent or nil),
    "settings: " .. vim.inspect(cfg.settings),
  }
  if cmdline then
    table.insert(lines, "cmd: " .. table.concat(cmdline, " "))
  else
    table.insert(lines, "cmd: <error> " .. (err or "unknown"))
  end
  util.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

---@param state table
function M.cache_clear(state)
  local cfg = config.merge(state.config)
  local root_dir = root.resolve_root(vim.api.nvim_buf_get_name(0), cfg)
  local dir = cache.server_cache_dir(root_dir)
  if vim.fn.isdirectory(dir) == 0 then
    util.notify("JLS cache not found: " .. dir, vim.log.levels.INFO)
    return
  end
  if cache.remove_dir(dir) then
    util.notify("JLS cache removed: " .. dir, vim.log.levels.INFO)
  else
    util.notify("Failed to remove JLS cache: " .. dir, vim.log.levels.ERROR)
  end
end

---@param state table
function M.cache_clear_restart(state)
  M.cache_clear(state)
  M.restart(state)
end

function M.logs()
  local log_path = vim.lsp.get_log_path()
  if vim.fn.filereadable(log_path) == 0 then
    util.notify("LSP log not found: " .. log_path, vim.log.levels.WARN)
    return
  end
  vim.cmd("split " .. vim.fn.fnameescape(log_path))
end

return M
