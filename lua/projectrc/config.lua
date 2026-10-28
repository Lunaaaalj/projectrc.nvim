-- Defaults, merged with setup() opts into M.options.

local M = {}

-- Open a terminal split at the bottom and run `cmd` there (shell syntax).
local function default_runner(cmd, ctx)
  vim.cmd("botright 12new")
  vim.fn.jobstart({ vim.o.shell, "-c", cmd }, { term = true, cwd = ctx.cwd, env = ctx.env })
  vim.cmd("startinsert")
end

M.defaults = {
  -- the settings file, relative to the project root
  file = ".nvim/settings.json",
  -- project root = nearest directory holding one of these, in priority order
  -- (the settings file's directory is always tried first)
  markers = { ".git", "compile_commands.json", "CMakeLists.txt" },
  -- C-family indentation follows clang-format (shiftwidth/tabstop/expandtab
  -- from `clang-format --dump-config`), so typing and formatting agree
  clang_indent = true,
  -- style clang-format uses when no .clang-format applies; also what a new
  -- .clang-format created from the UI starts with. Inline YAML, or a style
  -- name like "Google". Hand clang_format_args() to your formatter.
  fallback_style = "{BasedOnStyle: LLVM, IndentWidth: 4}",
  -- runs build.cmd / build.run / build.test:
  --   fun(cmd: string, ctx: { root, cwd, env: table<string,string>, kind: "cmd"|"run"|"test" })
  runner = default_runner,
  -- draw the float without a background (for transparent terminals);
  -- a boolean or a function returning one, read every time the float opens
  transparent = false,
  -- the float's size cap
  width = 100,
  -- highlight overrides: { ProjectRCAccent = { fg = "#a0c080" }, ... }
  highlights = {},
  -- extra settings appended to the schema (same shape as projectrc.schema)
  settings = {},
  -- float-local keys; set one to false to disable it
  keys = {
    edit = { "<CR>", "l" },
    reset = "x",
    scope = "f",
    json = "e",
    trust = "T",
    next_tab = "<Tab>",
    prev_tab = "<S-Tab>",
    close = { "q", "<Esc>" },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- lists are replaced, not merged index by index
  if opts and opts.markers then M.options.markers = opts.markers end
  if opts and opts.settings then M.options.settings = opts.settings end
end

function M.transparent()
  local t = M.options.transparent
  if type(t) == "function" then return t() == true end
  return t == true
end

return M
