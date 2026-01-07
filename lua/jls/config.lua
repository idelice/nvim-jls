---@class JlsLombokConfig
---@field path string|nil Path to lombok.jar
---@field javaagent string|nil Path to lombok javaagent jar
---@field search_paths string[]|nil Extra paths/globs to search for lombok.jar

---@class JlsConfig
---@field cmd string[]|string|nil Explicit command to start JLS
---@field jls_dir string|nil Path to JLS install root containing dist/
---@field filetypes string[]
---@field root_markers string[]
---@field settings table
---@field init_options table
---@field env table<string,string>
---@field java_home string|nil JAVA_HOME override
---@field lombok JlsLombokConfig
---@field extra_args string[]
---@field status JlsStatusConfig
---@field codelens { enable: boolean }
---@field stop_on_exit boolean

local M = {}

---@return JlsConfig
function M.default()
  return {
    cmd = nil,
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
    settings = {
      jls = {
        features = {
          inlayHints = true,
          semanticTokens = true,
        },
      },
    },
    init_options = {},
    env = {},
    java_home = nil,
    lombok = { path = nil, javaagent = nil, search_paths = nil },
    extra_args = {},
    codelens = { enable = false },
    stop_on_exit = false,
  }
end

---@param ... table
---@return JlsConfig
function M.merge(...)
  return vim.tbl_deep_extend("force", M.default(), ...)
end

return M
