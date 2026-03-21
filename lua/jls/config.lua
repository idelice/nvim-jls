---@class JlsConfig
---@field jls_dir string|nil Path to JLS install root containing dist/
---@field root_markers string[]
---@field settings table
---@field codelens boolean

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
    codelens = false,
  }
end

---@param ... table
---@return JlsConfig
function M.merge(...)
  return vim.tbl_deep_extend("force", M.default(), ...)
end

return M
