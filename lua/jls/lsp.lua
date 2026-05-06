local cmd = require("jls.cmd")
local config = require("jls.config")
local root = require("jls.root")
local util = require("jls.util")

local M = {}

local warned_roots = {}
local shown_server_messages = {}
local recent_server_messages = {}

local MAX_RECORDED_SERVER_MESSAGES = 20

local function find_client_for_root(root_dir)
  for _, client in ipairs(vim.lsp.get_clients({ name = "jls" })) do
    if client.config and client.config.root_dir == root_dir then
      return client
    end
  end
  return nil
end

local function get_lsp_log_path()
  local ok, path = pcall(vim.lsp.get_log_path)
  if ok then
    return path
  end
  return nil
end

local function record_server_message(root_dir, result)
  if not result or not result.message then
    return
  end
  table.insert(recent_server_messages, {
    root_dir = root_dir,
    type = result.type,
    message = result.message,
  })
  if #recent_server_messages > MAX_RECORDED_SERVER_MESSAGES then
    table.remove(recent_server_messages, 1)
  end
end

local function recent_messages_for_root(root_dir)
  local items = {}
  for i = #recent_server_messages, 1, -1 do
    local item = recent_server_messages[i]
    if item.root_dir == root_dir then
      table.insert(items, item)
    end
  end
  return items
end

local function recent_stderr_warnings(log_path, launcher)
  if not log_path or log_path == "" or not launcher or launcher == "" then
    return {}
  end
  local ok, lines = pcall(vim.fn.readfile, log_path)
  if not ok or type(lines) ~= "table" then
    return {}
  end

  local warnings = {}
  for i = #lines, 1, -1 do
    local line = lines[i]
    if line:find('"rpc"', 1, true)
        and line:find(launcher, 1, true)
        and line:find('"stderr"', 1, true)
        and line:find("WARNING", 1, true) then
      local payload = line:match([["stderr"%s+"(.*)"]]) or line
      payload = payload:gsub([[\n]], "\n")
      payload = payload:gsub([[\t]], "\t")
      payload = payload:gsub('\\"', '"')
      if not vim.tbl_contains(warnings, payload) then
        table.insert(warnings, payload)
      end
      if #warnings >= 5 then
        break
      end
    end
  end

  return warnings
end

function M.get_recent_server_messages(root_dir)
  return vim.deepcopy(recent_messages_for_root(root_dir))
end

function M.get_lsp_log_path()
  return get_lsp_log_path()
end

function M.get_recent_stderr_warnings(log_path, launcher)
  return vim.deepcopy(recent_stderr_warnings(log_path, launcher))
end

local function show_message_level(message_type)
  if message_type == vim.lsp.protocol.MessageType.Error then
    return vim.log.levels.ERROR
  elseif message_type == vim.lsp.protocol.MessageType.Warning then
    return vim.log.levels.WARN
  elseif message_type == vim.lsp.protocol.MessageType.Info then
    return vim.log.levels.INFO
  end
  return vim.log.levels.DEBUG
end

local function show_message_handler(root_dir)
  return function(err, result, ctx, handler_cfg)
    if err then
      return vim.lsp.handlers["window/showMessage"](err, result, ctx, handler_cfg)
    end
    if not result or not result.message then
      return
    end

    record_server_message(root_dir, result)

    if result.type == vim.lsp.protocol.MessageType.Warning then
      local key = table.concat({ root_dir or "", tostring(result.type), result.message }, "\0")
      if shown_server_messages[key] then
        return
      end
      shown_server_messages[key] = true
    end

    util.notify(result.message, show_message_level(result.type))
  end
end

---@param cfg JlsConfig
---@return table
local function build_settings(cfg)
  return vim.deepcopy(cfg.settings or {})
end

