local util = require("jls.util")

local M = {}

local function resolve_launcher(cfg)
  local cmd = cfg.cmd
  if cmd then
    if type(cmd) == "string" then
      return { cmd }
    end
    return cmd
  end

  local jls_dir = cfg.jls_dir or os.getenv("JLS_HOME") or os.getenv("JLS_DIR")
  if not jls_dir or jls_dir == "" then
    return nil, "jls_dir is not set (set config.jls_dir or JLS_HOME/JLS_DIR)"
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

function M.build_cmd(cfg)
  local base, err = resolve_launcher(cfg)
  if not base then
    return nil, err
  end

  local cmd = vim.deepcopy(base)

  if cfg.lombok and cfg.lombok.path and cfg.lombok.path ~= "" then
    table.insert(cmd, "-Dorg.javacs.lombokPath=" .. cfg.lombok.path)
  end

  if cfg.lombok and cfg.lombok.javaagent and cfg.lombok.javaagent ~= "" then
    table.insert(cmd, "-javaagent:" .. cfg.lombok.javaagent)
  end

  for _, arg in ipairs(cfg.extra_args or {}) do
    table.insert(cmd, arg)
  end

  return cmd
end

function M.build_env(cfg)
  local env = vim.tbl_deep_extend("force", {}, cfg.env or {})
  if cfg.java_home and cfg.java_home ~= "" then
    env.JAVA_HOME = cfg.java_home
  end
  return env
end

return M
