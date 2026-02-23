---@class JlsConfig
---@field jls_dir string|nil Path to JLS install root containing dist/
---@field filetypes string[]
---@field root_markers string[]
---@field settings table
---@field inlay_hints boolean|table
---@field inlay_hints_refresh "auto"|"insert_leave"
---@field inlay_hints_debounce_ms integer
---@field debounce_text_changes integer
---@field codelens boolean

local M = {}

---@return JlsConfig
function M.default()
  return {
    jls_dir = nil,
    filetypes = { "java" },
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
    inlay_hints = false,
    inlay_hints_refresh = "auto",
    inlay_hints_debounce_ms = 120,
    debounce_text_changes = 200,
    codelens = false,
  }
end

---@param ... table
---@return JlsConfig
function M.merge(...)
  return vim.tbl_deep_extend("force", M.default(), ...)
end

return M
