# projectrc.nvim

Per-project settings for Neovim, in the spirit of VS Code's `.vscode/settings.json`, edited in a float.

```
╭──────────────────────── Project settings ────────────────────────╮
│ Editor  Format  LSP  Build  Debug                 scope: project │
│  ~/code/engine  ·  trusted                                       │
│                                                                  │
│  Indent width          4          → from clang-format (Format)   │
│  Text width            100        ● project                      │
│  Soft wrap             off        ◆ [markdown]                   │
│  Spell check           off        ○ default                      │
│                                                                  │
│  <CR> edit  x reset  f filetype scope  e json  T trust  q close  │
╰───────── Hard wrap column for gq and auto-wrap (0 = off). ───────╯
```

* **One file you edit, many tools that agree.** Most settings live in `.nvim/settings.json`. Settings another tool reads are written to *that tool's* file instead (`.clang-format`, `.clangd`), so `clang-format` from a shell, clangd, CI and other editors all see the same values. Hand-written files keep their comments, other keys and other YAML documents. The first change to a file the plugin didn't create shows a diff and asks.
* **C-family indentation follows clang-format.** `shiftwidth`/`tabstop`/`expandtab` come from `clang-format --dump-config` for the file, so `>>` and format-on-save can't disagree. Without a `.clang-format`, a configurable fallback style is used for both.
* **Trust like `'exrc'`.** Settings that run something (build commands, environment, debug configs, clangd's `--query-driver`, the Python venv) are ignored until the settings file is trusted through `vim.secure`'s hash database. Edits made in the float keep a trusted file trusted, but never turn an untrusted one trusted.
* **Per-filetype overrides** (`"[python]": { … }`), shown in the float with where every value comes from: ● project, ◆ filetype, ▣ native file, ○ inherited.

Requires Neovim 0.11+. Optional: `clang-format`, `clangd`, conform.nvim, nvim-dap, pyright.

## Install

```lua
-- lazy.nvim
{
  "you/projectrc.nvim",
  lazy = false, -- the appliers must see the first FileType
  keys = {
    { "<leader>,", function() require("projectrc").open() end, desc = "Project settings" },
    { "<leader>bb", function() require("projectrc").build("cmd") end, desc = "Build" },
  },
  opts = {},
}
```

## Settings

| Tab | Key | Stored in |
|---|---|---|
| Editor | `editor.indent`, `editor.tabs`, `editor.textwidth`, `editor.colorcolumn`, `editor.wrap`, `editor.spell` (all per-filetype) | settings.json |
| Format | `format.on_save`, `format.formatters` (per-filetype) | settings.json |
| | `clang_format.style`, `clang_format.indent`, `clang_format.use_tab`, `clang_format.column_limit` | `.clang-format` |
| LSP | `lsp.disabled`, `pyright.venv`, `pyright.type_checking`, `clangd.query_driver` | settings.json |
| | `clangd.std`, `clangd.flags`, `clangd.compile_commands_dir` | `.clangd` |
| Build | `build.cmd`, `build.run`, `build.test`, `build.cwd`, `build.env` | settings.json |
| Debug | `debug.configurations` (nvim-dap launch configs) | settings.json |

```json
{
  "build.cmd": "cmake --build build",
  "editor.textwidth": 100,
  "[python]": { "editor.indent": 4, "format.formatters": ["ruff_format"] },
  "debug.configurations": [{ "name": "app", "program": "build/app", "args": ["--verbose"] }]
}
```

## Integrations

The plugin applies editor options, clang-format indentation and pyright/`lsp.disabled` on its own. These hooks wire in the rest:

```lua
-- conform.nvim: project format-on-save / formatters, and the clang-format fallback style
require("conform").setup({
  format_on_save = function(buf)
    local project = require("projectrc").format_opts(buf, true)
    if not project then return end
    return vim.tbl_extend("force", { timeout_ms = 2000, lsp_format = "fallback" }, project)
  end,
  formatters = {
    clang_format = { prepend_args = function(_, ctx) return require("projectrc").clang_format_args(ctx.filename) end },
  },
})

-- clangd: --query-driver from the project
vim.lsp.config("clangd", { cmd = require("projectrc").clangd_cmd })

-- nvim-dap: project launch configs first (done automatically when lazy.nvim loads nvim-dap)
require("projectrc").dap_sync()
```

## Options

```lua
require("projectrc").setup({
  file = ".nvim/settings.json",
  markers = { ".git", "compile_commands.json", "CMakeLists.txt" },
  clang_indent = true,
  fallback_style = "{BasedOnStyle: LLVM, IndentWidth: 4}",
  runner = function(cmd, ctx) end,  -- ctx = { root, cwd, env, kind }; default: a terminal split
  transparent = false,              -- or a function; for transparent terminals
  width = 100,
  highlights = {},                  -- { ProjectRCAccent = { fg = "#a0c080" } }
  settings = {},                    -- extra settings, same shape as projectrc.schema
  keys = { edit = { "<CR>", "l" }, reset = "x", scope = "f", json = "e", trust = "T",
           next_tab = "<Tab>", prev_tab = "<S-Tab>", close = { "q", "<Esc>" } },
})
```

See `:help projectrc` for everything, and `:checkhealth projectrc`.
