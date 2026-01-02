local uv = vim.loop

---@class JlsLombokConfig
---@field path string|nil Path to lombok.jar
---@field javaagent string|nil Path to lombok javaagent jar

---@class JlsStatusConfig
---@field enable boolean
---@field notify boolean

---@class JlsConfig
---@field cmd string[]|string|nil Explicit command to start JLS
---@field jls_dir string|nil Path to JLS install root containing dist/
---@field filetypes string[]
---@field root_markers string[]
---@field settings table
---@field init_options table
---@field env table<string,string>
---@field java_home string|nil JAVA_HOME override
---@field lombok JlsLombokConfig
---@field extra_args string[]
---@field status JlsStatusConfig

---@class JlsModule
local M = {}

local function default_config()
  return {
    cmd = nil,
    jls_dir = nil,
    filetypes = { "java" },
    root_markers = {
      "pom.xml",
      "build.gradle",
      "build.gradle.kts",
      "settings.gradle",
      "settings.gradle.kts",
      "WORKSPACE",
      "WORKSPACE.bazel",
      ".java-version",
      ".git",
    },
    settings = {
      jls = {
        features = {
          inlayHints = true,
          semanticTokens = true,
        },
      },
    },
    init_options = {},
    env = {},
    java_home = nil,
    lombok = { path = nil, javaagent = nil },
    extra_args = {},
    status = { enable = true, notify = false },
  }
end

---@type JlsConfig
M.config = default_config()

local function joinpath(...)
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end
  local parts = { ... }
  return table.concat(parts, "/")
end

local function detect_os()
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    return "windows"
  elseif vim.fn.has("mac") == 1 then
    return "mac"
  else
    return "linux"
  end
end

local function resolve_root(fname, cfg)
  local path = fname or vim.api.nvim_buf_get_name(0)
  if path == "" then
    return vim.fn.getcwd()
  end

  if vim.fs and vim.fs.find then
    local found = vim.fs.find(cfg.root_markers, { path = path, upward = true })
    if found and found[1] then
      return vim.fs.dirname(found[1])
    end
  end

  local ok, util = pcall(require, "lspconfig.util")
  if ok then
    local root = util.root_pattern(unpack(cfg.root_markers))(path)
    if root then
      return root
    end
  end

  return vim.fn.getcwd()
end

local function resolve_launcher(cfg)
  local cmd = cfg.cmd
  if cmd then
    if type(cmd) == "string" then
      return { cmd }
    end
    return cmd
  end

  local jls_dir = cfg.jls_dir or os.getenv("JLS_HOME") or os.getenv("JLS_DIR")
  if not jls_dir or jls_dir == "" then
    return nil, "jls_dir is not set (set config.jls_dir or JLS_HOME/JLS_DIR)"
  end

  local os_id = detect_os()
  local launcher = os_id == "windows"
      and joinpath(jls_dir, "dist", "lang_server_windows.cmd")
      or joinpath(jls_dir, "dist", "lang_server_" .. os_id .. ".sh")

  if vim.fn.filereadable(launcher) == 0 then
    return nil, "JLS launcher not found: " .. launcher
  end

  return { launcher }
end

local function build_cmd(cfg)
  local base, err = resolve_launcher(cfg)
  if not base then
    return nil, err
  end

  local cmd = vim.deepcopy(base)

  if cfg.lombok and cfg.lombok.path and cfg.lombok.path ~= "" then
    table.insert(cmd, "-Dorg.javacs.lombokPath=" .. cfg.lombok.path)
  end

  if cfg.lombok and cfg.lombok.javaagent and cfg.lombok.javaagent ~= "" then
    table.insert(cmd, "-javaagent:" .. cfg.lombok.javaagent)
  end

  for _, arg in ipairs(cfg.extra_args or {}) do
    table.insert(cmd, arg)
  end

  return cmd
end

local function build_env(cfg)
  local env = vim.tbl_deep_extend("force", {}, cfg.env or {})
  if cfg.java_home and cfg.java_home ~= "" then
    env.JAVA_HOME = cfg.java_home
  end
  return env
end

local function notify(msg, level)
  local ok = pcall(vim.notify, msg, level or vim.log.levels.INFO, { title = "jls" })
  if not ok then
    pcall(vim.notify, msg, level or vim.log.levels.INFO)
  end
end


local function get_clients_by_name(name)
  if vim.lsp.get_clients then
    return vim.lsp.get_clients({ name = name })
  end

  local clients = vim.lsp.get_active_clients()
  local filtered = {}
  for _, client in ipairs(clients) do
    if client.name == name then
      table.insert(filtered, client)
    end
  end
  return filtered
end


local status_state = { message = "", done = true }

local function set_status(msg, done)
  status_state.message = msg or ""
  status_state.done = done ~= false
end

local function statusline_text()
  if status_state.message == "" then
    return ""
  end
  return "[JLS] " .. status_state.message
end

