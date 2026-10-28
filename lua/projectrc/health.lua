-- :checkhealth projectrc
local M = {}

function M.check()
  local h = vim.health
  h.start("projectrc.nvim")
  if vim.fn.has("nvim-0.11") == 1 then h.ok("Neovim 0.11+") else h.error("Neovim 0.11+ is required") end
  local config = require("projectrc.config").options
  for _, tool in ipairs({
    { "clang-format", "C-family indent and the clang-format settings" },
    { "clangd", "the clangd settings" },
  }) do
    if vim.fn.executable(tool[1]) == 1 then
      local v = vim.fn.system({ tool[1], "--version" }):match("version ([%d.]+)") or "?"
      h.ok(("%s %s"):format(tool[1], v))
    else
      h.warn(tool[1] .. " not on PATH: " .. tool[2] .. " won't work")
    end
  end
  if config.clang_indent and vim.fn.executable("clang-format") == 1 then
    local r = vim.system({ "clang-format", "--dump-config", "--assume-filename=x.cpp",
      "--style=" .. config.fallback_style }, { text = true }):wait()
    if r.code == 0 then h.ok("fallback_style parses: " .. config.fallback_style)
    else h.error("fallback_style is rejected by clang-format: " .. vim.trim(r.stderr or "")) end
  end
  local store = require("projectrc.store")
  local root = store.root(0)
  local path = store.path(root)
  if vim.uv.fs_stat(path) then
    if store.trusted(root) then h.ok("trusted: " .. path)
    else h.warn("not trusted (build/debug/driver settings are off): " .. path, { ":ProjectRC trust" }) end
  else
    h.info("no settings file for this project yet (" .. path .. ")")
  end
end

return M
