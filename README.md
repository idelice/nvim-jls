# nvim-jls

Neovim integration for [JLS](https://github.com/idelice/jls) (Java Language Server). This plugin provides a clean, batteries‑included setup for JLS with sensible defaults, runtime hints, and convenience commands.

## Why this plugin

JLS can run as a raw LSP server, but configuring it correctly is the hard part. This plugin removes the boilerplate:

- OS‑aware launcher resolution (`dist/lang_server_{linux|mac|windows}`)
- Stable root detection for Maven/Gradle projects
- Built‑in commands

## Requirements

- Neovim 0.9+ (0.10+ recommended)
- JLS installed locally (build or release), with a `dist/` folder
- Optional: `nvim-lspconfig` (plugin works without it)

JLS is not currently listed in nvim-lspconfig or mason because it does not meet their minimum GitHub star threshold yet. This plugin still works with or without nvim-lspconfig/mason; if they become available, you can use them alongside this plugin without changing your setup.

## Quick start

```lua
-- lazy.nvim
{
  "idelice/nvim-jls",
  opts = {
    jls_dir = "/path/to/jls", -- must contain dist/lang_server_*.sh
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
  init_options = {},             -- LSP init options
  env = {},                      -- extra environment variables
  java_home = nil,               -- sets JAVA_HOME for the server
  extra_args = {},               -- extra args passed to JLS launcher
})
```

Notes on optional fields:

- `cmd`: if omitted, the plugin builds a launcher command from `jls_dir`.
- `jls_dir`: required only if you don't set `cmd` or `JLS_HOME`/`JLS_DIR`.
- `java_home`: only set this if you want to override your shell's `JAVA_HOME`.
- `init_options`: sent during LSP initialization. Use `init_options.jls.*` keys (see examples below).
- `env`: extra environment variables for the JLS process.
- `extra_args`: raw args appended to the JLS launcher command.

Examples:

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

## Notes

- If `cmd` is not set, the plugin resolves the launcher using `jls_dir`, `JLS_HOME`, or `JLS_DIR`.
- Notifications use `vim.notify`, so Noice will automatically render them if installed.
- nvim-jls caches resolved config per workspace under `~/.cache/nvim-jls/<workspace>/config.json`.