local function wait_for_attach(cb)
  local group = vim.api.nvim_create_augroup("JlsAttachOnce", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and client.name == "jls" then
        vim.api.nvim_del_augroup_by_id(group)
        cb(true, client)
      end
    end,
    once = true,
  })

  vim.defer_fn(function()
    local ok, ac = pcall(vim.api.nvim_get_autocmds, { group = group })
    if not ok or not ac or #ac == 0 then
      return
    end
    pcall(vim.api.nvim_del_augroup_by_id, group)
    cb(false, nil)
  end, 30000)
end

---@param opts JlsConfig|nil
---@return table|nil
---@return string|nil
function M.make_lsp_config(opts)
  local cfg = vim.tbl_deep_extend("force", default_config(), M.config, opts or {})
  local cmd, err = build_cmd(cfg)
  if not cmd then
    return nil, err
  end

  return {
    name = "jls",
    cmd = cmd,
    filetypes = cfg.filetypes,
    root_dir = function(fname)
      return resolve_root(fname, cfg)
    end,
    settings = cfg.settings,
    init_options = cfg.init_options,
    cmd_env = build_env(cfg),
  }
end

---@param opts JlsConfig|nil
function M.start(opts)
  local lsp_config, err = M.make_lsp_config(opts)
  if not lsp_config then
    notify(err or "JLS configuration failed", vim.log.levels.ERROR)
    return
  end

  local root = lsp_config.root_dir
  if type(root) == "function" then
    root = root(vim.api.nvim_buf_get_name(0)) or vim.fn.getcwd()
  end
  for _, client in ipairs(get_clients_by_name("jls")) do
    if client.config and client.config.root_dir == root then
      return
    end
  end

  notify("JLS: starting...", vim.log.levels.INFO)
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

  wait_for_attach(function(ok)
    if ok then
      notify("JLS: started", vim.log.levels.INFO)
    else
      notify("JLS: start timed out (no attach)", vim.log.levels.WARN)
    end
  end)
end

function M.stop()
  local clients = get_clients_by_name("jls")
  if #clients == 0 then
    notify("JLS: no running clients", vim.log.levels.WARN)
    return
  end

  for _, client in ipairs(clients) do
    client:stop(true)
  end
  notify("JLS: stopped (" .. #clients .. " client)", vim.log.levels.INFO)
end

---@param opts JlsConfig|nil
function M.restart(opts)
  notify("JLS: restarting...", vim.log.levels.INFO)
  M.stop()
  M.start(opts)
end


local function cache_dir(root)
  local cache_home = os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")
  local safe = root:gsub("[/%s]", "_")
  return joinpath(cache_home, "jls", safe)
end

local function remove_dir(path)
  local ok = pcall(vim.fn.delete, path, "rf")
  return ok
end

function M.info()
  local cfg = vim.tbl_deep_extend("force", default_config(), M.config)
  local cmd, err = build_cmd(cfg)
  if not cmd then
    notify(err or "JLS command resolution failed", vim.log.levels.ERROR)
    return
  end

  local root = resolve_root(vim.api.nvim_buf_get_name(0), cfg)
  local lines = {
    "JLS",
    "root: " .. root,
    "cmd: " .. table.concat(cmd, " "),
  }
  notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end


function M.cache_clear()
  local cfg = vim.tbl_deep_extend("force", default_config(), M.config)
  local root = resolve_root(vim.api.nvim_buf_get_name(0), cfg)
  local dir = cache_dir(root)
  if vim.fn.isdirectory(dir) == 0 then
    notify("JLS cache not found: " .. dir, vim.log.levels.INFO)
    return
  end
  if remove_dir(dir) then
    notify("JLS cache removed: " .. dir, vim.log.levels.INFO)
  else
    notify("Failed to remove JLS cache: " .. dir, vim.log.levels.ERROR)
  end
end

function M.logs()
  local log_path = vim.lsp.get_log_path()
  if vim.fn.filereadable(log_path) == 0 then
    notify("LSP log not found: " .. log_path, vim.log.levels.WARN)
    return
  end
  vim.cmd("split " .. vim.fn.fnameescape(log_path))
end

function M.statusline()
  return statusline_text()
end

---@param args JlsConfig|nil
function M.setup(args)
  M.config = vim.tbl_deep_extend("force", default_config(), M.config, args or {})


  if M.config.status and M.config.status.enable then
    local group = vim.api.nvim_create_augroup("JlsStatus", { clear = true })
    vim.api.nvim_create_autocmd("LspProgress", {
      group = group,
      callback = function(ev)
        local value = ev.data and ev.data.params and ev.data.params.value or nil
        if type(value) == "table" then
          local title = value.title or ""
          local message = value.message or ""
          local percentage = value.percentage and (" " .. value.percentage .. "%%") or ""
          local text = (title .. " " .. message .. percentage):gsub("%s+", " "):gsub("^%s+", "")
          local done = value.kind == "end"
          set_status(text, done)
          if M.config.status.notify and text ~= "" then
            vim.notify("JLS: " .. text, vim.log.levels.INFO)
          end
        end
      end,
    })
  end
end

return M
