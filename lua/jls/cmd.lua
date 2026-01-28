local util = require("jls.util")

local M = {}

function M.build_cmd(cfg)
  local jls_dir = cfg.jls_dir
  if not jls_dir or jls_dir == "" then
    return nil, "jls_dir is not set"
  end

  local os_id = util.detect_os()
  local launcher = os_id == "windows"
      and util.joinpath(jls_dir, "dist", "lang_server_windows.cmd")
      or util.joinpath(jls_dir, "dist", "lang_server_" .. os_id .. ".sh")

  if vim.fn.filereadable(launcher) == 0 then
    return nil, "JLS launcher not found: " .. launcher
  end

  return { launcher }
end

return M
