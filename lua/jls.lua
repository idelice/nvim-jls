local uv = vim.loop

---@class JlsLombokConfig
---@field path string|nil Path to lombok.jar
---@field javaagent string|nil Path to lombok javaagent jar
---@field search_paths string[]|nil Extra paths/globs to search for lombok.jar

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
---@field codelens { enable: boolean }

---@class JlsModule
local M = {}

local warned_roots = {}
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
    lombok = { path = nil, javaagent = nil, search_paths = nil },
    extra_args = {},
    status = { enable = true, notify = false },
    codelens = { enable = false },
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

local function resolve_root_info(fname, cfg)
  local path = fname or vim.api.nvim_buf_get_name(0)
  local cwd = vim.fn.getcwd()
  if path == "" then
    return cwd, true
  end

  if vim.fs and vim.fs.find then
    local found = vim.fs.find(cfg.root_markers, { path = path, upward = true })
    if found and found[1] then
      return vim.fs.dirname(found[1]), false
    end
  end

  local ok, util = pcall(require, "lspconfig.util")
  if ok then
    local root = util.root_pattern(unpack(cfg.root_markers))(path)
    if root then
      return root, false
    end
  end

  return cwd, true
end

local function resolve_root(fname, cfg)
  local root = resolve_root_info(fname, cfg)
  return root
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

local function workspace_cache_root()
  local cache_home = os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")
  return joinpath(cache_home, "nvim-jls")
end

local function workspace_cache_dir(root)
  local name = vim.fn.fnamemodify(root, ":t")
  if name == nil or name == "" then
    name = root:gsub("[/%s]", "_")
  end
  return joinpath(workspace_cache_root(), name)
end

local function workspace_cache_path(root)
  return joinpath(workspace_cache_dir(root), "config.json")
end

local function read_workspace_cache(root)
  local path = workspace_cache_path(root)
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

local function write_workspace_cache(root, cache)
  local path = workspace_cache_path(root)
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

local function apply_workspace_cache(cfg, root)
  local entry = read_workspace_cache(root)
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

local function update_workspace_cache(root, cfg)
  local entry = {
    jls_dir = cfg.jls_dir,
    java_home = cfg.java_home,
    lombok_path = cfg.lombok and cfg.lombok.path or nil,
    lombok_javaagent = cfg.lombok and cfg.lombok.javaagent or nil,
  }
  write_workspace_cache(root, entry)
end

