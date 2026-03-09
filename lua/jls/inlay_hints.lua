local client_mod = require("jls.client")

local api = vim.api
local lsp_util = vim.lsp.util
local ms = vim.lsp.protocol.Methods

local M = {}

local namespace = api.nvim_create_namespace("jls.inlay_hints")
local states = {}

local function format_range(range)
  if not range then
    return "none"
  end
  return string.format(
    "%d:%d-%d:%d",
    range.start.line,
    range.start.character,
    range["end"].line,
    range["end"].character
  )
end

local function state_for(bufnr)
  local state = states[bufnr]
  if state then
    return state
  end
  state = {
    enabled = false,
    seq = 0,
    initial_done = false,
    insert_suspended = false,
    last_request_kind = nil,
    last_request_range = nil,
  }
  states[bufnr] = state
  return state
end

local function same_range(a, b)
  if not a or not b then
    return false
  end
  return a.start.line == b.start.line
    and a.start.character == b.start.character
    and a["end"].line == b["end"].line
    and a["end"].character == b["end"].character
end

local function clear_range(bufnr, range)
  if not api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local start_line = 0
  local end_line = -1
  if range then
    start_line = math.max(range.start.line, 0)
    end_line = math.max(range["end"].line + 1, start_line + 1)
  end
  api.nvim_buf_clear_namespace(bufnr, namespace, start_line, end_line)
end

local function clear_all(bufnr)
  clear_range(bufnr, nil)
end

local function supports_inlay_hints(client)
  if not client or client.name ~= "jls" then
    return false
  end
  return client.server_capabilities
      and client.server_capabilities.inlayHintProvider ~= nil
end

