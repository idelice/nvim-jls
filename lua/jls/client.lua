local M = {}

M._client_id = nil
M._group = nil
M._stop_on_exit = false

---@param cfg JlsConfig|nil
function M.setup_autocmds(cfg)
  if M._group then
    return
  end
  if cfg and cfg.stop_on_exit ~= nil then
    M._stop_on_exit = cfg.stop_on_exit
  end
  M._group = vim.api.nvim_create_augroup("JlsClientCache", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = M._group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if client and client.name == "jls" then
        M._client_id = client.id
      end
    end,
  })
  vim.api.nvim_create_autocmd("LspDetach", {
    group = M._group,
    callback = function(ev)
      if M._client_id == ev.data.client_id then
        M._client_id = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimLeavePre", "ExitPre" }, {
    group = M._group,
    callback = function()
      if not M._stop_on_exit then
        return
      end
      local client = M.get(nil)
      if client then
        client:stop(true)
      end
    end,
  })
end

---@param bufnr number|nil
---@return vim.lsp.Client|nil
function M.get(bufnr)
  if not M._client_id then
    return nil
  end
  local client = vim.lsp.get_client_by_id(M._client_id)
  if not client or client.name ~= "jls" then
    return nil
  end
  if bufnr and client.attached_buffers and not client.attached_buffers[bufnr] then
    return nil
  end
  return client
end

return M