local function pick_latest_path(paths)
  if not paths or #paths == 0 then
    return nil
  end
  table.sort(paths)
  return paths[#paths]
end

local function find_lombok_in_paths(paths)
  if not paths then
    return nil
  end
  for _, p in ipairs(paths) do
    if type(p) == "string" and p ~= "" then
      if p:match("%.jar$") and vim.fn.filereadable(p) == 1 then
        return p
      end
      local matches = vim.fn.glob(p, 1, 1)
      if matches and #matches > 0 then
        local jar = pick_latest_path(matches)
        if jar and vim.fn.filereadable(jar) == 1 then
          return jar
        end
      end
      local globbed = vim.fn.globpath(p, "**/lombok-*.jar", 1, 1)
      if globbed and #globbed > 0 then
        local jar = pick_latest_path(globbed)
        if jar and vim.fn.filereadable(jar) == 1 then
          return jar
        end
      end
    end
  end
  return nil
end

local function detect_lombok(cfg)
  cfg.lombok = cfg.lombok or {}
  if cfg.lombok.path and cfg.lombok.path ~= "" then
    return cfg
  end
  local env_path = os.getenv("LOMBOK_PATH")
  if env_path and env_path ~= "" and vim.fn.filereadable(env_path) == 1 then
    cfg.lombok.path = env_path
    return cfg
  end

  local search = cfg.lombok.search_paths or {}
  local found = find_lombok_in_paths(search)
  if found then
    cfg.lombok.path = found
    return cfg
  end

  local home = os.getenv("HOME")
  if home and home ~= "" then
    local m2 = joinpath(home, ".m2", "repository", "org", "projectlombok", "lombok", "*", "lombok-*.jar")
    local m2_hits = vim.fn.glob(m2, 1, 1)
    local m2_found = pick_latest_path(m2_hits)
    if m2_found and vim.fn.filereadable(m2_found) == 1 then
      cfg.lombok.path = m2_found
      return cfg
    end
  end
  return cfg
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


local function normalize_path(path)
  if not path or path == "" then
    return nil
  end
  local real = vim.loop.fs_realpath(path)
  return real or path
end

local function path_has_prefix(path, prefix)
  local norm_path = normalize_path(path)
  local norm_prefix = normalize_path(prefix)
  if not norm_path or not norm_prefix then
    return false
  end
  if norm_path == norm_prefix then
    return true
  end
  return norm_path:sub(1, #norm_prefix + 1) == norm_prefix .. "/"
end

local function resolve_client_root(client, bufname)
  local root = client and client.config and client.config.root_dir or nil
  if type(root) == "function" then
    root = root(bufname)
  end
  if not root or root == "" then
    root = client and client.root_dir or nil
  end
  return root
end

local function buffer_matches_client(client, bufname, root)
  local client_root = resolve_client_root(client, bufname)
  if client_root and path_has_prefix(bufname, client_root) then
    return true
  end
  if root and client_root and path_has_prefix(root, client_root) then
    return true
  end
  if client.workspace_folders then
    for _, folder in ipairs(client.workspace_folders) do
      local folder_path = folder.uri and vim.uri_to_fname(folder.uri) or folder.name
      if folder_path and path_has_prefix(bufname, folder_path) then
        return true
      end
    end
  end
  return false
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
  local root, _ = resolve_root_info(vim.api.nvim_buf_get_name(0), cfg)
  cfg = apply_workspace_cache(cfg, root)
  cfg = detect_lombok(cfg)
  local cmd, err = build_cmd(cfg)
  if not cmd then
    return nil, err
  end

  M._last_resolved_cfg = cfg
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
  local bufnr = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  for _, client in ipairs(get_clients_by_name("jls")) do
    if client.attached_buffers and client.attached_buffers[bufnr] then
      return
    end
    if buffer_matches_client(client, bufname, root) then
      pcall(vim.lsp.buf_attach_client, bufnr, client.id)
      return
    end
  end

  local _, fallback = resolve_root_info(vim.api.nvim_buf_get_name(0), M.config)
  if fallback and not warned_roots[root] then
    warned_roots[root] = true
    notify("JLS: root markers not found; using cwd: " .. root, vim.log.levels.WARN)
  end

  update_workspace_cache(root, M._last_resolved_cfg or vim.tbl_deep_extend("force", default_config(), M.config, opts or {}))
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

  local root, fallback = resolve_root_info(vim.api.nvim_buf_get_name(0), cfg)
  local lines = {
    "JLS",
    "root: " .. root,
    fallback and "root-warning: markers not found, using cwd" or "root-warning: none",
    "cmd: " .. table.concat(cmd, " "),
  }
  notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

function M.doctor()
  local cfg = vim.tbl_deep_extend("force", default_config(), M.config)
  local root, fallback = resolve_root_info(vim.api.nvim_buf_get_name(0), cfg)
  cfg = apply_workspace_cache(cfg, root)
  cfg = detect_lombok(cfg)
  local cmd, err = build_cmd(cfg)
  local lines = {
    "JLS Doctor",
    "root: " .. root,
    fallback and "root-warning: markers not found, using cwd" or "root-warning: none",
    "jls_dir: " .. tostring(cfg.jls_dir),
    "java_home: " .. tostring(cfg.java_home),
    "lombok.path: " .. tostring(cfg.lombok and cfg.lombok.path or nil),
    "lombok.javaagent: " .. tostring(cfg.lombok and cfg.lombok.javaagent or nil),
    "settings: " .. vim.inspect(cfg.settings),
  }
  if cmd then
    table.insert(lines, "cmd: " .. table.concat(cmd, " "))
  else
    table.insert(lines, "cmd: <error> " .. (err or "unknown"))
  end
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

function M.cache_clear_restart()
  M.cache_clear()
  M.restart()
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

  if M.config.codelens and M.config.codelens.enable then
    local group = vim.api.nvim_create_augroup("JlsCodeLens", { clear = true })

    local function has_jls(bufnr)
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if client.name == "jls" then
          return true
        end
      end
      return false
    end

    local function refresh(bufnr)
      if not has_jls(bufnr) then
        return
      end
      if vim.lsp.codelens and vim.lsp.codelens.refresh then
        vim.lsp.codelens.refresh({ bufnr = bufnr })
      end
    end

    vim.api.nvim_create_autocmd("LspAttach", {
      group = group,
      callback = function(ev)
        if ev.buf and vim.bo[ev.buf].filetype == "java" then
          refresh(ev.buf)
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "BufEnter" }, {
      group = group,
      callback = function(ev)
        if ev.buf and vim.bo[ev.buf].filetype == "java" then
          refresh(ev.buf)
        end
      end,
    })
  end


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
