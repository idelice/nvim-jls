local jls = require("jls")

vim.api.nvim_create_user_command("JlsStart", function()
  jls.start()
end, {})

vim.api.nvim_create_user_command("JlsRestart", function()
  jls.restart()
end, {})

vim.api.nvim_create_user_command("JlsStop", function()
  jls.stop()
end, {})

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
