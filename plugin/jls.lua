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

vim.api.nvim_create_user_command("JlsDoctor", function()
  jls.doctor()
end, {})