---@param bufnr integer
---@return boolean
local function is_decompiled_buffer(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name:find("jls-binary-decompiled", 1, true) ~= nil
    or name:find("jls-jar-sources", 1, true) ~= nil
end

---@param bufnr integer
---@param client table|nil
---@param cfg JlsConfig
local function on_attach(bufnr, client, cfg)
  if not client or client.name ~= "jls" then
    return
  end

  -- Decompiled / external-jar buffers: make readonly and skip all editing features.
  if is_decompiled_buffer(bufnr) then
    vim.bo[bufnr].readonly = true
    vim.bo[bufnr].modifiable = false
    return
  end

  -- Neovim's default pull-diagnostic trigger fires on every textDocument/didChange
  -- (debounced at ~150ms), causing a full javac compile on each keystroke.
  -- Clearing diagnosticProvider before vim.schedule runs the capability setup
  -- prevents Neovim from attaching its LspNotify/didChange → diagnostic pull
  -- machinery for this buffer entirely.
  client.server_capabilities.diagnosticProvider = nil

  local augroup = "JlsDiagnostics_" .. bufnr
  local group = vim.api.nvim_create_augroup(augroup, { clear = true })
  local ns = vim.lsp.diagnostic.get_namespace(client.id)

  local function request_diagnostics()
    -- client:request flushes pending didChange first so the server always
    -- compiles the current buffer content.
    -- We supply our own handler instead of nil: passing nil would route the
    -- response through Neovim's default textDocument/diagnostic handler, which
    -- expects internal bufstate that was never initialised (because we cleared
    -- diagnosticProvider above) and crashes with "attempt to index bufstate".
    client:request(
      "textDocument/diagnostic",
      { textDocument = vim.lsp.util.make_text_document_params(bufnr) },
      function(err, result)
        if err or not result or result.kind ~= "full" then
          return
        end
        local nvim_diags = {}
        for _, d in ipairs(result.items or {}) do
          table.insert(nvim_diags, {
            lnum = d.range.start.line,
            end_lnum = d.range["end"].line,
            col = d.range.start.character,
            end_col = d.range["end"].character,
            severity = d.severity,
            message = d.message,
            source = d.source,
            code = d.code,
            user_data = { lsp = d },
          })
        end
        vim.diagnostic.set(ns, bufnr, nvim_diags)
      end,
      bufnr
    )
  end

  local DEBOUNCE_MS = 500
  local timer = vim.uv.new_timer()

  -- Inlay hints state: defined before client_ready so request_hints is in scope.
  local request_hints
  if cfg.inlay_hints and cfg.inlay_hints.enabled then
    local hint_ns = vim.api.nvim_create_namespace("jls_inlay_hints_" .. bufnr)

    local function clear_hints()
      vim.api.nvim_buf_clear_namespace(bufnr, hint_ns, 0, -1)
    end

    local function apply_hints(hints)
      clear_hints()
      for _, hint in ipairs(hints) do
        local label = hint.label
        if hint.paddingRight then
          label = label .. " "
        end
        pcall(vim.api.nvim_buf_set_extmark, bufnr, hint_ns, hint.position.line, hint.position.character, {
          virt_text = { { label, "LspInlayHint" } },
          virt_text_pos = "inline",
          hl_mode = "combine",
        })
      end
    end

    local hint_pending = false
    local last_hint_file = nil
    local last_hint_tick = nil
    request_hints = function(opts)
      -- On BufEnter, skip re-requesting if the file and content haven't changed.
      if opts and opts.skip_if_unchanged then
        local current_file = vim.api.nvim_buf_get_name(bufnr)
        local current_tick = vim.b[bufnr].changedtick
        if current_file == last_hint_file and current_tick == last_hint_tick then
          return
        end
      end
      if hint_pending or not vim.api.nvim_buf_is_valid(bufnr) then return end
      hint_pending = true
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      client:request(
        "textDocument/inlayHint",
        {
          textDocument = vim.lsp.util.make_text_document_params(bufnr),
          range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = line_count, character = 0 },
          },
        },
        function(err, result)
          hint_pending = false
          if err or not result or not vim.api.nvim_buf_is_valid(bufnr) then return end
          apply_hints(result)
          last_hint_file = vim.api.nvim_buf_get_name(bufnr)
          last_hint_tick = vim.b[bufnr].changedtick
        end,
        bufnr
      )
    end
  end

  -- on_attach IS the client-ready signal. Register autocmds and fire initial
  -- requests here directly — no vim.schedule needed.
  local function client_ready()
    vim.api.nvim_create_autocmd("TextChanged", {
      group = group,
      buffer = bufnr,
      callback = function()
        timer:stop()
        timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(request_diagnostics))
      end,
    })
    vim.api.nvim_create_autocmd({ "InsertLeave", "BufWritePost" }, {
      group = group,
      buffer = bufnr,
      callback = request_diagnostics,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      buffer = bufnr,
      callback = function()
        local win = vim.api.nvim_get_current_win()
        if vim.api.nvim_win_get_config(win).relative ~= "" then return end
        request_diagnostics()
      end,
    })

    if request_hints then
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      local root_dir = client.root_dir or ""
      if bufname:sub(1, #root_dir) == root_dir then
        vim.api.nvim_create_autocmd("InsertLeave", {
          group = group,
          buffer = bufnr,
          callback = request_hints,
        })
        vim.api.nvim_create_autocmd("BufEnter", {
          group = group,
          buffer = bufnr,
          callback = function()
            local win = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_get_config(win).relative ~= "" then return end
            if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
              request_hints({ skip_if_unchanged = true })
            end
          end,
        })
      end
    end

    request_diagnostics()
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local root_dir = client.root_dir or ""
    if request_hints and bufname:sub(1, #root_dir) == root_dir then
      request_hints()
    end
  end

  client_ready()

  -- Clean up timer and autocmds when jls detaches from this buffer.
  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function(ev)
      if ev.data.client_id == client.id then
        if not timer:is_closing() then
          timer:stop()
          timer:close()
        end
        pcall(vim.api.nvim_del_augroup_by_name, augroup)
      end
    end,
  })
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
    handlers = {
      ["window/showMessage"] = show_message_handler(root_dir),
    },
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
---@param control? { notify?: boolean }
function M.start(state, opts, control)
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
        if control and control.notify then
          util.notify("JLS: started", vim.log.levels.INFO)
        end
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
---@param control? { notify?: boolean }
function M.restart(state, opts, control)
  local target_bufnr = vim.api.nvim_get_current_buf()
  M.stop(state)

  local attempts = 0
  local max_attempts = 50

  local function restart_when_stopped()
    if #vim.lsp.get_clients({ name = "jls" }) > 0 and attempts < max_attempts then
      attempts = attempts + 1
      vim.defer_fn(restart_when_stopped, 100)
      return
    end

    if vim.api.nvim_buf_is_valid(target_bufnr) then
      vim.api.nvim_buf_call(target_bufnr, function()
        M.start(state, opts, control)
      end)
      return
    end

    M.start(state, opts, control)
  end

  vim.defer_fn(restart_when_stopped, 100)
end

function M.open_log()
  local log_path = get_lsp_log_path()
  if not log_path or log_path == "" then
    util.notify("JLS: Neovim LSP log path is unavailable", vim.log.levels.ERROR)
    return
  end
  if vim.fn.filereadable(log_path) == 0 then
    util.notify("JLS: LSP log not found: " .. log_path, vim.log.levels.ERROR)
    return
  end

  vim.cmd("botright split " .. vim.fn.fnameescape(log_path))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
end

return M
