-- Settings whose real home is another tool's config file. Those files are the
-- storage: the UI reads them back and writes them in place, so clang-format
-- from a shell, clangd, CI and other editors all see the same values.
--
--   .clang-format  top-level `Key: value` lines we manage are replaced in
--                  place (or appended); comments and other keys are kept.
--   .clangd        our values live in a separate YAML document between
--                  markers; clangd merges every `---` fragment, so the rest of
--                  the file is left alone.
--
-- The first write to a file we didn't create asks first; afterwards a header
-- line marks it as shared with the settings UI.
local M = {}

local HEADER = "# Some keys are edited by projectrc.nvim (:ProjectRC)."
local BEGIN, END = "# >>> projectrc.nvim", "# <<< projectrc.nvim"

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return vim.split(text, "\n", { plain = true })
end

local function write(path, lines)
  if lines[#lines] ~= "" then lines[#lines + 1] = "" end
  local f = assert(io.open(path, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
  -- a buffer showing the file would otherwise hold stale text
  local buf = vim.fn.bufnr(path)
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
    vim.api.nvim_buf_call(buf, function() vim.cmd("checktime") end)
  end
end

-- May we edit `path`? New files and files carrying our header: yes.
-- Otherwise show the change and ask once.
local function permitted(path, old, new)
  if not old or vim.tbl_contains(old, HEADER) then return true end
  -- vim.text.diff is 0.12+; vim.diff before
  local diff = (vim.text.diff or vim.diff)(table.concat(old, "\n"), table.concat(new, "\n"), { ctxlen = 1 })
  local choice = vim.fn.confirm(
    ("%s exists and wasn't made here. Apply this change?\n\n%s"):format(vim.fn.fnamemodify(path, ":~:."), diff),
    "&Yes\n&No", 2)
  return choice == 1
end

---------------------------------------------------------------------------
-- .clang-format

M.clang_keys = {
  ["clang_format.style"] = "BasedOnStyle",
  ["clang_format.indent"] = "IndentWidth",
  ["clang_format.column_limit"] = "ColumnLimit",
  ["clang_format.use_tab"] = "UseTab",
}

local function clang_path(root) return root .. "/.clang-format" end

local function scalar(raw)
  if raw == nil then return nil end
  raw = vim.trim((raw:gsub("%s+#.*$", "")))
  return tonumber(raw) or (raw:gsub("^['\"](.*)['\"]$", "%1"))
end

-- Value of `key` in the root's .clang-format (first YAML document only).
function M.clang_get(root, key)
  local lines = read(clang_path(root))
  if not lines then return nil end
  local yaml_key = M.clang_keys[key]
  local content = false
  for _, l in ipairs(lines) do
    if (l == "---" or l == "...") and content then break end
    local v = l:match("^" .. yaml_key .. ":%s*(.-)%s*$")
    if v then return scalar(v) end
    content = content or (l:match("^%s*[^#%s-]") ~= nil)
  end
end

-- Set (or with nil, remove) `key` in the root's .clang-format. Returns ok.
function M.clang_set(root, key, value)
  local path = clang_path(root)
  local old = read(path)
  local lines = old and vim.deepcopy(old) or { HEADER }
  if not old then
    -- seed with the fallback style these files were formatted with, so
    -- setting one key doesn't silently change the rest
    local fallback = require("projectrc.config").options.fallback_style
    -- a bare style name ("Google") is a BasedOnStyle
    if not fallback:match("^{") then fallback = "{BasedOnStyle: " .. fallback .. "}" end
    for pair in fallback:gsub("^{", ""):gsub("}$", ""):gmatch("[^,]+") do
      lines[#lines + 1] = vim.trim(pair)
    end
  end
  local yaml_key = M.clang_keys[key]
  -- the first document ends at the first `---`/`...` that follows content
  local found, doc_end, content = nil, nil, false
  for i, l in ipairs(lines) do
    if (l == "---" or l == "...") and content then doc_end = i; break end
    if l:match("^" .. yaml_key .. ":") then found = i end
    content = content or (l:match("^%s*[^#%s-]") ~= nil)
  end
  local entry = value ~= nil and (yaml_key .. ": " .. tostring(value)) or nil
  if found then
    if entry then
      lines[found] = entry .. (lines[found]:match("%s+#.*$") or "") -- keep a trailing comment
    else
      table.remove(lines, found)
    end
  elseif entry then
    local at = doc_end or #lines + 1
    while at > 1 and lines[at - 1] == "" do at = at - 1 end
    table.insert(lines, at, entry)
  else
    return true
  end
  if old and not vim.tbl_contains(lines, HEADER) then table.insert(lines, 1, HEADER) end
  if not permitted(path, old, lines) then return false end
  write(path, lines)
  require("projectrc.clang_indent").refresh(root)
  return true
end

---------------------------------------------------------------------------
-- .clangd

M.clangd_keys = { ["clangd.flags"] = true, ["clangd.std"] = true, ["clangd.compile_commands_dir"] = true }

local function clangd_path(root) return root .. "/.clangd" end

-- Our fragment, decoded: { flags = {...}, std = "c++20", compile_commands_dir = "build" }
local function clangd_read(root)
  local lines = read(clangd_path(root))
  local out = {}
  if not lines then return out, nil end
  local i0, i1
  for i, l in ipairs(lines) do
    if l == BEGIN then i0 = i elseif l == END then i1 = i end
  end
  if not (i0 and i1) then return out, lines end
  for i = i0 + 1, i1 - 1 do
    local add = lines[i]:match("^%s+Add:%s*(%[.*%])%s*$")
    local db = lines[i]:match("^%s+CompilationDatabase:%s*(.-)%s*$")
    -- we write flow sequences / quoted scalars, which are JSON
    if add then
      local ok, list = pcall(vim.json.decode, add)
      for _, flag in ipairs(ok and list or {}) do
        local std = flag:match("^%-std=(.+)$")
        if std then out.std = std else out.flags = out.flags or {}; table.insert(out.flags, flag) end
      end
    elseif db then
      local ok, s = pcall(vim.json.decode, db)
      out.compile_commands_dir = ok and s or db
    end
  end
  return out, lines, i0, i1
end

function M.clangd_get(root, key)
  return (clangd_read(root))[key:match("^clangd%.(.+)$")]
end

function M.clangd_set(root, key, value)
  local path = clangd_path(root)
  local vals, old, i0, i1 = clangd_read(root)
  vals[key:match("^clangd%.(.+)$")] = value
  local add = vim.list_extend(vals.std and { "-std=" .. vals.std } or {}, vals.flags or {})
  local frag = {}
  if #add > 0 or vals.compile_commands_dir then
    frag = { BEGIN, "---", "CompileFlags:" }
    if #add > 0 then frag[#frag + 1] = "  Add: " .. vim.json.encode(add) end
    if vals.compile_commands_dir then
      frag[#frag + 1] = "  CompilationDatabase: " .. vim.json.encode(vals.compile_commands_dir)
    end
    frag[#frag + 1] = END
  end
  local lines = old and vim.deepcopy(old) or {}
  if i0 then
    for _ = i0, i1 do table.remove(lines, i0) end
  else
    i0 = #lines + 1
    while i0 > 1 and lines[i0 - 1] == "" do i0 = i0 - 1 end
  end
  for j, l in ipairs(frag) do table.insert(lines, i0 + j - 1, l) end
  -- a file holding nothing but our (now empty) fragment can go entirely
  if not vim.iter(lines):any(function(l) return l:match("%S") and l ~= HEADER end) then
    if old then os.remove(path) end
    return true
  end
  if not vim.tbl_contains(lines, HEADER) then table.insert(lines, 1, HEADER) end
  if not permitted(path, old, lines) then return false end
  write(path, lines)
  return true
end

---------------------------------------------------------------------------

-- `store` names from the schema → getter/setter.
M.backends = {
  clang_format = { get = M.clang_get, set = M.clang_set, file = ".clang-format" },
  clangd = { get = M.clangd_get, set = M.clangd_set, file = ".clangd" },
}

return M
