local cmd = require("jls.cmd")
local config = require("jls.config")
local root = require("jls.root")
local util = require("jls.util")

local M = {}

local warned_roots = {}

local function find_client_for_root(root_dir)
  for _, client in ipairs(vim.lsp.get_clients({ name = "jls" })) do
    if client.config and client.config.root_dir == root_dir then
      return client
    end
  end
  return nil
end

---@param cfg JlsConfig
---@return table
local function build_settings(cfg)
  return vim.deepcopy(cfg.settings or {})
end

---@param bufnr integer
---@param client table|nil
---@param cfg JlsConfig
local function on_attach(bufnr, client, cfg)
  if not client or client.name ~= "jls" then
    return
  end
end

---@param state table
---@param opts JlsConfig|nil
---@return table|nil
---@return string|nil
function M.make_lsp_config(state, opts)
  local cfg = config.merge(state.config, opts or {})
  local root_dir, _ = root.resolve_root_info(vim.api.nvim_buf_get_name(0), cfg)
  local cmdline, cmd_env = cmd.build_cmd(cfg, root_dir)
  if not cmdline then
    return nil, cmd_env
  end

  state._last_resolved_cfg = cfg
  return {
    name = "jls",
    cmd = cmdline,
    cmd_env = cmd_env,
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
  local root_dir = lsp_config.root_dir
  if type(root_dir) == "function" then
    root_dir = root_dir(vim.api.nvim_buf_get_name(0)) or vim.fn.getcwd()
  end

  local existing = find_client_for_root(root_dir)
  if existing then
    pcall(vim.lsp.buf_attach_client, bufnr, existing.id)
    on_attach(bufnr, existing, cfg)
    return
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
  local clients = vim.lsp.get_clients({ name = "jls" })
  if #clients == 0 then
    util.notify("JLS: no running clients", vim.log.levels.WARN)
    return
  end
  for _, client in ipairs(clients) do
    client:stop(true)
  end
  util.notify("JLS: stopped " .. tostring(#clients) .. " client(s)", vim.log.levels.INFO)
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
  local cmdline, cmd_env_or_err = cmd.build_cmd(cfg, root_dir)
  local lines = {
    "JLS Doctor",
    "root: " .. root_dir,
    fallback and "root-warning: markers not found, using cwd" or "root-warning: none",
    "jls_dir: " .. tostring(cfg.jls_dir),
    "settings: " .. vim.inspect(cfg.settings),
  }
  if cmdline then
    table.insert(lines, "cmd: " .. table.concat(cmdline, " "))
    table.insert(lines, "cmd_env: " .. vim.inspect(cmd_env_or_err or {}))
  else
    table.insert(lines, "cmd: <error> " .. (cmd_env_or_err or "unknown"))
  end
  util.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
