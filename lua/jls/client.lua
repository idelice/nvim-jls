local M = {}

M._client_id = nil
M._group = nil

local function is_external_jls_source(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= nil and name:find("jls%-jar%-sources", 1, false) ~= nil
end

local function configure_external_source_buffer(bufnr)
  if not bufnr or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not is_external_jls_source(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "java"
end

---@param cfg JlsConfig|nil
function M.setup_autocmds(cfg)
  if M._group then
    return
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
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter", "BufWinEnter" }, {
    group = M._group,
    callback = function(ev)
      configure_external_source_buffer(ev.buf)
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
