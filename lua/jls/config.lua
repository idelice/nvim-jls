---@class JlsConfig
---@field jls_dir string|nil Path to JLS install root containing dist/
---@field root_markers string[]
---@field settings table
---@field inlay_hints { enabled: boolean }
---@field jvm_args string[]|nil Extra JVM args passed via JLS_JVM_OPTS (override default -Xmx2g -Xms512m)

local M = {}

---@return JlsConfig
function M.default()
  return {
    jls_dir = nil,
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
    jvm_args = nil,
  }
end

---@param ... table
---@return JlsConfig
function M.merge(...)
  return vim.tbl_deep_extend("force", M.default(), ...)
end

return M