local function full_file_range(bufnr)
  local line_count = api.nvim_buf_line_count(bufnr)
  local end_line = math.max(line_count - 1, 0)
  local last_line = api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)[1] or ""
  return {
    start = { line = 0, character = 0 },
    ["end"] = { line = end_line, character = #last_line },
  }
end

local function visible_range(bufnr)
  local top_line
  local bottom_line
  for _, winid in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(winid) and api.nvim_win_get_buf(winid) == bufnr then
      local info = vim.fn.getwininfo(winid)[1]
      if info then
        local topline = math.max((info.topline or 1) - 1, 0)
        local botline = math.max((info.botline or info.topline or 1) - 1, topline)
        if not top_line or topline < top_line then
          top_line = topline
        end
        if not bottom_line or botline > bottom_line then
          bottom_line = botline
        end
      end
    end
  end
  if top_line == nil or bottom_line == nil then
    return full_file_range(bufnr)
  end
  local last_line = api.nvim_buf_get_lines(bufnr, bottom_line, bottom_line + 1, false)[1] or ""
  return {
    start = { line = top_line, character = 0 },
    ["end"] = { line = bottom_line, character = #last_line },
  }
end

local function make_virtual_text(hint)
  local text = ""
  local label = hint.label
  if type(label) == "string" then
    text = label
  else
    for _, part in ipairs(label or {}) do
      text = text .. part.value
    end
  end
  local vt = {}
  if hint.paddingLeft then
    vt[#vt + 1] = { " " }
  end
  vt[#vt + 1] = { text, "LspInlayHint" }
  if hint.paddingRight then
    vt[#vt + 1] = { " " }
  end
  return vt
end

local function apply_hints(bufnr, client, range, hints, replace_all)
  if not api.nvim_buf_is_loaded(bufnr) then
    return
  end
  if replace_all then
    clear_all(bufnr)
  else
    clear_range(bufnr, range)
  end

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, hint in ipairs(hints or {}) do
    local line = hint.position.line
    local source = lines[line + 1] or ""
    local byte_col =
      vim.str_byteindex(source, client.offset_encoding, hint.position.character, false)
    api.nvim_buf_set_extmark(bufnr, namespace, line, byte_col, {
      virt_text_pos = "inline",
      virt_text = make_virtual_text(hint),
    })
  end
end

local function request_hints(bufnr, request_kind)
  local state = state_for(bufnr)
  if not state.enabled or state.insert_suspended or not api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local client = client_mod.get(bufnr)
  if not supports_inlay_hints(client) then
    return
  end

  local range = request_kind == "full" and full_file_range(bufnr) or visible_range(bufnr)
  if request_kind == "visible"
      and state.last_request_kind == "visible"
      and same_range(state.last_request_range, range) then
    return
  end
  local version = api.nvim_buf_get_changedtick(bufnr)
  local seq = state.seq
  local params = {
    textDocument = lsp_util.make_text_document_params(bufnr),
    range = range,
  }
  state.last_request_kind = request_kind
  state.last_request_range = vim.deepcopy(range)

  client:request(ms.textDocument_inlayHint, params, function(err, result)
    local current = states[bufnr]
    if err or not current or current.seq ~= seq or current.insert_suspended then
      return
    end
    if not api.nvim_buf_is_loaded(bufnr) then
      return
    end
    local current_version = api.nvim_buf_get_changedtick(bufnr)
    if current_version ~= version then
      return
    end
    apply_hints(bufnr, client, range, result or {}, request_kind == "full")
    if request_kind == "full" then
      current.initial_done = true
    end
  end, bufnr)
end

local function schedule_refresh(bufnr, request_kind, delay_ms)
  local state = state_for(bufnr)
  state.seq = state.seq + 1
  local seq = state.seq
  vim.defer_fn(function()
    local current = states[bufnr]
    if not current or current.seq ~= seq then
      return
    end
    request_hints(bufnr, request_kind)
  end, delay_ms or 0)
end

local function desired_request_kind(bufnr)
  if not state_for(bufnr).initial_done then
    return "full"
  end
  return "visible"
end

local function refresh_after_event(bufnr, delay_ms)
  schedule_refresh(bufnr, desired_request_kind(bufnr), delay_ms or 0)
end

local function install_refresh_handler(client)
  if not client or client._jls_inlay_refresh_handler_installed then
    return
  end
  client._jls_inlay_refresh_handler_installed = true
  client.handlers = client.handlers or {}
  client.handlers[ms.workspace_inlayHint_refresh] = function(err, _, ctx)
    if err then
      return vim.NIL
    end
    for _, bufnr in ipairs(vim.lsp.get_buffers_by_client_id(ctx.client_id)) do
      local state = states[bufnr]
      if state and state.enabled then
        refresh_after_event(bufnr, 0)
      end
    end
    return vim.NIL
  end
end

---@param bufnr integer
---@param client vim.lsp.Client
---@param cfg JlsConfig
function M.attach(bufnr, client, cfg)
  if not supports_inlay_hints(client) then
    return
  end

  if vim.lsp.inlay_hint and type(vim.lsp.inlay_hint.enable) == "function" then
    pcall(vim.lsp.inlay_hint.enable, false, { bufnr = bufnr })
  end

  install_refresh_handler(client)

  local state = state_for(bufnr)
  state.enabled = true
  state.client_id = client.id

  local group = api.nvim_create_augroup("JlsInlayHints" .. bufnr, { clear = true })
  local debounce_ms = tonumber(cfg.inlay_hints_debounce_ms) or 120
  if debounce_ms < 0 then
    debounce_ms = 0
  end

  api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      if state_for(bufnr).initial_done then
        refresh_after_event(bufnr, debounce_ms)
      end
    end,
  })

  api.nvim_create_autocmd("WinScrolled", {
    group = group,
    buffer = bufnr,
    callback = function()
      if state_for(bufnr).initial_done then
        schedule_refresh(bufnr, "visible", debounce_ms)
      end
    end,
  })

  if cfg.inlay_hints_refresh == "insert_leave" then
    api.nvim_create_autocmd("InsertEnter", {
      group = group,
      buffer = bufnr,
      callback = function()
        local current = state_for(bufnr)
        current.seq = current.seq + 1
        current.insert_suspended = true
        current.last_request_kind = nil
        current.last_request_range = nil
      end,
    })
    api.nvim_create_autocmd("InsertLeave", {
      group = group,
      buffer = bufnr,
      callback = function()
        local current = state_for(bufnr)
        current.insert_suspended = false
        refresh_after_event(bufnr, debounce_ms)
      end,
    })
  else
    api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      buffer = bufnr,
      callback = function()
        if state_for(bufnr).initial_done then
          schedule_refresh(bufnr, "visible", debounce_ms)
        end
      end,
    })
  end

  api.nvim_create_autocmd("LspDetach", {
    group = group,
    buffer = bufnr,
    callback = function(args)
      if args.data.client_id ~= client.id then
        return
      end
      clear_all(bufnr)
      states[bufnr] = nil
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })
end

return M
