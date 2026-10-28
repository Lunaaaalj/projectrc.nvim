-- C-family indentation follows clang-format, so `>>`/`=`/<Tab> and
-- format-on-save can never disagree. clang-format is the single source of
-- truth: the nearest .clang-format if there is one, else the configured
-- `fallback_style` (hand `style_args()` to your formatter too; see
-- projectrc.clang_format_args).
--
-- `--fallback-style` only accepts a style *name*, so the fallback is passed as
-- `--style=<inline>` and only when no .clang-format exists above the file.
local config = require("projectrc.config")

local M = {}

M.filetypes = { "c", "cpp", "objc", "objcpp", "cuda", "proto" }

local style_files = { ".clang-format", "_clang-format" }

-- Nearest .clang-format above `path`, or nil.
function M.style_file(path)
  return vim.fs.find(style_files, { upward = true, path = vim.fs.dirname(path), type = "file" })[1]
end

-- Extra clang-format args for `path`: the fallback style when no style file
-- applies, nothing otherwise (clang-format finds the file itself).
function M.style_args(path)
  if path == "" or M.style_file(path) then return {} end
  return { "--style=" .. config.options.fallback_style }
end

-- style file (or "<none>") -> { mtime, eff = { TopLevelKey = value } }
local cache = {}

-- Top-level `Key: value` scalars of a --dump-config.
local function parse(dump)
  local eff = {}
  for line in dump:gmatch("[^\n]+") do
    local k, v = line:match("^(%w+):%s*(.-)%s*$")
    if k and v ~= "" then eff[k] = tonumber(v) or (v:gsub("^'(.*)'$", "%1")) end
  end
  return eff
end

local function indent_of(eff)
  return {
    width = tonumber(eff.IndentWidth) or 4,
    tab = tonumber(eff.TabWidth) or 8,
    use_tab = (eff.UseTab or "Never") ~= "Never",
  }
end

local function set(buf, eff)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local ind, bo = indent_of(eff), vim.bo[buf]
  bo.shiftwidth = ind.width
  bo.softtabstop = ind.width
  bo.expandtab = not ind.use_tab
  -- With real tabs a tab must look like an indent level; with spaces, keep
  -- clang-format's TabWidth so existing tabs render as the formatter sees them.
  bo.tabstop = ind.use_tab and ind.width or ind.tab
end

-- Cache key + the clang-format command for `path`, or nil.
local function lookup(path)
  if path == "" or vim.fn.executable("clang-format") == 0 then return nil end
  local file = M.style_file(path)
  local st = file and vim.uv.fs_stat(file)
  local mtime = st and (st.mtime.sec .. "." .. st.mtime.nsec) or 0
  local cmd = { "clang-format", "--dump-config", "--assume-filename=" .. path }
  vim.list_extend(cmd, M.style_args(path))
  return file or "<none>", mtime, cmd
end

local function store(key, mtime, r)
  -- a broken style file: keep the global options
  if r.code ~= 0 then return nil end
  local eff = parse(r.stdout)
  cache[key] = { mtime = mtime, eff = eff }
  return eff
end

-- clang-format's effective top-level options for `path` (sync; cached).
function M.effective(path)
  local key, mtime, cmd = lookup(path)
  if not key then return nil end
  local hit = cache[key]
  if hit and hit.mtime == mtime then return hit.eff end
  return store(key, mtime, vim.system(cmd, { text = true, cwd = vim.fs.dirname(path) }):wait())
end

-- Resolve and apply the indent for `buf` (async; cached per style file+mtime).
function M.apply(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local path = vim.api.nvim_buf_get_name(buf)
  local key, mtime, cmd = lookup(path)
  if not key then return end
  local hit = cache[key]
  if hit and hit.mtime == mtime then return set(buf, hit.eff) end
  vim.system(cmd, { text = true, cwd = vim.fs.dirname(path) }, function(r)
    local eff = store(key, mtime, r)
    if eff then vim.schedule(function() set(buf, eff) end) end
  end)
end

-- Re-apply to every loaded C-family buffer below `dir` (a style file changed).
function M.refresh(dir)
  local fts = {}
  for _, ft in ipairs(M.filetypes) do fts[ft] = true end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and fts[vim.bo[buf].filetype]
      and (not dir or vim.startswith(name, dir .. "/")) then
      M.apply(buf)
    end
  end
end

function M.setup(group)
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = M.filetypes,
    callback = function(ev) M.apply(ev.buf) end,
  })
  -- The mtime key already catches edits on the next FileType; this updates the
  -- buffers that are already open.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = style_files,
    callback = function(ev) M.refresh(vim.fs.dirname(vim.api.nvim_buf_get_name(ev.buf))) end,
  })
end

return M
