local cmd = require("jls.cmd")
local config = require("jls.config")
local root = require("jls.root")
local util = require("jls.util")

local M = {}

-- Pending params from a `java/renameFile` notification, consumed by the
-- `textDocument/rename` response handler to ensure the disk rename happens
-- AFTER the WorkspaceEdit is applied to all buffers.
-- Keyed by client_id to avoid cross-client interference in multi-root workspaces.
local _pending_java_rename = {}

-- Run the picker and generate accessor methods.
-- Works for both the workspace/executeCommand response path (nvim ≤0.10)
-- and the exec_cmd patch path (nvim ≥0.11).
-- `client`  – the JLS client object
-- `className`, `methodKind` – from the pickFields payload
-- `fieldStr` – comma-separated list of field names
local function pick_and_generate(client, className, methodKind, fieldStr)
  local fields = {}
  for f in tostring(fieldStr):gmatch("[^,]+") do
    table.insert(fields, vim.trim(f))
  end
  if #fields == 0 then
    return
  end

  local function generate(selected_fields)
    if not selected_fields then
      return
    end
    -- For non-constructor kinds, require at least one field selected.
    if #selected_fields == 0 and methodKind ~= "constructor" then
      return
    end
    local buf = vim.api.nvim_get_current_buf()
    vim.lsp.buf_request(buf, "workspace/executeCommand", {
      command = "java.generateFields",
      arguments = { className, methodKind, table.concat(selected_fields, ",") },
    }, function(gen_err, gen_result)
      if gen_err then
        vim.notify("[jls] generateFields failed: " .. tostring(gen_err.message or gen_err), vim.log.levels.ERROR)
        return
      end
      if gen_result then
        vim.lsp.util.apply_workspace_edit(gen_result, client and client.offset_encoding or "utf-8")
      end
    end)
  end

  -- Prefer snacks multi-select picker, fall back to numbered echo + vim.ui.input.
  -- snacks.picker.select always calls on_choice with a single item; use pick()
  -- directly so we can read picker:selected({fallback=true}) on confirm.
  local snacks = package.loaded["snacks"]
  if snacks and snacks.picker and type(snacks.picker.pick) == "function" then
    local done = false
    snacks.picker.pick({
      source = "select",
      title = ("Generate %s  <Tab> select  <CR> done"):format(methodKind),
      finder = function()
        local ret = {}
        for i, field in ipairs(fields) do
          ret[i] = { text = field, item = field, idx = i }
        end
        return ret
      end,
      format = function(item)
        return { { item.text, "Normal" } }
      end,
      actions = {
        confirm = function(picker, _item)
          if done then
            return
          end
          done = true
          -- Only use fallback (cursor item) for non-constructor kinds.
          -- For constructor, no explicit selection means no-arg constructor.
          local sel = picker:selected({ fallback = methodKind ~= "constructor" })
          picker:close()
          vim.schedule(function()
            local result_fields = {}
            for _, s in ipairs(sel) do
              table.insert(result_fields, s.item)
            end
            generate(result_fields)
          end)
        end,
      },
    })
  else
    -- Build float lines
    local float_lines = { ("  Generate %s"):format(methodKind), "" }
    for i, f in ipairs(fields) do
      table.insert(float_lines, string.format("  %d.  %s", i, f))
    end
    table.insert(float_lines, "")
    table.insert(float_lines, "  Type numbers (e.g. 1,3) or 'all'")

    local float_w = 0
    for _, l in ipairs(float_lines) do
      float_w = math.max(float_w, #l)
    end
    float_w = float_w + 2

    local float_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, float_lines)

    local float_win = vim.api.nvim_open_win(float_buf, false, {
      relative = "editor",
      row = math.floor((vim.o.lines - #float_lines) / 2),
      col = math.floor((vim.o.columns - float_w) / 2),
      width = float_w,
      height = #float_lines,
      style = "minimal",
      border = "rounded",
      noautocmd = true,
    })

    local function close_float()
      if vim.api.nvim_win_is_valid(float_win) then
        vim.api.nvim_win_close(float_win, true)
      end
      if vim.api.nvim_buf_is_valid(float_buf) then
        vim.api.nvim_buf_delete(float_buf, { force = true })
      end
    end

    vim.ui.input({ prompt = "Fields (e.g. 1,3 or all): " }, function(input)
      close_float()
      if not input then
        return
      end
      if vim.trim(input) == "" then
        generate({})
        return
      end
      local selected = {}
      if vim.trim(input) == "all" then
        for _, f in ipairs(fields) do
          table.insert(selected, f)
        end
      else
        for token in input:gmatch("[^,]+") do
          local idx = tonumber(vim.trim(token))
          if idx and fields[idx] then
            table.insert(selected, fields[idx])
          end
        end
      end
      generate(selected)
    end)
  end
end

local warned_roots = {}
local shown_server_messages = {}
local recent_server_messages = {}

-- Auto-restart backoff state, keyed by root_dir
local auto_restart_attempts = {}
local AUTO_RESTART_MAX = 3
local AUTO_RESTART_DELAYS = { 1000, 3000, 10000 } -- ms
local AUTO_RESTART_RESET_UPTIME = 60 -- seconds: reset counter if server ran this long

local MAX_RECORDED_SERVER_MESSAGES = 20

--- Walk up from path to find the multi-module build root (settings.gradle or pom.xml with <modules>).
local function find_build_root(path)
  local dir = path
  while dir and dir ~= "/" do
    if vim.fn.filereadable(dir .. "/settings.gradle") == 1
        or vim.fn.filereadable(dir .. "/settings.gradle.kts") == 1 then
      return dir
    end
    local pom = dir .. "/pom.xml"
    if vim.fn.filereadable(pom) == 1 then
      local content = vim.fn.readfile(pom, "", 50)
      for _, line in ipairs(content) do
        if line:find("<modules>") then return dir end
      end
    end
    dir = vim.fn.fnamemodify(dir, ":h")
  end
  return nil
end

local function find_client_for_root(root_dir)
  for _, client in ipairs(vim.lsp.get_clients({ name = "jls" })) do
    if client.config and client.config.root_dir then
      local client_root = client.config.root_dir
      -- Exact match
      if client_root == root_dir then
        return client
      end
      -- Same multi-module project: both roots share a common ancestor with settings.gradle
      -- or a pom.xml containing <modules>.
      local client_build_root = find_build_root(client_root)
      local new_build_root = find_build_root(root_dir)
      if client_build_root and client_build_root == new_build_root then
        return client
      end
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
    if
      line:find('"rpc"', 1, true)
      and line:find(launcher, 1, true)
      and line:find('"stderr"', 1, true)
      and line:find("WARNING", 1, true)
    then
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
  return name:find("jls-binary-decompiled", 1, true) ~= nil or name:find("jls-jar-sources", 1, true) ~= nil
end

---@param bufnr integer
---@param client table|nil
---@param cfg JlsConfig
local function on_attach(bufnr, client, cfg)
  if not client or client.name ~= "jls" then
    return
  end

  -- Patch exec_cmd to intercept java.pickAndGenerate before it is sent to the
  -- server, so we can show the picker and issue java.generateFields ourselves.
  -- exec_cmd provides its own callback to client:request, which would otherwise
  -- swallow the server response without routing it through any handler.
  if not client._jls_exec_cmd_patched and type(client.exec_cmd) == "function" then
    client._jls_exec_cmd_patched = true
    local orig_exec_cmd = client.exec_cmd
    client.exec_cmd = function(self, command, opts, handler)
      if command.command == "java.pickAndGenerate" then
        local args = command.arguments
        pick_and_generate(self, args and args[1], args and args[2], args and args[3])
        return
      end
      return orig_exec_cmd(self, command, opts, handler)
    end
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
    client:request(
      "textDocument/diagnostic",
      { textDocument = vim.lsp.util.make_text_document_params(bufnr) },
      function(err, result)
        local items = result.items or {}
        local nvim_diags = {}
        for _, d in ipairs(items) do
          local diag_tags = nil
          if d.tags then
            diag_tags = {}
            for _, tag in ipairs(d.tags) do
              if tag == 1 then diag_tags.unnecessary = true end
              if tag == 2 then diag_tags.deprecated = true end
            end
          end
          table.insert(nvim_diags, {
            lnum = d.range.start.line,
            end_lnum = d.range["end"].line,
            col = d.range.start.character,
            end_col = d.range["end"].character,
            severity = d.severity,
            message = d.message,
            source = d.source,
            code = d.code,
            _tags = diag_tags,
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
      if hint_pending or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      hint_pending = true
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      client:request("textDocument/inlayHint", {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = line_count, character = 0 },
        },
      }, function(err, result)
        hint_pending = false
        if err or not result or not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        apply_hints(result)
        last_hint_file = vim.api.nvim_buf_get_name(bufnr)
        last_hint_tick = vim.b[bufnr].changedtick
      end, bufnr)
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
    vim.api.nvim_create_autocmd("InsertLeave", {
      group = group,
      buffer = bufnr,
      callback = request_diagnostics,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      buffer = bufnr,
      callback = function()
        timer:stop()
        timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(request_diagnostics))
      end,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      buffer = bufnr,
      callback = function()
        local win = vim.api.nvim_get_current_win()
        if vim.api.nvim_win_get_config(win).relative ~= "" then
          return
        end
        request_diagnostics()
      end,
    })
    -- Re-pull diagnostics when server signals background compile is done
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "JlsDiagnosticRefresh",
      callback = function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          request_diagnostics()
        end
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
            if vim.api.nvim_win_get_config(win).relative ~= "" then
              return
            end
            if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
              request_hints({ skip_if_unchanged = true })
            end
          end,
        })
      end
    end

    request_diagnostics()
  end

  client_ready()

  -- Listen for the initial workspace index completion to trigger first diagnostics.
  -- Fires only once (the first "Index ready" after attach), then removes itself.
  local index_ready_group = vim.api.nvim_create_augroup("JlsIndexReady_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("LspProgress", {
    group = index_ready_group,
    callback = function(ev)
      if ev.data and ev.data.client_id == client.id then
        local val = ev.data.params and ev.data.params.value
        if val and val.kind == "end" and val.message == "Index ready" then
          request_diagnostics()
          if request_hints then
            request_hints()
          end
          pcall(vim.api.nvim_del_augroup_by_name, "JlsIndexReady_" .. bufnr)
          return true
        end
      end
    end,
  })

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

  local lsp_cfg = {
    name = "jls",
    cmd = cmdline,
    cmd_env = cmd_env,
    handlers = {
      ["window/showMessage"] = show_message_handler(root_dir),
      ["workspace/diagnostic/refresh"] = function(_, _, _)
        -- Server finished background compile — trigger diagnostic refresh for all JLS buffers
        vim.api.nvim_exec_autocmds("User", { pattern = "JlsDiagnosticRefresh" })
        return vim.NIL
      end,
      ["java/renameFile"] = function(_, result, ctx)
        if not result or not result.oldPath or not result.newPath then
          return
        end
        _pending_java_rename[ctx.client_id] = result
      end,
      ["textDocument/rename"] = function(err, result, ctx)
        if err then
          vim.notify("Rename failed: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        if not result then
          vim.notify("Language server couldn't provide rename result", vim.log.levels.INFO)
          return
        end
        local client = vim.lsp.get_client_by_id(ctx.client_id)
        if not client then
          return
        end
        vim.lsp.util.apply_workspace_edit(result, client.offset_encoding)
        local pending = _pending_java_rename[ctx.client_id]
        _pending_java_rename[ctx.client_id] = nil
        if pending then
          vim.schedule(function()
            require("jls.commands").handle_rename_file(pending)
          end)
        end
      end,
    },
    on_attach = function(client, bufnr)
      on_attach(bufnr, client, cfg)
    end,
    root_dir = function(fname)
      local module_root = root.resolve_root(fname, cfg)
      return find_build_root(module_root) or module_root
    end,
    settings = build_settings(cfg),
  }

  if cfg.auto_restart then
    local start_time = vim.uv.now()
    lsp_cfg.on_exit = function(code, signal)
      -- clean exit → don't restart
      if code == 0 and signal == 0 then
        auto_restart_attempts[root_dir] = nil
        return
      end
      local uptime = (vim.uv.now() - start_time) / 1000
      local attempts = auto_restart_attempts[root_dir] or 0
      if uptime > AUTO_RESTART_RESET_UPTIME then
        attempts = 0
      end
      if attempts >= AUTO_RESTART_MAX then
        util.notify(
          ("JLS: crashed (code=%d); giving up after %d restart attempts"):format(code, AUTO_RESTART_MAX),
          vim.log.levels.ERROR
        )
        auto_restart_attempts[root_dir] = nil
        return
      end
      local delay = AUTO_RESTART_DELAYS[attempts + 1] or AUTO_RESTART_DELAYS[#AUTO_RESTART_DELAYS]
      attempts = attempts + 1
      auto_restart_attempts[root_dir] = attempts
      util.notify(
        ("JLS: crashed (code=%d); restarting in %.1fs (attempt %d/%d)"):format(
          code,
          delay / 1000,
          attempts,
          AUTO_RESTART_MAX
        ),
        vim.log.levels.WARN
      )
      vim.defer_fn(function()
        M.start(state, opts)
      end, delay)
    end
  end

  state._last_resolved_cfg = cfg
  return lsp_cfg
end

---@param state table
---@param opts JlsConfig|nil
---@param control? { notify?: boolean }
function M.start(state, opts, control)
  local lsp_config, err = M.make_lsp_config(state, opts)
  if not lsp_config then
    return nil, err
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

  -- If no root markers found, attach to any existing JLS client rather than spawning
  -- a new server. This prevents new server instances for decompiled/external files.
  if fallback then
    local any_jls = vim.lsp.get_clients({ name = "jls" })
    if #any_jls > 0 then
      pcall(vim.lsp.buf_attach_client, bufnr, any_jls[1].id)
      return
    end
  end

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
