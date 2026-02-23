# nvim-jls

Neovim integration for [JLS](https://github.com/idelice/jls) (Java Language Server).

## Why this plugin

JLS can run as a raw LSP server, but configuring it correctly is the hard part. This plugin removes the boilerplate:

- OS‑aware launcher resolution (`dist/lang_server_{linux|mac|windows}`)
- Stable root detection for Maven/Gradle projects

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
- `:JlsDoctor` – show effective config and diagnostics

## Configuration

```lua
require("jls").setup({
  jls_dir = nil,                 -- used to resolve dist/lang_server_*.sh
  filetypes = { "java" },
  debounce_text_changes = 200,   -- reduce request churn while typing
  inlay_hints = false,           -- true or table (see below)
  inlay_hints_refresh = "auto",  -- "auto" | "insert_leave"
  inlay_hints_debounce_ms = 120, -- used when inlay_hints_refresh = "insert_leave"
  codelens = false,
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
})
```

### Inlay hints

`nvim-jls` forwards inlay hint settings to JLS as `settings.java.inlayHints`.

```lua
require("jls").setup({
  inlay_hints = {
    enabled = true,
    parameterNames = true,
    debounceMs = 250,
    cacheIdleMs = 120000,
    cacheMaxEntries = 256,
  },
})
```

Notes:
- `inlay_hints = true` enables JLS inlay hints with server defaults.
- `inlay_hints_refresh = "auto"` uses Neovim's default inlay-hint refresh behavior.
- `inlay_hints_refresh = "insert_leave"` disables inlay hints while typing and refreshes once after insert mode.
- `inlay_hints_debounce_ms` controls the post-insert refresh delay in `"insert_leave"` mode.
