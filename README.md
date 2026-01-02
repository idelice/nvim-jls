# nvim-jls

Neovim integration for JLS (Java Language Server). This plugin provides a clean, batteries‑included setup for JLS with sensible defaults, Lombok wiring, runtime hints, and convenience commands.

## Why this plugin

JLS can run as a raw LSP server, but configuring it correctly is the hard part. This plugin removes the boilerplate:

- OS‑aware launcher resolution (`dist/lang_server_{linux|mac|windows}`)
- Stable root detection for Maven/Gradle/Bazel projects
- Lombok support via `-Dorg.javacs.lombokPath` or `-javaagent` (manual jar path optional; auto-detected)
- Built‑in commands and status reporting

## Requirements

- Neovim 0.9+ (0.10+ recommended)
- JLS installed locally (build or release), with a `dist/` folder
- Optional: `nvim-lspconfig` (plugin works without it)

JLS is not currently listed in nvim-lspconfig or mason because it does not meet their minimum GitHub star threshold yet. This plugin still works with or without nvim-lspconfig/mason; if they become available, you can use them alongside this plugin without changing your setup.

## Install

Use your plugin manager:

```lua
-- lazy.nvim (opts-only)
{
  "idelice/nvim-jls",
  opts = {},
}
```

## Quick start

```lua
-- lazy.nvim (opts-only)
{
  "idelice/nvim-jls",
  opts = {
    jls_dir = "/path/to/jls", -- must contain dist/lang_server_*.sh
    lombok = {
      -- path = "/path/to/lombok.jar", -- optional (auto-detected if present)
      -- javaagent = "/path/to/lombok.jar", -- optional
    },
  },
}
```

JLS starts automatically on `FileType=java` via a filetype plugin. `setup()` is only needed if you want to override defaults.

## Commands

- `:JlsStart` – start JLS for the current buffer
- `:JlsRestart` – restart JLS
- `:JlsStop` – stop all JLS clients
- `:JlsInfo` – show resolved root and command
- `:JlsDoctor` – show effective config and diagnostics
- `:JlsCacheClear` – delete workspace cache under `~/.cache/jls/`
- `:JlsCacheClearRestart` – clear cache and restart JLS
- `:JlsLogs` – open Neovim LSP log

## Configuration

```lua
require("jls").setup({
  cmd = nil,                     -- override full command
  jls_dir = nil,                 -- used to resolve dist/lang_server_*.sh
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
  settings = {                   -- LSP settings (sent via didChangeConfiguration)
    jls = {
      features = {
        inlayHints = true,
        semanticTokens = true,
      },
    },
  },
  init_options = {},             -- LSP init options
  env = {},                      -- extra environment variables
  java_home = nil,               -- sets JAVA_HOME for the server
  lombok = { path = nil, javaagent = nil },
  -- lombok = { path = nil, javaagent = nil, search_paths = { "/opt/lombok/*.jar" } },
  extra_args = {},               -- extra args passed to JLS launcher
  status = { enable = true, notify = false }, -- progress status
  codelens = { enable = false }, -- auto-refresh codelens on BufEnter
})
```

Notes on optional fields:

- `cmd`: if omitted, the plugin builds a launcher command from `jls_dir`.
- `jls_dir`: required only if you don't set `cmd` or `JLS_HOME`/`JLS_DIR`.
- `java_home`: only set this if you want to override your shell's `JAVA_HOME`.
- `settings`: forwarded to JLS as `workspace/didChangeConfiguration`. Use `settings.jls.*` keys (see examples below).
- `init_options`: sent during LSP initialization. Use `init_options.jls.*` keys (see examples below).
- `env`: extra environment variables for the JLS process.
- `lombok.path`: optional. If omitted, the plugin tries to auto-detect Lombok from `~/.m2` first, then from any `lombok.search_paths`.
- `lombok.javaagent`: adds `-javaagent:/path/to/lombok.jar` when Lombok needs a Java agent instead of only `lombokPath`.
- `lombok.search_paths`: optional list of paths or globs to search for Lombok (used if `lombok.path` is not set).
- `extra_args`: raw args appended to the JLS launcher command.
- `codelens.enable`: toggles codelens auto-refresh on `BufEnter`.

Examples:

```lua
settings = {
  jls = {
    diagnostics = {
      enable = true,
      unusedImports = "warning", -- "error" | "warning" | "off"
    },
    features = {
      inlayHints = true,
      semanticTokens = true,
    },
  },
}
```

```lua
init_options = {
  jls = {
    cache = {
      dir = "/path/to/jls-cache",
    },
  },
}
```

```lua
env = {
  JAVA_TOOL_OPTIONS = "-Xmx2g",
}
```

```lua
extra_args = { "-Xmx2g", "-Dhttps.proxyHost=proxy", "-Dhttps.proxyPort=8443" }
```

## Statusline

Show JLS progress in your statusline:

```lua
require("lualine").setup({
  sections = {
    lualine_c = { function() return require("jls").statusline() end },
  },
})
```

## Notes

- If `cmd` is not set, the plugin resolves the launcher using `jls_dir`, `JLS_HOME`, or `JLS_DIR`.
- JLS runtime selection follows the server’s default behavior (`JAVA_HOME`, `~/.config/jls/runtimes.json`).
- Notifications use `vim.notify`, so Noice will automatically render them if installed.
- For Lombok compilation issues, ensure Maven is configured to run annotation processors.
- nvim-jls caches resolved config per workspace under `~/.cache/nvim-jls/<workspace>/config.json`.
