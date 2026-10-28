-- The settings float (:ProjectRC): tabs Editor /
-- Format / LSP / Build / Debug in the winbar, one setting per line, each
-- showing its value and where it comes from:
--
--   ● project   set in .nvim/settings.json
--   ◆ [cpp]     set for this filetype only
--   ▣ .clangd   lives in that tool's own file
--   ○ default   inherited (nothing set)
--
-- It edits the project of the buffer it was opened from; edits apply live.
local project = require("projectrc")
local schema = require("projectrc.schema")
local store = require("projectrc.store")
local config = require("projectrc.config")
local hl = require("projectrc.ui.hl")

local M = {}

local ns = vim.api.nvim_create_namespace("project_ui")
local LABEL_W, VALUE_W = 28, 30

local ui = { tab = 1 }

local c_family = {}
for _, ft in ipairs(require("projectrc.clang_indent").filetypes) do c_family[ft] = true end

local function valid_win(w) return w and vim.api.nvim_win_is_valid(w) end
local function width(s) return vim.fn.strdisplaywidth(s) end

local function cell(text, w)
  text = tostring(text or "")
  if width(text) > w then
    local n = vim.fn.strchars(text)
    while n > 0 and width(vim.fn.strcharpart(text, 0, n)) > w - 1 do n = n - 1 end
    text = vim.fn.strcharpart(text, 0, n) .. "…"
  end
  return text .. (" "):rep(math.max(0, w - width(text)))
end

---------------------------------------------------------------------------
-- Values

local function show(v, s)
  if v == nil or v == "" then return "—" end
  if type(v) == "boolean" then return v and "on" or "off" end
  if s.type == "json" then return #v .. (#v == 1 and " configuration" or " configurations") end
  if type(v) == "table" then
    if vim.islist(v) then return table.concat(v, ", ") end
    local keys = vim.tbl_keys(v)
    table.sort(keys)
    return table.concat(vim.tbl_map(function(k) return k .. "=" .. tostring(v[k]) end, keys), " ")
  end
  return tostring(v)
end

-- C-family indent rows are views of .clang-format (owned by clang_indent).
local function redirected(s)
  return (s.key == "editor.indent" or s.key == "editor.tabs") and c_family[ui.ctx.ft]
end

-- value, origin text, marker, marker hl
local function describe(s)
  if redirected(s) then
    local bo = vim.bo[ui.ctx.buf]
    local v = s.key == "editor.indent" and bo.shiftwidth or not bo.expandtab
    return v, "from clang-format (Format tab)", "→", "ProjectRCMuted"
  end
  local v, origin, own = project.effective(ui.ctx.buf, s.key, ui.ctx)
  if own then
    origin = origin or "project"
    local mark = origin == "project" and "●" or origin:sub(1, 1) == "[" and "◆" or "▣"
    if s.exec and not store.trusted(ui.ctx.root) then return v, origin .. " · untrusted", "⊘", "ProjectRCWarn" end
    return v, origin, mark, "ProjectRCAccent"
  end
  return v, origin or "default", "○", "ProjectRCMuted"
end

---------------------------------------------------------------------------
-- Rendering

local function first_key(k)
  k = config.options.keys[k]
  if type(k) == "table" then k = k[1] end
  return k or nil
end

