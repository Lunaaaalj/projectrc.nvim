-- The settings file (default .nvim/settings.json): finding a buffer's
-- project, reading/writing the file (cached by mtime) and its trust state.
--
-- The file is VS Code–shaped: flat dotted keys, plus "[ft]" tables for
-- per-filetype overrides. Reading never prompts; only settings that run
-- something (schema `exec`) need the file trusted, and `M.ensure_trusted()`
-- asks through vim.secure (the same hash-based trust as 'exrc').
local config = require("projectrc.config")

local M = {}

-- The settings file's first path component (".nvim") outranks every marker.
local function markers()
  local first = config.options.file:match("^([^/]+)/") or config.options.file
  return vim.list_extend({ first }, vim.deepcopy(config.options.markers))
end

-- Project root for a buffer (or a path): the nearest dir with a marker, in
-- marker priority order, else the file's dir / the cwd.
function M.root(src)
  src = src or 0
  if type(src) == "number" then
    src = src == 0 and vim.api.nvim_get_current_buf() or src
    local name = vim.api.nvim_buf_get_name(src)
    src = (name ~= "" and vim.bo[src].buftype == "") and name or vim.fn.getcwd()
  end
  local root = vim.fs.root(src, markers())
  if root then return root end
  return vim.fn.isdirectory(src) == 1 and src or vim.fs.dirname(src)
end

function M.path(root) return root .. "/" .. config.options.file end

local cache = {} -- root -> { mtime, data }

local function mtime(path)
  local st = vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. "." .. st.mtime.nsec) or nil
end

-- Settings table for `root` ({} when there is no file or it doesn't parse).
function M.load(root)
  local path = M.path(root)
  local mt = mtime(path)
  local hit = cache[root]
  if hit and hit.mtime == mt then return hit.data end
  local data = {}
  if mt then
    local f = io.open(path, "r")
    local text = f and f:read("*a") or ""
    if f then f:close() end
    local ok, decoded = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
    if ok and type(decoded) == "table" then
      data = decoded
    elseif text:match("%S") then
      vim.notify("projectrc: can't parse " .. path, vim.log.levels.WARN)
    end
  end
  cache[root] = { mtime = mt, data = data }
  return data
end

---------------------------------------------------------------------------
-- Trust

local function trust_db()
  local db = {}
  local f = io.open(vim.fn.stdpath("state") .. "/trust", "r")
  if not f then return db end
  for line in f:lines() do
    local hash, file = line:match("^(%S+) (.+)$")
    if hash then db[file] = hash end
  end
  f:close()
  return db
end

-- Is the settings file trusted as it is now? Never prompts. A missing file
-- counts as trusted (it holds nothing to run).
function M.trusted(root)
  local path = vim.uv.fs_realpath(M.path(root))
  if not path then return true end
  local f = io.open(path, "r")
  if not f then return false end
  local text = f:read("*a")
  f:close()
  return trust_db()[path] == vim.fn.sha256(text)
end

-- Record the file's current contents as trusted. vim.secure.trust() only
-- allows *buffers* (it hashes their text), so write the entry the same way
-- `:trust` does: one "sha256 realpath" line per file in stdpath("state")/trust.
local function allow(path)
  path = vim.uv.fs_realpath(path)
  local f = path and io.open(path, "r")
  if not f then return end
  local text = f:read("*a")
  f:close()
  local db = trust_db()
  db[path] = vim.fn.sha256(text)
  local lines = {}
  for file, hash in pairs(db) do lines[#lines + 1] = hash .. " " .. file end
  table.sort(lines)
  local out = assert(io.open(vim.fn.stdpath("state") .. "/trust", "w"))
  out:write(table.concat(lines, "\n") .. "\n")
  out:close()
end

-- Trusted, or ask (vim.secure's ignore/view/deny/allow prompt). True if usable.
function M.ensure_trusted(root)
  if M.trusted(root) then return true end
  return vim.secure.read(M.path(root)) ~= nil
end

---------------------------------------------------------------------------
-- Writing

-- Stable, readable JSON: sorted keys ("[ft]" tables last), 2-space indent.
local function encode(v, indent)
  indent = indent or ""
  local inner = indent .. "  "
  if type(v) ~= "table" then return vim.json.encode(v) end
  if vim.islist(v) then
    if #v == 0 then return "[]" end
    local scalar = vim.iter(v):all(function(x) return type(x) ~= "table" end)
    local parts = vim.tbl_map(function(x) return encode(x, inner) end, v)
    if scalar then return "[" .. table.concat(parts, ", ") .. "]" end
    return "[\n" .. inner .. table.concat(parts, ",\n" .. inner) .. "\n" .. indent .. "]"
  end
  local keys = vim.tbl_keys(v)
  table.sort(keys, function(a, b)
    local fa, fb = a:sub(1, 1) == "[", b:sub(1, 1) == "["
    if fa ~= fb then return fb end
    return a < b
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = inner .. vim.json.encode(k) .. ": " .. encode(v[k], inner)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end
M.encode = encode

-- Replace the whole settings table for `root`. Our own writes stay trusted,
-- but only if the file was trusted before (or new): editing an indent in an
-- untrusted repo must not silently approve its build commands.
function M.save(root, data)
  local path = M.path(root)
  local keep_trust = M.trusted(root)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(encode(data) .. "\n")
  f:close()
  if keep_trust then allow(path) end
  cache[root] = nil
  M.changed(root)
end

function M.changed(root)
  cache[root] = nil
  vim.api.nvim_exec_autocmds("User", { pattern = "ProjectRCChanged", data = { root = root } })
end

return M
