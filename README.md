# nvim-jls

Neovim integration for [JLS](https://github.com/idelice/jls) (Java Language Server).

## Why this plugin

JLS can run as a raw LSP server, but configuring it correctly is the hard part. This plugin removes the boilerplate:

- OS‑aware launcher resolution (`dist/lang_server_{linux|mac|windows}`)
- Stable root detection for Maven/Gradle projects

## Requirements

- **Neovim 0.10+** – required for pull diagnostics (errors/warnings will not appear on older versions)
- Optional: `nvim-lspconfig` (plugin works without it)

## Quick start

```lua
-- lazy.nvim
{
  "idelice/nvim-jls",
  opts = {},
}
```

JLS starts automatically on `FileType=java` via a filetype plugin. `setup()` is only needed to override defaults.

**Installation:** If you use [mason.nvim](https://github.com/mason-org/mason.nvim), install via `:MasonInstall jls` — the plugin detects and uses the mason path automatically. Without mason, run `:JlsInstall` once to download JLS to Neovim's data directory.

> **Note for nvim-lspconfig users:** Do not call `require('lspconfig').jls.setup()` yourself — nvim-jls calls it internally with its own configuration. Doing so causes a conflict where either your settings or nvim-jls's features are silently dropped depending on load order.

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


## Inlay hints

Enable parameter name hints at call sites:

```lua
require("jls").setup({
  inlay_hints = { enabled = true },
})
```

Hints appear only for files in your workspace. JDK and dependency sources opened via go-to-definition are not annotated.

## Diagnostics

Diagnostics are requested on `InsertLeave`, `BufWritePost`, and after 500ms of no edits in normal mode. They are not re-requested when navigating back to an unchanged buffer.

## Code actions

Use the standard Neovim LSP mapping (`vim.lsp.buf.code_action()`) to trigger code actions.

Actions are computed lazily — the list appears immediately, and the workspace edit is only computed when you confirm an action.

**On a text selection inside a method:**
- Surround with try-catch
- Extract to local variable

**With cursor inside a class (no selection):**
- Generate constructor / equals / hashCode / toString
- Generate getters (pick fields) — opens a picker
- Generate setters (pick fields) — opens a picker; `final` fields are excluded
- Override inherited method — one entry per overridable method
- Add `@Lombok` annotation — available when Lombok is on the classpath

**Quick fixes (from diagnostics):**
- Import unresolved type
- Add `throws` for unreported exception
- Implement abstract methods
- Generate constructor (missing field initializer)
- Create missing method
- Remove unused class / method / field / local variable
- Remove unused `throws` clause
- Suppress unchecked warning

### Getter/setter picker

When snacks.nvim is loaded, a multi-select picker opens (`<Tab>` to select, `<CR>` to confirm). Without snacks.nvim, a floating window lists fields and `vim.ui.input` prompts for a comma-separated list of numbers (e.g. `1,3`) or `all`.

## Rename

Use the standard Neovim rename (`vim.lsp.buf.rename()`). When renaming a class, JLS also renames the source file on disk and notifies your file explorer (nvim-tree, neo-tree, mini.files, and snacks.nvim explorer are all supported) to refresh automatically.

## Debugging

JLS ships a DAP debug adapter (`jls-debug-adapter`) alongside the language server binary. It attaches to a running JVM via JDWP — you start your app in debug mode first, then connect from Neovim.

### Setup

Install [nvim-dap](https://github.com/mfussenegger/nvim-dap) and configure the adapter:

```lua
local dap = require("dap")

dap.adapters.jls = {
  type = "executable",
  command = "jls-debug-adapter",  -- must be on PATH (mason install handles this)
}

dap.configurations.java = {
  {
    type = "jls",
    request = "attach",
    name = "Debug (Attach) - Remote (JLS)",
    hostName = "127.0.0.1",
    port = 5005,
    -- Required: absolute path(s) to your Java source roots.
    -- Defaults to src/main/java relative to cwd; set SOURCE_ROOT env var to override.
    sourceRoots = function()
      local root = os.getenv("SOURCE_ROOT")
      if root and root ~= "" then return { root } end
      return { vim.fn.getcwd() .. "/src/main/java" }
    end,
  },
}
```

(To-be-implemented) If you use [LazyVim](https://github.com/LazyVim/LazyVim), enable the `lazyvim.plugins.extras.lang.jls` extra — it configures the adapter automatically.

### Usage

**1. Start your Java application with JDWP enabled:**

| Build tool | Command |
|---|---|
| Maven (Spring Boot) | `./mvnw spring-boot:run -Dspring-boot.run.jvmArguments="-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005"` |
| Gradle (Spring Boot) | `./gradlew bootRun --debug-jvm` |
| Plain JAR | `java -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005 -jar app.jar` |

Wait for output like `Listening for transport dt_socket at address: 5005` before attaching.

**2. Open Neovim from the project root** so that `sourceRoots` resolves correctly. If your sources live outside `src/main/java`, set the env var before launching:

```sh
SOURCE_ROOT=/path/to/src/main/java nvim .
```

**3. Attach the debugger** via `:DapContinue` (or `<leader>dc` in LazyVim). Select "Debug (Attach) - Remote (JLS)" when prompted.

Set breakpoints with `:DapToggleBreakpoint` (`<leader>db`) before or after attaching.