local function hints()
  local parts = {}
  for _, h in ipairs({ { "edit", "edit" }, { "reset", "reset" }, { "scope", "filetype scope" },
    { "json", "json" }, { "trust", "trust" }, { "next_tab", "tabs" }, { "close", "close" } }) do
    local k = first_key(h[1])
    if k then parts[#parts + 1] = k .. " " .. h[2] end
  end
  return table.concat(parts, "  ")
end

local function winbar()
  local parts = { " " }
  for i, name in ipairs(schema.tabs) do
    parts[#parts + 1] = (i == ui.tab and "%#ProjectRCTitle#" or "%#ProjectRCMuted#") .. name .. "%*  "
  end
  parts[#parts + 1] = "%=%#ProjectRCMuted#scope:%* %#ProjectRCAccent#"
    .. (ui.scope and ("[" .. ui.scope .. "]") or "project") .. "%* "
  return table.concat(parts)
end

local function render()
  if not valid_win(ui.win) then return end
  local ctx = ui.ctx
  local lines, marks = {}, {}
  local function add(segs)
    local line = ""
    for _, seg in ipairs(segs) do
      local start = #line
      line = line .. seg[1]
      if seg[2] then marks[#marks + 1] = { #lines, start, #line, seg[2] } end
    end
    lines[#lines + 1] = line
  end

  local exists = vim.uv.fs_stat(store.path(ctx.root)) ~= nil
  local trust = not exists and { "no settings file yet", "ProjectRCMuted" }
    or store.trusted(ctx.root) and { "trusted", "ProjectRCAccent" }
    or { "untrusted: build/debug/driver settings are off (" .. (first_key("trust") or ":ProjectRC trust") .. ")", "ProjectRCWarn" }
  local name = vim.fn.fnamemodify(ctx.root, ":~")
  local room = vim.api.nvim_win_get_width(ui.win) - width(trust[1]) - 9
  if width(name) > room then name = vim.fn.pathshorten(name) end
  add({ { "  " .. cell(name, math.min(width(name), room)), "ProjectRCTitle" }, { "  ·  ", "ProjectRCMuted" }, trust })
  add({})

  ui.rows = {}
  for _, s in ipairs(schema.list) do
    if s.tab == schema.tabs[ui.tab] then
      local v, origin, mark, hl = describe(s)
      local scoped_out = ui.scope and not s.ft
      ui.rows[#lines + 1] = s
      add({
        { "  " .. cell(s.label, LABEL_W), scoped_out and "ProjectRCMuted" or nil },
        { cell(show(v, s), VALUE_W), hl == "ProjectRCMuted" and "ProjectRCMuted" or nil },
        { mark .. " ", hl },
        { origin, "ProjectRCMuted" },
      })
    end
  end
  add({})
  add({ { "  " .. hints(), "ProjectRCMuted" } })

  vim.bo[ui.buf].modifiable = true
  vim.api.nvim_buf_set_lines(ui.buf, 0, -1, false, lines)
  vim.bo[ui.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(ui.buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(ui.buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  vim.wo[ui.win].winbar = winbar()
  local first = math.huge
  for l in pairs(ui.rows) do first = math.min(first, l) end
  ui.first = first
  local cur = vim.api.nvim_win_get_cursor(ui.win)[1]
  if not ui.rows[cur] then vim.api.nvim_win_set_cursor(ui.win, { first, 0 }) end
end

local function selected()
  return ui.rows and ui.rows[vim.api.nvim_win_get_cursor(ui.win)[1]]
end

-- The footer shows the selected setting's description.
local function footer()
  local s = selected()
  if not s or not valid_win(ui.win) then return end
  local w = vim.api.nvim_win_get_width(ui.win) - 4
  local text = s.desc .. (s.exec and " (runs code: needs trust)" or "")
  vim.api.nvim_win_set_config(ui.win, { footer = { { " " .. cell(text, w):gsub("%s+$", "") .. " ", "ProjectRCMuted" } },
    footer_pos = "center" })
end

local function set_tab(i)
  ui.tab = (i - 1) % #schema.tabs + 1
  render()
  footer()
end

---------------------------------------------------------------------------
-- Editing

local function commit(s, value)
  local ok, err = project.set(ui.ctx.root, s.key, value, s.ft and ui.scope or nil)
  if not ok and err ~= "cancelled" then vim.notify("projectrc: " .. s.label .. ": " .. err, vim.log.levels.WARN) end
  render()
end

-- Edit a list / dict / JSON value as JSON in a scratch float; :w commits.
local function edit_json(s, current)
  local templates = {
    json = { { name = "main", program = "build/main", args = {} } },
    dict = { KEY = "value" },
    list = {},
  }
  local text = store.encode(current or templates[s.type])
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(b, "projectrc://" .. s.key)
  vim.bo[b].buftype = "acwrite"
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].filetype = "json"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(text, "\n"))
  vim.bo[b].modified = false
  local h = math.min(vim.o.lines - 6, math.max(6, select(2, text:gsub("\n", "")) + 3))
  local w = math.min(vim.o.columns - 6, 72)
  local win = vim.api.nvim_open_win(b, true, {
    relative = "editor", row = math.floor((vim.o.lines - h) / 2), col = math.floor((vim.o.columns - w) / 2),
    width = w, height = h, border = "rounded", style = "minimal",
    title = " " .. s.label .. " ", title_pos = "center",
    footer = { { " :w save · empty = reset · q cancel ", "ProjectRCMuted" } }, footer_pos = "center",
  })
  vim.w[win].no_cursorline = true
  hl.style(win)
  ui.editing = true
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = b,
    callback = function()
      local src = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
      local value
      if src:match("%S") then
        local ok, decoded = pcall(vim.json.decode, src, { luanil = { object = true, array = true } })
        if not ok then return vim.notify("projectrc: invalid JSON: " .. decoded, vim.log.levels.ERROR) end
        value = decoded
      end
      vim.bo[b].modified = false
      vim.api.nvim_win_close(win, true)
      ui.editing = false
      if valid_win(ui.win) then vim.api.nvim_set_current_win(ui.win) end
      commit(s, value)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = b,
    callback = function()
      ui.editing = false
      vim.schedule(function() if valid_win(ui.win) then vim.api.nvim_set_current_win(ui.win) end end)
    end,
  })
end

local function edit()
  local s = selected()
  if not s then return end
  if ui.scope and not s.ft then
    return vim.notify("projectrc: " .. s.label .. " has no per-filetype value (f: back to project scope)")
  end
  if redirected(s) then
    set_tab(2)
    for l, row in pairs(ui.rows) do
      if row.key == "clang_format.indent" then vim.api.nvim_win_set_cursor(ui.win, { l, 0 }) end
    end
    return footer()
  end
  local current = project.effective(ui.ctx.buf, s.key, ui.ctx)
  if s.type == "bool" then
    commit(s, not current)
  elseif s.type == "enum" then
    ui.editing = true
    vim.ui.select(s.values, {
      prompt = s.label,
      format_item = function(v) return (v == current and "● " or "  ") .. v end,
    }, function(choice)
      ui.editing = false
      if choice then commit(s, choice) end
    end)
  elseif s.type == "int" or s.type == "string" then
    ui.editing = true
    vim.ui.input({ prompt = s.label .. " (empty = reset): ", default = current ~= nil and tostring(current) or "" },
      function(input)
        ui.editing = false
        if input == nil then return end
        commit(s, input ~= "" and input or nil)
      end)
  else
    local own = project.get(ui.ctx.buf, s.key, true)
    edit_json(s, own or (s.type == "list" and current) or nil)
  end
end

local function reset()
  local s = selected()
  if not s or redirected(s) then return end
  local _, origin = project.get(ui.ctx.buf, s.key, true)
  if not origin then return end
  local ft = origin:match("^%[(.+)%]$")
  local ok, err = project.set(ui.ctx.root, s.key, nil, ft)
  if not ok and err ~= "cancelled" then vim.notify("projectrc: " .. err, vim.log.levels.WARN) end
  render()
end

local function toggle_scope()
  if ui.ctx.ft == "" then return vim.notify("projectrc: the source buffer has no filetype") end
  ui.scope = not ui.scope and ui.ctx.ft or nil
  render()
end

local function open_json()
  local root = ui.ctx.root
  M.close()
  require("projectrc").json(root)
end

local function trust()
  require("projectrc").trust(ui.ctx.root)
  render()
end

---------------------------------------------------------------------------

function M.close()
  if ui.augroup then pcall(vim.api.nvim_del_augroup_by_id, ui.augroup) end
  ui.augroup = nil
  if valid_win(ui.win) then vim.api.nvim_win_close(ui.win, true) end
  ui.win, ui.buf = nil, nil
end

function M.open()
  if valid_win(ui.win) then return vim.api.nvim_set_current_win(ui.win) end
  ui.ctx = project.context(0)
  ui.scope = nil

  local w = math.min(LABEL_W + VALUE_W + 36, config.options.width, vim.o.columns - 4)
  local most = 0
  for _, tab in ipairs(schema.tabs) do
    local n = #vim.tbl_filter(function(s) return s.tab == tab end, schema.list)
    most = math.max(most, n)
  end
  local h = math.min(most + 4, vim.o.lines - 6)
  ui.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[ui.buf].bufhidden = "wipe"
  vim.bo[ui.buf].filetype = "projectrc"
  ui.win = vim.api.nvim_open_win(ui.buf, true, {
    relative = "editor", row = math.floor((vim.o.lines - h) / 2) - 1, col = math.floor((vim.o.columns - w) / 2),
    width = w, height = h, style = "minimal", border = "rounded",
    title = " Project settings ", title_pos = "center",
  })
  -- the cursorline is the selection
  vim.wo[ui.win].cursorline = true
  vim.wo[ui.win].cursorlineopt = "line"
  hl.style(ui.win, "CursorLine:ProjectRCSel")

  local function map(name, fn)
    local lhs = config.options.keys[name]
    if not lhs then return end
    for _, k in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      vim.keymap.set("n", k, fn, { buffer = ui.buf, nowait = true })
    end
  end
  map("edit", edit)
  map("reset", reset)
  map("scope", toggle_scope)
  map("json", open_json)
  map("trust", trust)
  map("next_tab", function() set_tab(ui.tab + 1) end)
  map("prev_tab", function() set_tab(ui.tab - 1) end)
  for i = 1, math.min(9, #schema.tabs) do
    vim.keymap.set("n", tostring(i), function() set_tab(i) end, { buffer = ui.buf, nowait = true })
  end
  map("close", M.close)

  ui.augroup = vim.api.nvim_create_augroup("project_ui", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = ui.augroup,
    buffer = ui.buf,
    callback = function()
      local l = vim.api.nvim_win_get_cursor(ui.win)[1]
      if not ui.rows[l] then
        -- skip the header/blank/hint lines
        local best
        for row in pairs(ui.rows) do
          if not best or math.abs(row - l) < math.abs(best - l) then best = row end
        end
        if best then vim.api.nvim_win_set_cursor(ui.win, { best, 0 }) end
      end
      footer()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = ui.augroup,
    pattern = "ProjectRCChanged",
    callback = function() vim.schedule(render) end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = ui.augroup,
    callback = function()
      if valid_win(ui.win) then hl.style(ui.win, "CursorLine:ProjectRCSel") end
      render()
    end,
  })
  -- close when focus leaves for anything but our own prompts/editors
  vim.api.nvim_create_autocmd("WinLeave", {
    group = ui.augroup,
    buffer = ui.buf,
    callback = function()
      vim.schedule(function()
        if ui.win and not ui.editing and vim.api.nvim_get_current_win() ~= ui.win then M.close() end
      end)
    end,
  })
  set_tab(ui.tab)
end

return M
