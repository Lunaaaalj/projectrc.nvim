-- projectrc.nvim: per-project settings, VS Code style. A settings file at the
-- project root (default .nvim/settings.json; flat dotted keys + "[ft]"
-- overrides), edited through a float (:ProjectRC). Settings another tool reads
-- (clang-format, clangd) live in that tool's own file instead (native.lua).
-- The schema (schema.lua) defines every setting; apply.lua pushes them into
-- options, the formatter, LSP, the build runner and nvim-dap.
local config = require("projectrc.config")
local store = require("projectrc.store")
local schema = require("projectrc.schema")
local native = require("projectrc.native")

local M = {}

M.root = store.root

local function ft_key(ft) return "[" .. ft .. "]" end

-- Raw project value of `key` for a buffer, honouring "[ft]" overrides.
-- Returns value, origin ("project" | "[ft]" | ".clang-format" | ".clangd").
-- `exec` settings read as nil while the file is untrusted, unless `untrusted`.
function M.get(buf, key, untrusted)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  return M.get_at(store.root(buf), vim.bo[buf].filetype, key, untrusted)
end

-- M.get for a project root + filetype (ft may be "" or nil) instead of a buffer.
function M.get_at(root, ft, key, untrusted)
  local s = schema.by_key[key]
  if s.store then
    local b = native.backends[s.store]
    local v = b.get(root, key)
    if v ~= nil then return v, b.file end
    return nil
  end
  if s.exec and not untrusted and not store.trusted(root) then return nil end
  local data = store.load(root)
  local scoped = s.ft and ft and ft ~= "" and data[ft_key(ft)]
  if type(scoped) == "table" and scoped[key] ~= nil then return scoped[key], ft_key(ft) end
  if data[key] ~= nil then return data[key], "project" end
end

-- What's in effect: the project value, else the inherited one.
-- Returns value, origin, from_project.
function M.effective(buf, key, ctx)
  local v, origin = M.get(buf, key, true)
  if v ~= nil then return v, origin, true end
  ctx = ctx or M.context(buf)
  local iv, io = schema.by_key[key].inherited(ctx)
  return iv, io, false
end

function M.context(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  return { buf = buf, root = store.root(buf), ft = vim.bo[buf].filetype, path = vim.api.nvim_buf_get_name(buf) }
end

-- Set `key` in `root` (nil removes it). `ft` writes the "[ft]" override.
-- Returns true, or false + reason.
function M.set(root, key, value, ft)
  local s = schema.by_key[key]
  if value ~= nil then
    local err
    value, err = schema.check(s, value)
    if value == nil then return false, err end
    -- an empty list/dict means "unset", so the inherited value shows through
    if type(value) == "table" and next(value) == nil then value = nil end
  end
  if s.store then
    local ok = native.backends[s.store].set(root, key, value)
    if ok then store.changed(root) end
    return ok, not ok and "cancelled" or nil
  end
  local data = vim.deepcopy(store.load(root))
  if ft and s.ft then
    local t = data[ft_key(ft)] or {}
    t[key] = value
    data[ft_key(ft)] = next(t) and t or nil
  else
    data[key] = value
  end
  store.save(root, data)
  return true
end

---------------------------------------------------------------------------
-- Integrations: hand these to the tools (see :help projectrc-integrations)

-- conform.nvim: false = skip format-on-save; else extra conform.format() opts.
function M.format_opts(buf, on_save) return require("projectrc.apply").format_opts(buf or 0, on_save) end

-- clangd's `cmd` (adds --query-driver): vim.lsp.config("clangd", { cmd = require("projectrc").clangd_cmd })
function M.clangd_cmd(dispatchers, cfg) return require("projectrc.apply").clangd_cmd(dispatchers, cfg) end

-- Extra clang-format args for `path` (the fallback style when no .clang-format applies).
function M.clang_format_args(path) return require("projectrc.clang_indent").style_args(path) end

-- Re-insert the current project's launch configs at the top of dap.configurations.
function M.dap_sync(buf) require("projectrc.apply").dap(buf) end

-- Run the project's build ("cmd"), run or test command through `runner`.
function M.build(kind) require("projectrc.apply").build(kind or "cmd") end

function M.open() require("projectrc.ui").open() end

-- Trust the current project's settings file (vim.secure prompt if needed).
function M.trust(root)
  root = root or store.root(0)
  if store.ensure_trusted(root) then store.changed(root) end
end

function M.json(root)
  root = root or store.root(0)
  local path = store.path(root)
  if not vim.uv.fs_stat(path) then store.save(root, {}) end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

function M.setup(opts)
  config.setup(opts)
  schema.extend(config.options.settings)
  local group = vim.api.nvim_create_augroup("projectrc", { clear = true })
  require("projectrc.ui.hl").setup()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = require("projectrc.ui.hl").setup })
  -- hand edits (or `e` in the UI) re-apply like UI edits do
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*/" .. config.options.file, "*/.clangd" },
    callback = function(ev)
      store.changed(store.root(vim.api.nvim_buf_get_name(ev.buf)))
    end,
  })
  if config.options.clang_indent then require("projectrc.clang_indent").setup(group) end
  require("projectrc.apply").setup(group)
  -- buffers opened before setup() (lazy-loading, a file on the command line)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype ~= "" then
      vim.api.nvim_exec_autocmds("FileType", { group = group, buffer = buf })
    end
  end
end

return M
