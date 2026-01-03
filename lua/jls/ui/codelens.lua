local client_mod = require("jls.client")

local M = {}

function M.setup(cfg)
  if not (cfg.codelens and cfg.codelens.enable) then
    return
  end
  local group = vim.api.nvim_create_augroup("JlsCodeLens", { clear = true })

  local function has_jls(bufnr)
    return client_mod.get(bufnr) ~= nil
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

return M
