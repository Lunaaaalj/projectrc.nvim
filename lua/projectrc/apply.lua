-- Pushes project settings into Neovim and the tools: buffer/window options,
-- conform (via format_opts), LSP (pyright settings, clangd's command line,
-- disabled servers), the build terminal and nvim-dap. Every applier is
-- idempotent and runs again on `User ProjectRCChanged`.
local store = require("projectrc.store")

local M = {}

local function P() return require("projectrc") end

local c_family = {}
for _, ft in ipairs(require("projectrc.clang_indent").filetypes) do c_family[ft] = true end

local function regular(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

---------------------------------------------------------------------------
-- Editor options

local win_opts = { wrap = true, spell = true, colorcolumn = true }

local function current(buf, opt)
  if not win_opts[opt] then return vim.bo[buf][opt] end
  local win = vim.fn.bufwinid(buf)
  return win ~= -1 and vim.wo[win][opt] or vim.go[opt]
end

-- The value an option had before the project touched it (for "inherited").
function M.original(buf, opt)
  local saved = vim.b[buf].project_saved or {}
  if saved[opt] ~= nil then return saved[opt] end
  return current(buf, opt)
end

local function set_opt(buf, opt, value)
  if win_opts[opt] then
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.api.nvim_set_option_value(opt, value, { scope = "local", win = win })
    end
  else
    vim.bo[buf][opt] = value
  end
end

-- option -> desired value from the project, or nil (= leave/restore).
local function desired(buf)
  local get = function(k) return P().get(buf, k) end
  local want = {}
  if not c_family[vim.bo[buf].filetype] then -- C-family indent is clang-format's
    local indent, tabs = get("editor.indent"), get("editor.tabs")
    if indent then want.shiftwidth, want.softtabstop = indent, indent end
    if tabs ~= nil then
      want.expandtab = not tabs
      if tabs then want.tabstop = indent or vim.bo[buf].shiftwidth end
    end
  end
  want.textwidth = get("editor.textwidth")
  want.colorcolumn = get("editor.colorcolumn")
  want.wrap = get("editor.wrap")
  want.spell = get("editor.spell")
  return want
end

local managed = { "shiftwidth", "softtabstop", "expandtab", "tabstop", "textwidth", "colorcolumn", "wrap", "spell" }

function M.editor(buf)
  if not regular(buf) then return end
  local want = desired(buf)
  local saved = vim.b[buf].project_saved or {}
  for _, opt in ipairs(managed) do
    if want[opt] ~= nil then
      if saved[opt] == nil then saved[opt] = current(buf, opt) end
      set_opt(buf, opt, want[opt])
    elseif saved[opt] ~= nil then
      set_opt(buf, opt, saved[opt]) -- the setting was removed: put it back
      saved[opt] = nil
    end
  end
  vim.b[buf].project_saved = saved
end

---------------------------------------------------------------------------
-- Formatting (projectrc.format_opts, for conform.nvim or any formatter)

-- false = don't format on save; a table = extra conform.format() options.
function M.format_opts(buf, on_save)
  if on_save and P().get(buf, "format.on_save") == false then return false end
  local list = P().get(buf, "format.formatters")
  return list and { formatters = list } or {}
end

---------------------------------------------------------------------------
-- LSP

-- clangd's command line (projectrc.clangd_cmd, set as clangd's `cmd`):
-- --query-driver can't go in .clangd, and it's `exec`, so trusted files only.
function M.clangd_cmd(dispatchers, config)
  local cmd = { "clangd" }
  local qd = config.root_dir and P().get_at(store.root(config.root_dir), nil, "clangd.query_driver")
  if qd then cmd[#cmd + 1] = "--query-driver=" .. qd end
  return vim.lsp.rpc.start(cmd, dispatchers, {
    cwd = config.cmd_cwd or config.root_dir, env = config.cmd_env, detached = config.detached,
  })
end

local function pyright_settings(client, buf)
  client._project_base = client._project_base or vim.deepcopy(client.settings or {})
  local s = vim.deepcopy(client._project_base)
  local root = store.root(buf)
  local venv = P().get(buf, "pyright.venv")
  local mode = P().get(buf, "pyright.type_checking")
  if venv then
    local dir = venv:sub(1, 1) == "/" and venv or root .. "/" .. venv
    s = vim.tbl_deep_extend("force", s, { python = { pythonPath = vim.fs.normalize(dir) .. "/bin/python" } })
  end
  if mode then s = vim.tbl_deep_extend("force", s, { python = { analysis = { typeCheckingMode = mode } } }) end
  if vim.deep_equal(s, client.settings) then return end
  client.settings = s
  client:notify("workspace/didChangeConfiguration", { settings = s })
end

local function detach_if_disabled(client, buf)
  local disabled = P().get(buf, "lsp.disabled")
  if not (disabled and vim.tbl_contains(disabled, client.name)) then return false end
  vim.schedule(function()
    if not vim.lsp.buf_is_attached(buf, client.id) then return end
    vim.lsp.buf_detach_client(buf, client.id)
    if vim.tbl_isempty(client.attached_buffers) then client:stop() end
  end)
  return true
end

local function lsp_attach(ev)
  local client = vim.lsp.get_client_by_id(ev.data.client_id)
  if not client or detach_if_disabled(client, ev.buf) then return end
  if client.name == "pyright" then pyright_settings(client, ev.buf) end
  if client.name == "clangd" then
    client._project_qd = client._project_qd
      or P().get(ev.buf, "clangd.query_driver") or false
  end
end

-- Settings changed under `root`: update or restart the clients serving it.
local function lsp_refresh(root)
  for _, client in ipairs(vim.lsp.get_clients()) do
    local buf = next(client.attached_buffers)
    if buf and store.root(buf) == root then
      if not detach_if_disabled(client, buf) then
        if client.name == "pyright" then pyright_settings(client, buf) end
        if client.name == "clangd" and (P().get(buf, "clangd.query_driver") or false) ~= client._project_qd then
          pcall(vim.cmd, "LspRestart clangd")
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Build / run / test

local function abs(root, p)
  if not p or p == "" then return root end
  return vim.fs.normalize(p:sub(1, 1) == "/" and p or root .. "/" .. p)
end

-- kind: "cmd" (build) | "run" | "test"
function M.build(kind)
  local buf = vim.api.nvim_get_current_buf()
  local root = store.root(buf)
  local key = "build." .. kind
  local cmd = P().get(buf, key, true)
  if not cmd then
    return vim.notify(("projectrc: no %s for %s (set it in :ProjectRC, Build tab)"):format(key, vim.fn.fnamemodify(root, ":~")),
      vim.log.levels.WARN)
  end
  if not store.ensure_trusted(root) then
    return vim.notify("projectrc: the settings file isn't trusted; not running " .. key, vim.log.levels.WARN)
  end
  local env = {}
  for k, v in pairs(P().get(buf, "build.env") or {}) do env[k] = tostring(v) end
  require("projectrc.config").options.runner(cmd, {
    root = root, cwd = abs(root, P().get(buf, "build.cwd")), env = env, kind = kind,
  })
end

---------------------------------------------------------------------------
-- nvim-dap

local adapter_fts = { codelldb = { "c", "cpp", "rust" }, python = { "python" } }
local default_type = { c = "codelldb", cpp = "codelldb", rust = "codelldb", python = "python" }

-- Put the current project's launch configs first in dap.configurations.
function M.dap(buf)
  if not package.loaded.dap then return end
  buf = buf or vim.api.nvim_get_current_buf()
  if not regular(buf) then return end
  local dap = require("dap")
  local root = store.root(buf)
  for ft, list in pairs(dap.configurations) do
    dap.configurations[ft] = vim.tbl_filter(function(c) return not c.project_root end, list)
  end
  local configs = P().get(buf, "debug.configurations") or {}
  for i = #configs, 1, -1 do
    local c = vim.deepcopy(configs[i])
    c.type = c.type or default_type[vim.bo[buf].filetype]
    if c.type then
      c.name = (c.name or c.program or "launch") .. " (project)"
      c.request = c.request or "launch"
      if c.program then c.program = abs(root, c.program) end
      c.cwd = abs(root, c.cwd)
      c.project_root = root
      for _, ft in ipairs(c.filetypes or adapter_fts[c.type] or { vim.bo[buf].filetype }) do
        dap.configurations[ft] = dap.configurations[ft] or {}
        table.insert(dap.configurations[ft], 1, c)
      end
      c.filetypes = nil
    end
  end
end

---------------------------------------------------------------------------

function M.setup(group)
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    -- scheduled: ftplugins (registered after init.lua) run on FileType too
    callback = function(ev) vim.schedule(function() M.editor(ev.buf) end) end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev) M.editor(ev.buf) end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev) M.dap(ev.buf) end,
  })
  -- nvim-dap loaded lazily (lazy.nvim): add the configs as soon as it's there
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LazyLoad",
    callback = function(ev) if ev.data == "nvim-dap" then vim.schedule(function() M.dap() end) end end,
  })
  vim.api.nvim_create_autocmd("LspAttach", { group = group, callback = lsp_attach })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ProjectRCChanged",
    callback = function(ev)
      local root = ev.data.root
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and regular(buf) and store.root(buf) == root then M.editor(buf) end
      end
      lsp_refresh(root)
      M.dap()
    end,
  })
end

return M
