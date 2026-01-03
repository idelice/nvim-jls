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

vim.api.nvim_create_user_command("JlsInfo", function()
  jls.info()
end, {})

vim.api.nvim_create_user_command("JlsDoctor", function()
  jls.doctor()
end, {})

vim.api.nvim_create_user_command("JlsCacheClear", function()
  jls.cache_clear()
end, {})

vim.api.nvim_create_user_command("JlsCacheClearRestart", function()
  jls.cache_clear_restart()
end, {})

vim.api.nvim_create_user_command("JlsLogs", function()
  jls.logs()
end, {})

vim.api.nvim_create_user_command("JlsCodeActions", function()
  jls.code_actions()
end, {})
