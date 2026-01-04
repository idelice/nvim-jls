local client_mod = require("jls.client")
local util = require("jls.util")
local constructor = require("jls.actions.constructor")

local M = {}

local function ensure_snacks()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    util.notify("JLS: Snacks.nvim is required for this UI", vim.log.levels.WARN)
    return nil
  end
  return snacks
end

local function apply_action(client, action)
  if not action then
    return
  end
  local supports_resolve = util.supports_code_action_resolve(client)

  if (not action.edit and not action.command) and supports_resolve then
    client.request("codeAction/resolve", action, function(err, resolved)
      if err then
        util.notify("JLS: resolve failed: " .. err.message, vim.log.levels.ERROR)
        return
      end
      apply_action(client, resolved or action)
    end)
    return
  end
  if action.edit then
    vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
  end
  if action.command then
    vim.lsp.buf.execute_command(action.command)
  end
end

function M.code_actions()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = client_mod.get(bufnr)
  if not client then
    util.notify("JLS: not attached", vim.log.levels.WARN)
    return
  end
  local snacks = ensure_snacks()
  if not snacks then
    return
  end

  local win = vim.api.nvim_get_current_win()
  ---@type lsp.CodeActionParams
  local params = vim.lsp.util.make_range_params(win, client.offset_encoding)
  params.context = { diagnostics = vim.diagnostic.get(bufnr) }
  client:request("textDocument/codeAction", params, function(err, actions)
    if err then
      util.notify("JLS: code actions failed: " .. err.message, vim.log.levels.ERROR)
      return
    end
    if not actions or vim.tbl_isempty(actions) then
      util.notify("JLS: no code actions available", vim.log.levels.WARN)
      return
    end
    local items = {}
    for _, action in ipairs(actions) do
      table.insert(items, { text = action.title, action = action })
    end

    snacks.picker.pick({
      title = "JLS Code Actions",
      items = items,
      layout = { main = { preview = { enabled = false } } },
      format = function(item)
        return { { item.text } }
      end,
      win = { preview = { enabled = false } },
      actions = {
        confirm = function(picker, item)
          picker:close()
          if not item or not item.action then
            return
          end
          if item.action.title == "Generate constructor" then
            constructor.pick_fields(snacks, client, bufnr)
          else
            apply_action(client, item.action)
          end
        end,
      },
    })
  end, bufnr)
end

return M
