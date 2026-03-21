local cmd = require("jls.cmd")
local config = require("jls.config")
local root = require("jls.root")
local util = require("jls.util")
local client_mod = require("jls.client")

local M = {}

local warned_roots = {}

---@param cfg JlsConfig
---@return table
local function build_settings(cfg)
  local settings = vim.deepcopy(cfg.settings or {})
  if cfg.codelens then
    settings.java = settings.java or {}
    if settings.java.codeLens == nil and settings.java.codelens == nil then
      settings.java.codeLens = true
    end
  end
  return settings
end

---@param bufnr integer
---@param client table|nil
---@param cfg JlsConfig
local function on_attach(bufnr, client, cfg)
  if not client or client.name ~= "jls" then
    return
  end

  if cfg.codelens then
    local ok_codelens, codelens = pcall(function()
      return vim.lsp.codelens
    end)
    if ok_codelens and codelens and type(codelens.refresh) == "function" then
      local function refresh_codelens()
        pcall(codelens.refresh, { bufnr = bufnr })
        if type(codelens.display) == "function" then
          pcall(codelens.display, { bufnr = bufnr })
        end
      end
      refresh_codelens()
      local group = vim.api.nvim_create_augroup("JlsCodeLens", { clear = false })
      vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "BufWritePost" }, {
        group = group,
        buffer = bufnr,
        callback = refresh_codelens,
      })
    end
  end
end

---@param state table
---@param opts JlsConfig|nil
---@return table|nil
---@return string|nil
function M.make_lsp_config(state, opts)
  local cfg = config.merge(state.config, opts or {})
  local root_dir, _ = root.resolve_root_info(vim.api.nvim_buf_get_name(0), cfg)
  local cmdline, err = cmd.build_cmd(cfg)
  if not cmdline then
    return nil, err
  end

  state._last_resolved_cfg = cfg
  return {
    name = "jls",
    cmd = cmdline,
    on_attach = function(client, bufnr)
      on_attach(bufnr, client, cfg)
    end,
    root_dir = function(fname)
      return root.resolve_root(fname, cfg)
    end,
    settings = build_settings(cfg),
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
  local cfg = config.merge(state.config, opts or {})
  -- Prefer any running JLS client and just attach this buffer (avoids spawning
  -- a new client when jumping into jars in ~/.m2)
  local existing = client_mod.get(nil)
  if existing then
    pcall(vim.lsp.buf_attach_client, bufnr, existing.id)
    on_attach(bufnr, existing, cfg)
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
  M.stop(state)
  vim.defer_fn(function()
    M.start(state, opts)
  end, 50)
end

---@param state table
function M.doctor(state)
  local cfg = config.merge(state.config)
  local root_dir, fallback = root.resolve_root_info(vim.api.nvim_buf_get_name(0), cfg)
  local cmdline, err = cmd.build_cmd(cfg)
  local lines = {
    "JLS Doctor",
    "root: " .. root_dir,
    fallback and "root-warning: markers not found, using cwd" or "root-warning: none",
    "jls_dir: " .. tostring(cfg.jls_dir),
    "settings: " .. vim.inspect(cfg.settings),
  }
  if cmdline then
    table.insert(lines, "cmd: " .. table.concat(cmdline, " "))
  else
    table.insert(lines, "cmd: <error> " .. (err or "unknown"))
  end
  util.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
