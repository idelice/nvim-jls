# nvim-jls

Neovim integration for [JLS](https://github.com/idelice/jls) (Java Language Server).

## Why this plugin

JLS can run as a raw LSP server, but configuring it correctly is the hard part. This plugin removes the boilerplate:

- OS‑aware launcher resolution (`dist/lang_server_{linux|mac|windows}`)
- Stable root detection for Maven/Gradle projects

## Requirements

- **Neovim 0.10+** – required for pull diagnostics (errors/warnings will not appear on older versions)
- Optional: `nvim-lspconfig` (plugin works without it)

JLS is not currently listed in nvim-lspconfig or mason because it does not meet their minimum GitHub star threshold yet. This plugin still works with or without nvim-lspconfig/mason; if they become available, you can use them alongside this plugin without changing your setup.

## Quick start

```lua
-- lazy.nvim
{
  "idelice/nvim-jls",
  opts = {},
}
```

Run `:JlsInstall` once after installing the plugin. JLS is downloaded to Neovim's data directory automatically. `setup()` is only needed to override defaults.

JLS starts automatically on `FileType=java` via a filetype plugin.

## Disk usage

This plugin writes to two locations on your machine:

| What | Path |
|---|---|
| JLS binary | `stdpath("data")/jls/` — typically `~/.local/share/nvim/jls/` on Linux/macOS, `~/AppData/Local/nvim-data/jls/` on Windows |
| Workspace cache | `$XDG_CACHE_HOME/jls/<project>-<hash>/` — typically `~/.cache/jls/` on Linux/macOS |

To remove the JLS binary: delete the directory manually.
To remove a workspace's cache: run `:JlsClearCache` from any buffer in that project, or delete `~/.cache/jls/` manually.

## Commands

- `:JlsInstall [tag]` – download and install JLS (latest release by default; pass a tag like `v1.2.3` to pin a version)
- `:JlsUpdate` – update JLS to the latest release
- `:JlsRestart` – restart JLS (only available while JLS is running)
- `:JlsLog` – open Neovim's LSP log in a read-only buffer
- `:JlsClearCache` – delete this workspace's JLS disk cache
- `:checkhealth jls` – run the built-in health check

## Configuration

```lua
require("jls").setup({
  jls_dir = nil,                 -- defaults to managed install (~/.local/share/nvim/jls); set to override
  settings = {},                 -- passed through to the JLS LSP settings payload
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
  inlay_hints = {
    enabled = false,             -- show parameter name hints at call sites
  },
  jvm_args = nil,                -- override JVM args (default: -Xmx2g -Xms512m ...)
  cmd_env = {},                  -- extra environment variables passed to the JLS process
  auto_restart = false,          -- automatically restart JLS if it crashes (up to 3 attempts with backoff)
})
```

JLS ships with sensible JVM defaults (`-Xmx2g -Xms512m -XX:MaxHeapFreeRatio=50
-XX:MinHeapFreeRatio=20 -XX:+UseStringDeduplication`). Override via `jvm_args`:

```lua
require("jls").setup({
  jls_dir = "/path/to/jls",
  jvm_args = { "-Xmx1g", "-Xms256m" },
})
```

The list is joined with spaces and passed as `JLS_JVM_OPTS` to the launcher,
which uses it in place of the default flags. You can also set the `JLS_JVM_OPTS`
environment variable directly (outside Neovim or via `vim.fn.setenv`).

`cmd_env` passes arbitrary environment variables to the JLS process:

```lua
require("jls").setup({
  cmd_env = { JAVA_HOME = "/usr/local/java21" },
})
```

`auto_restart` restarts JLS automatically if it exits unexpectedly (up to 3 attempts with exponential backoff):

```lua
require("jls").setup({
  auto_restart = true,
})
```

## Debug logging

Run `:JlsDebugEnable` to switch JLS to FINE-level logging. The plugin patches
`logging.properties` (backing up the original to `logging.properties.bak`) and
restarts JLS automatically if it is running. Detailed logs appear in
`:JlsLog` (Neovim's LSP log).

Run `:JlsDebugDisable` to restore default log levels. If a backup exists it is
used; otherwise the plugin reverts the patched lines. JLS restarts automatically.

Debug logging persists across Neovim restarts until you explicitly disable it.

## Inlay hints

Enable parameter name hints at call sites:

```lua
require("jls").setup({
  inlay_hints = { enabled = true },
})
```

Hints appear only for files in your workspace. JDK and dependency sources opened via go-to-definition are not annotated.
