# nvim-jls

Neovim integration for [JLS](https://github.com/idelice/jls) (Java Language Server).

## Why this plugin

JLS can run as a raw LSP server, but configuring it correctly is the hard part. This plugin removes the boilerplate:

- OS‑aware launcher resolution (`dist/lang_server_{linux|mac|windows}`)
- Stable root detection for Maven/Gradle projects

## Requirements

- **Neovim 0.10+** – required for pull diagnostics (errors/warnings will not appear on older versions)
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
    settings = {},
  },
}
```

JLS starts automatically on `FileType=java` via a filetype plugin. `setup()` is only needed if you want to override defaults.

## Commands

- `:JlsStart` – start JLS for the current buffer
- `:JlsRestart` – restart JLS
- `:JlsStop` – stop all JLS clients
- `:JlsLog` – open Neovim's LSP log in a read-only buffer
- `:JlsClearCache` – delete this workspace's JLS disk cache
- `:checkhealth jls` – run the built-in health check

## Configuration

```lua
require("jls").setup({
  jls_dir = nil,                 -- used to resolve dist/lang_server_*.sh
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

## Inlay hints

Enable parameter name hints at call sites:

```lua
require("jls").setup({
  inlay_hints = { enabled = true },
})
```

Hints appear only for files in your workspace. JDK and dependency sources opened via go-to-definition are not annotated.
