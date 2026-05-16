local cmd = require("jls.cmd")
local config = require("jls.config")
local installer = require("jls.installer")
local lsp = require("jls.lsp")
local root = require("jls.root")

local M = {}

local health = vim.health
if not health then
  health = require("health")
end

local function start(section)
  health.start(section)
end

local function ok(msg)
  health.ok(msg)
end

local function warn(msg, advice)
  health.warn(msg, advice)
end

local function err(msg, advice)
  health.error(msg, advice)
end

local function info(msg)
  health.info(msg)
end

local function is_file_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= nil and name ~= ""
end

local function is_java_buffer(bufnr)
  return is_file_buffer(bufnr) and vim.bo[bufnr].filetype == "java"
end

local function build_context(bufnr, cfg)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local details = root.resolve_root_details(bufname, cfg)
  return {
    bufnr = bufnr,
    bufname = bufname,
    root = details.root_dir,
    fallback = details.fallback,
    marker = details.marker,
    roots = { details.root_dir },
    source = "current buffer",
  }
end

local function first_attached_java_buffer(client)
  if not client or type(client.attached_buffers) ~= "table" then
    return nil
  end
  for bufnr, attached in pairs(client.attached_buffers) do
    if attached and is_java_buffer(bufnr) then
      return bufnr
    end
  end
  return nil
end

