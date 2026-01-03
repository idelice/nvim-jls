local util = require("jls.util")

local M = {}

local function symbol_kinds()
  local kinds = vim.lsp.protocol and vim.lsp.protocol.SymbolKind or {}
  return {
    class = kinds.Class or 5,
    field = kinds.Field or 8,
  }
end

local function collect_fields_from_symbols(symbols, cursor)
  local kinds = symbol_kinds()
  if not symbols or #symbols == 0 then
    return {}
  end

  if symbols[1].range then
    local classes = {}
    local function scan(node)
      if node.kind == kinds.class then
        table.insert(classes, node)
      end
      if node.children then
        for _, child in ipairs(node.children) do
          scan(child)
        end
      end
    end
    for _, sym in ipairs(symbols) do
      scan(sym)
    end

    local target = nil
    for _, cls in ipairs(classes) do
      if util.pos_in_range(cursor, cls.range) then
        target = cls
        break
      end
    end
    if not target then
      target = classes[1]
    end
    if not target or not target.children then
      return {}
    end
    local fields = {}
    for _, child in ipairs(target.children) do
      if child.kind == kinds.field then
        table.insert(fields, child.name)
      end
    end
    return fields
  end

  local fields = {}
  for _, sym in ipairs(symbols) do
    if sym.kind == kinds.field then
      table.insert(fields, sym.name)
    end
  end
  return fields
end

local function set_client_settings(client, settings)
  client.config.settings = settings
  client.notify("workspace/didChangeConfiguration", { settings = settings })
end

local function request_code_actions(client, bufnr, title, apply_settings, restore_settings)
  local win = vim.api.nvim_get_current_win()
  local params = vim.lsp.util.make_range_params(win, client.offset_encoding)
  params.context = { diagnostics = {} }
  apply_settings()
  client.request("textDocument/codeAction", params, function(err, actions)
    restore_settings()
    if err then
      util.notify("JLS: code actions failed: " .. err.message, vim.log.levels.ERROR)
      return
    end
    if not actions or vim.tbl_isempty(actions) then
      util.notify("JLS: no code actions available", vim.log.levels.WARN)
      return
    end
    local action = nil
    for _, item in ipairs(actions) do
      if item.title == title then
        action = item
        break
      end
    end
    if not action then
      util.notify("JLS: action not found: " .. title, vim.log.levels.WARN)
      return
    end
    if action.edit then
      vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
    end
    if action.command then
      vim.lsp.buf.execute_command(action.command)
    end
  end, bufnr)
end

function M.pick_fields(snacks, client, bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local pos = { line = cursor[1] - 1, character = cursor[2] }
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
  client.request("textDocument/documentSymbol", params, function(err, symbols)
    if err then
      util.notify("JLS: document symbols failed: " .. err.message, vim.log.levels.ERROR)
      return
    end
    local fields = collect_fields_from_symbols(symbols, pos)
    if #fields == 0 then
      util.notify("JLS: no fields found for constructor", vim.log.levels.WARN)
      return
    end

    local items = {}
    for _, name in ipairs(fields) do
      table.insert(items, { text = name, name = name })
    end

    snacks.picker.pick({
      title = "Constructor fields",
      items = items,
      layout = { preview = false, hidden = { "preview" } },
      format = function(item)
        return { { item.text } }
      end,
      formatters = {
        selected = { show_always = true, unselected = true },
      },
      actions = {
        jls_toggle = function(picker, item)
          if not item then
            return
          end
          picker.list:select(item)
        end,
        confirm = function(picker)
          local selected = picker:selected({ fallback = false })
          local names = {}
          for _, sel in ipairs(selected) do
            if sel.name then
              table.insert(names, sel.name)
            end
          end
          picker:close()
          local original = vim.deepcopy(client.config.settings or {})
          local include = util.names_to_patterns(names)
          local patch = {
            jls = {
              codeActions = {
                generateConstructor = {
                  include = include,
                },
              },
            },
          }
          local merged = vim.tbl_deep_extend("force", original, patch)
          request_code_actions(
            client,
            bufnr,
            "Generate constructor",
            function()
              set_client_settings(client, merged)
            end,
            function()
              set_client_settings(client, original)
            end
          )
        end,
      },
      win = {
        preview = { enabled = false },
        input = {
          footer = {
            { "Select fields with <Space>, then press <Enter> to generate", "DiagnosticWarn" },
          },
          footer_pos = "center",
          keys = {
            ["<Space>"] = { "jls_toggle", mode = { "i", "n" } },
            ["<CR>"] = { "confirm", mode = { "i", "n" } },
          },
        },
        list = {
          keys = {
            ["<Space>"] = "jls_toggle",
            ["<CR>"] = "confirm",
          },
        },
      },
    })
  end, bufnr)
end

return M
