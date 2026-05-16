local util = require("jls.util")

local M = {}

function M.resolve_launcher(cfg)
  local jls_dir = cfg.jls_dir
  if not jls_dir or jls_dir == "" then
    return nil, "jls_dir is not set"
  end

  jls_dir = vim.fn.expand(jls_dir)
  if not jls_dir or jls_dir == "" then
    return nil, "jls_dir is not set"
  end

  local os_id = util.detect_os()
  local filename = os_id == "windows"
      and "lang_server_windows.cmd"
      or "lang_server_" .. os_id .. ".sh"

  -- Managed installs extract scripts to the root; source builds put them in dist/
  local launcher = util.joinpath(jls_dir, filename)
  if vim.fn.filereadable(launcher) == 0 then
    launcher = util.joinpath(jls_dir, "dist", filename)
  end

  if vim.fn.filereadable(launcher) == 0 then
    return nil, "JLS launcher not found in " .. jls_dir .. "\nRun :JlsInstall to download and install JLS."
  end

  return launcher, nil
end

function M.is_executable(launcher)
  if not launcher or launcher == "" then
    return false
  end
  if util.detect_os() == "windows" then
    return true
  end
  return vim.fn.executable(launcher) == 1
end

function M.build_cmd(cfg, _root_dir)
  local launcher, err = M.resolve_launcher(cfg)
  if not launcher then
    return nil, err
  end

  local env = cfg.cmd_env or {}
  if cfg.jvm_args and #cfg.jvm_args > 0 then
    env = vim.tbl_extend("force", env, { JLS_JVM_OPTS = table.concat(cfg.jvm_args, " ") })
  end

  return { launcher }, env, nil
end

return M