local function current_context(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  if is_java_buffer(bufnr) then
    return build_context(bufnr, cfg)
  end

  local running = vim.lsp.get_clients({ name = "jls" })
  local roots = {}
  for _, client in ipairs(running) do
    if client.root_dir and not vim.tbl_contains(roots, client.root_dir) then
      table.insert(roots, client.root_dir)
    end
    local attached_bufnr = first_attached_java_buffer(client)
    if attached_bufnr then
      local ctx = build_context(attached_bufnr, cfg)
      ctx.roots = roots
      ctx.source = "attached java buffer"
      return ctx
    end
  end

  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if is_java_buffer(candidate) then
      local ctx = build_context(candidate, cfg)
      ctx.roots = roots
      ctx.source = "java buffer"
      return ctx
    end
  end

  local ctx = build_context(bufnr, cfg)
  ctx.roots = roots
  return ctx
end

local function check_config(cfg, ctx)
  start("Configuration")

  local managed_dir = installer.managed_install_dir()
  local installed_ver = installer.installed_version()
  local using_managed = cfg.jls_dir == managed_dir or cfg.jls_dir == vim.fn.expand(managed_dir)

  if installed_ver then
    ok("managed install: " .. managed_dir .. " (version " .. installed_ver .. ")")
  elseif using_managed then
    warn("JLS is not installed", {
      "Run :JlsInstall to download and install the latest release.",
    })
  else
    info("managed install not in use (jls_dir is user-configured)")
  end

  if cfg.jls_dir and cfg.jls_dir ~= "" then
    if using_managed then
      ok("jls_dir: " .. cfg.jls_dir .. " (managed)")
    else
      ok("jls_dir: " .. cfg.jls_dir .. " (user-configured)")
    end
  else
    err("jls_dir is not set", {
      'Run :JlsInstall, or configure `require("jls").setup({ jls_dir = "/path/to/jls" })`.',
    })
  end

  if type(cfg.root_markers) == "table" and #cfg.root_markers > 0 then
    ok("root markers configured: " .. table.concat(cfg.root_markers, ", "))
  else
    err("root_markers is empty", {
      "Configure at least one marker such as pom.xml or build.gradle.",
    })
  end

  if ctx.bufname ~= "" then
    info(string.format("buffer (%s): %s", ctx.source, ctx.bufname))
  else
    info("buffer: <unnamed>")
  end
end

local function check_root(ctx)
  start("Workspace Root")

  if ctx.fallback then
    warn("root markers not found; using cwd: " .. ctx.root, {
      "Open a Java file inside a Maven/Gradle/Bazel project root, or extend `root_markers`.",
    })
  else
    local marker = ctx.marker and (" via " .. ctx.marker) or ""
    ok("resolved root: " .. ctx.root .. marker)
  end

  if vim.bo[ctx.bufnr].filetype == "java" then
    ok("current buffer filetype is java")
  else
    warn("current buffer filetype is `" .. vim.bo[ctx.bufnr].filetype .. "`", {
      "Run `:checkhealth jls` from a Java buffer for the most relevant results.",
    })
  end
end

local function check_launcher(cfg)
  start("Launcher")

  local launcher, launcher_err = cmd.resolve_launcher(cfg)
  if not launcher then
    err(launcher_err or "unable to resolve launcher")
    return nil
  end

  ok("launcher found: " .. launcher)

  if cmd.is_executable(launcher) then
    ok("launcher is executable")
  else
    err("launcher is not executable: " .. launcher, {
      "Run `chmod +x " .. launcher .. "`.",
    })
  end

  return launcher
end

local function check_clients(ctx, launcher)
  start("LSP Runtime")

  local attached = vim.lsp.get_clients({ bufnr = ctx.bufnr, name = "jls" })
  local running = vim.lsp.get_clients({ name = "jls" })

  if #attached > 0 then
    ok("attached JLS client(s): " .. #attached)
  else
    warn("no JLS client attached to the current buffer", {
      "Open a Java buffer and run `:JlsStart` if autostart has not attached.",
    })
  end

  if #running > 0 then
    ok("running JLS client(s): " .. #running)
  else
    warn("no running JLS clients found", {
      "Start JLS with `:JlsStart` and re-run `:checkhealth jls`.",
    })
  end

  local message_roots = vim.deepcopy(ctx.roots or {})
  if ctx.root and not vim.tbl_contains(message_roots, ctx.root) then
    table.insert(message_roots, ctx.root)
  end

  local recent_messages = {}
  local seen_messages = {}
  for _, root_dir in ipairs(message_roots) do
    for _, item in ipairs(lsp.get_recent_server_messages(root_dir)) do
      local key = table.concat({ tostring(item.type), item.message }, "\0")
      if not seen_messages[key] then
        seen_messages[key] = true
        table.insert(recent_messages, item)
      end
    end
  end

  if #recent_messages == 0 then
    ok("no `window/showMessage` warnings recorded for inspected JLS roots in the current session")
  else
    for _, item in ipairs(recent_messages) do
      local text = "server message: " .. item.message
      if item.type == vim.lsp.protocol.MessageType.Error then
        err(text)
      elseif item.type == vim.lsp.protocol.MessageType.Warning then
        warn(text)
      else
        info(text)
      end
    end
  end

  local log_path = lsp.get_lsp_log_path()
  if log_path and log_path ~= "" then
    info("lsp log: " .. log_path)
  else
    warn("could not determine Neovim LSP log path")
  end

  local stderr_warnings = lsp.get_recent_stderr_warnings(log_path, launcher)
  if #stderr_warnings == 0 then
    ok("no recent JLS stderr warnings found in the LSP log")
  else
    for _, message in ipairs(stderr_warnings) do
      warn("JLS stderr warning: " .. message)
    end
  end
end

local function check_optional_integrations()
  start("Optional Integrations")

  local ok_lspconfig = pcall(require, "lspconfig")
  if ok_lspconfig then
    ok("nvim-lspconfig is installed")
  else
    info("nvim-lspconfig not installed; plugin will use `vim.lsp.start()` directly")
  end

  local ok_snacks, snacks = pcall(require, "snacks")
  if ok_snacks and snacks.notify then
    ok("snacks.nvim notify integration is available")
  else
    info("snacks.nvim notify integration not available; using `vim.notify`")
  end
end

function M.check()
  local cfg = config.merge(require("jls").config)
  local ctx = current_context(cfg)
  local launcher = check_launcher(cfg)

  check_config(cfg, ctx)
  check_root(ctx)
  check_clients(ctx, launcher)
  check_optional_integrations()
end

return M
