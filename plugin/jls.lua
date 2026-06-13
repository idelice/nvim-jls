local jls = require("jls")

local function jls_running()
  return #vim.lsp.get_clients({ name = "jls" }) > 0
end

vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("JlsCommands", { clear = true }),
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not (client and client.name == "jls") then return end
    if not vim.api.nvim_get_commands({})["JlsRestart"] then
      vim.api.nvim_create_user_command("JlsRestart", function()
        jls.restart()
      end, { desc = "Restart the JLS language server" })
    end
  end,
})

vim.api.nvim_create_autocmd("LspDetach", {
  group = "JlsCommands",
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not (client and client.name == "jls") then return end
    vim.schedule(function()
      if not jls_running() and vim.api.nvim_get_commands({})["JlsRestart"] then
        vim.api.nvim_del_user_command("JlsRestart")
      end
    end)
  end,
})

vim.api.nvim_create_user_command("JlsLog", function()
  jls.log()
end, {})

vim.api.nvim_create_user_command("JlsClearCache", function()
  jls.clear_cache()
end, {})

vim.api.nvim_create_user_command("JlsInstall", function(opts)
  jls.install(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "Download and install JLS (optionally specify a version tag e.g. v1.2.3)" })

vim.api.nvim_create_user_command("JlsUpdate", function()
  jls.update()
end, { desc = "Update JLS to the latest release" })

-- Ensure JLS server processes are killed when Neovim exits.
-- Neovim's built-in shutdown may not wait for the LSP handshake to complete,
-- leaving orphaned java processes consuming GBs of memory.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("JlsCleanup", { clear = true }),
  callback = function()
    for _, client in ipairs(vim.lsp.get_clients({ name = "jls" })) do
      -- Force stop sends SIGTERM to the spawned process
      pcall(function() client:stop(true) end)
    end
    -- Give the process a moment to die
    vim.wait(100, function() return false end)
  end,
})
