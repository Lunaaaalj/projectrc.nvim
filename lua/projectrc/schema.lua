-- Every project setting, in UI order. This table is the only definition: the
-- UI rows, validation, the appliers and the docs all read it.
--
--   key        dotted name; the JSON key (or the native file's key, see store)
--   tab        UI tab
--   type       bool | int | string | enum | list | dict | json (free-form JSON)
--   values     enum choices
--   ft         may be overridden per filetype ("[cpp]": { ... })
--   exec       runs something: ignored until .nvim/settings.json is trusted
--   store      "json" (default) or a native backend in project/native.lua
--   inherited  fun(ctx) -> value, origin: what applies when unset
--              (ctx = { buf, root, ft, path })
local M = {}

M.tabs = { "Editor", "Format", "LSP", "Build", "Debug" }

local function opt(name)
  return function(ctx)
    return require("projectrc.apply").original(ctx.buf, name), "default"
  end
end

-- clang-format's effective value for the source file (sync dump, cached).
local function clang(field)
  return function(ctx)
    local eff = require("projectrc.clang_indent").effective(ctx.path ~= "" and ctx.path or ctx.root .. "/x.cpp")
    if not eff then return nil, "clang-format" end
    local file = require("projectrc.clang_indent").style_file(ctx.path ~= "" and ctx.path or ctx.root .. "/x.cpp")
    return eff[field], file and "clang-format default" or "fallback style"
  end
end

M.list = {
  -- Editor ------------------------------------------------------------------
  { key = "editor.indent", tab = "Editor", label = "Indent width", type = "int", ft = true,
    desc = "shiftwidth/softtabstop. C-family files take this from .clang-format (Format tab).",
    inherited = opt("shiftwidth") },
  { key = "editor.tabs", tab = "Editor", label = "Indent with tabs", type = "bool", ft = true,
    desc = "noexpandtab, with tabstop = indent width.",
    inherited = function(ctx)
      return not require("projectrc.apply").original(ctx.buf, "expandtab"), "default"
    end },
  { key = "editor.textwidth", tab = "Editor", label = "Text width", type = "int", ft = true,
    desc = "Hard wrap column for gq and auto-wrap (0 = off).", inherited = opt("textwidth") },
  { key = "editor.colorcolumn", tab = "Editor", label = "Ruler columns", type = "string", ft = true,
    desc = "colorcolumn, e.g. \"80\" or \"80,120\" or \"+1\" (textwidth + 1).", inherited = opt("colorcolumn") },
  { key = "editor.wrap", tab = "Editor", label = "Soft wrap", type = "bool", ft = true,
    desc = "Wrap long lines on screen.", inherited = opt("wrap") },
  { key = "editor.spell", tab = "Editor", label = "Spell check", type = "bool", ft = true,
    desc = "Spell checking in this project's buffers.", inherited = opt("spell") },

  -- Format ------------------------------------------------------------------
  { key = "format.on_save", tab = "Format", label = "Format on save", type = "bool", ft = true,
    desc = "Run the formatter on :w (through projectrc.format_opts).",
    inherited = function() return true, "formatter config" end },
  { key = "format.formatters", tab = "Format", label = "Formatters", type = "list", ft = true,
    desc = "conform.nvim formatter names for this filetype, run in order.",
    inherited = function(ctx)
      local ok, conform = pcall(require, "conform")
      local list = ok and conform.list_formatters_to_run and vim.tbl_map(function(f) return f.name end,
        (conform.list_formatters_to_run(ctx.buf))) or nil
      return list, "conform"
    end },
  { key = "clang_format.style", tab = "Format", label = "clang-format base style", type = "enum",
    values = { "LLVM", "Google", "Chromium", "Mozilla", "WebKit", "Microsoft", "GNU" }, store = "clang_format",
    desc = "BasedOnStyle in .clang-format; the other keys override it.",
    inherited = function(ctx)
      local file = require("projectrc.clang_indent").style_file(ctx.root .. "/x.cpp")
      return "LLVM", file and "clang-format default" or "fallback style"
    end },
  { key = "clang_format.indent", tab = "Format", label = "clang-format indent", type = "int", store = "clang_format",
    desc = "IndentWidth in .clang-format. C/C++ buffers indent with this too.", inherited = clang("IndentWidth") },
  { key = "clang_format.use_tab", tab = "Format", label = "clang-format tabs", type = "enum",
    values = { "Never", "ForIndentation", "ForContinuationAndIndentation", "AlignWithSpaces", "Always" },
    store = "clang_format", desc = "UseTab in .clang-format.", inherited = clang("UseTab") },
  { key = "clang_format.column_limit", tab = "Format", label = "clang-format column limit", type = "int",
    store = "clang_format", desc = "ColumnLimit in .clang-format (0 = no limit).", inherited = clang("ColumnLimit") },

  -- LSP ---------------------------------------------------------------------
  { key = "lsp.disabled", tab = "LSP", label = "Disabled servers", type = "list",
    desc = "Language servers that must not attach in this project (e.g. [\"ruff\"]).",
    inherited = function() return nil, "none" end },
  { key = "clangd.std", tab = "LSP", label = "clangd language standard", type = "string", store = "clangd",
    desc = "-std= for files without a compile database entry, e.g. c++20 or c17.",
    inherited = function() return nil, "clangd default" end },
  { key = "clangd.flags", tab = "LSP", label = "clangd extra flags", type = "list", store = "clangd",
    desc = "CompileFlags.Add in .clangd: include dirs, defines, warnings (-Iinclude, -DDEBUG, -Wall).",
    inherited = function() return nil, "none" end },
  { key = "clangd.compile_commands_dir", tab = "LSP", label = "compile_commands.json dir", type = "string",
    store = "clangd", desc = "CompileFlags.CompilationDatabase in .clangd, relative to the project (e.g. build).",
    inherited = function() return nil, "searched upward" end },
  { key = "clangd.query_driver", tab = "LSP", label = "clangd query driver", type = "string", exec = true,
    desc = "--query-driver glob so clangd asks a cross compiler for its system includes (e.g. /opt/arm/bin/*-gcc). Restarts clangd.",
    inherited = function() return nil, "none" end },
  { key = "pyright.venv", tab = "LSP", label = "Python environment", type = "string", exec = true,
    desc = "A venv dir (relative to the project) whose python pyright resolves imports with.",
    inherited = function() return nil, "auto" end },
  { key = "pyright.type_checking", tab = "LSP", label = "pyright type checking", type = "enum",
    values = { "off", "basic", "standard", "strict" }, desc = "python.analysis.typeCheckingMode.",
    inherited = function() return "basic", "config" end },

  -- Build -------------------------------------------------------------------
  { key = "build.cmd", tab = "Build", label = "Build command", type = "string", exec = true,
    desc = "Run with :ProjectRC build (shell syntax). Runs through the configured runner.",
    inherited = function() return nil, "none" end },
  { key = "build.run", tab = "Build", label = "Run command", type = "string", exec = true,
    desc = ":ProjectRC run.", inherited = function() return nil, "none" end },
  { key = "build.test", tab = "Build", label = "Test command", type = "string", exec = true,
    desc = ":ProjectRC test.", inherited = function() return nil, "none" end },
  { key = "build.cwd", tab = "Build", label = "Working directory", type = "string",
    desc = "Where the commands run, relative to the project root.",
    inherited = function() return ".", "project root" end },
  { key = "build.env", tab = "Build", label = "Environment", type = "dict", exec = true,
    desc = "Extra environment variables for the build/run/test commands.",
    inherited = function() return nil, "none" end },

  -- Debug -------------------------------------------------------------------
  { key = "debug.configurations", tab = "Debug", label = "Launch configurations", type = "json", exec = true,
    desc = "nvim-dap launch configs listed first when debugging: { name, program, args, cwd, env, type }. "
      .. "Paths are relative to the project; type defaults by filetype (codelldb / python).",
    inherited = function() return nil, "none" end },
}

M.by_key = {}
for _, s in ipairs(M.list) do M.by_key[s.key] = s end

-- Add (or replace, by key) settings from setup({ settings = ... }); a new
-- `tab` gets its own tab after the built-in ones.
function M.extend(list)
  for _, s in ipairs(list or {}) do
    assert(s.key and s.tab and s.type and s.label, "projectrc: a setting needs key, tab, type and label")
    s.desc = s.desc or ""
    s.inherited = s.inherited or function() return nil, "none" end
    if M.by_key[s.key] then
      for i, old in ipairs(M.list) do if old.key == s.key then M.list[i] = s end end
    else
      M.list[#M.list + 1] = s
    end
    M.by_key[s.key] = s
    if not vim.tbl_contains(M.tabs, s.tab) then M.tabs[#M.tabs + 1] = s.tab end
  end
end

-- Is `v` acceptable for setting `s`? Returns the normalized value or nil, err.
function M.check(s, v)
  local t = s.type
  if t == "bool" then
    if type(v) == "boolean" then return v end
  elseif t == "int" then
    local n = tonumber(v)
    if n and n >= 0 and n == math.floor(n) then return n end
    return nil, "expected a whole number"
  elseif t == "string" then
    if type(v) == "string" or type(v) == "number" then return tostring(v) end
  elseif t == "enum" then
    if vim.tbl_contains(s.values, v) then return v end
    return nil, "expected one of " .. table.concat(s.values, ", ")
  elseif t == "list" then
    if type(v) == "table" and vim.islist(v)
      and vim.iter(v):all(function(x) return type(x) == "string" end) then return v end
    return nil, "expected a list of strings"
  elseif t == "dict" then
    if type(v) == "table" and (next(v) == nil or not vim.islist(v)) then return v end
    return nil, "expected an object"
  elseif t == "json" then
    if type(v) == "table" then return v end
  end
  return nil, "expected a " .. t
end

return M
