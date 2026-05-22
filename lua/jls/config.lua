---@class JlsConfig
---@field jls_dir string|nil Path to JLS install root containing dist/ (defaults to managed install)
---@field root_markers string[]
---@field settings table
---@field inlay_hints { enabled: boolean }
---@field cmd_env table<string,string> Extra environment variables passed to the JLS process
---@field auto_restart boolean Automatically restart JLS if it crashes (up to 3 attempts with backoff)
---@field jvm_args string[]|nil Extra JVM args passed via JLS_JVM_OPTS (override default -Xmx2g -Xms512m)

local installer = require("jls.installer")

local M = {}

---@return string
local function resolve_default_jls_dir()
  local mason_path = vim.fn.stdpath("data") .. "/mason/packages/jls"
  if vim.fn.isdirectory(mason_path) == 1 then
    return mason_path
  end
  return installer.managed_install_dir()
end

---@return JlsConfig
function M.default()
  return {
    jls_dir = resolve_default_jls_dir(),
    root_markers = {
      "pom.xml",
      "build.gradle",
      "build.gradle.kts",
      "settings.gradle",
      "settings.gradle.kts",
      "WORKSPACE",
      "WORKSPACE.bazel",
      ".java-version",
      ".git",
    },
    settings = {},
    inlay_hints = {
      enabled = false,
    },
    cmd_env = {},
    auto_restart = false,
    jvm_args = nil,
  }
end

---@param ... table
---@return JlsConfig
function M.merge(...)
  return vim.tbl_deep_extend("force", M.default(), ...)
end

return M
