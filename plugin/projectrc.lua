-- :ProjectRC                    open the settings float
-- :ProjectRC build | run | test run the project's command
-- :ProjectRC trust | json       trust / edit the settings file
-- Nothing else runs at startup; call require("projectrc").setup() to enable
-- the appliers (options, clang-format indent, LSP, DAP).

if vim.g.loaded_projectrc then return end
vim.g.loaded_projectrc = true

local subs = {
  build = function(p) p.build("cmd") end,
  run = function(p) p.build("run") end,
  test = function(p) p.build("test") end,
  trust = function(p) p.trust() end,
  json = function(p) p.json() end,
}

vim.api.nvim_create_user_command("ProjectRC", function(cmd)
  local a = cmd.fargs[1]
  local p = require("projectrc")
  if not a then return p.open() end
  if not subs[a] then return vim.notify("projectrc: unknown argument '" .. a .. "'", vim.log.levels.ERROR) end
  subs[a](p)
end, {
  nargs = "?",
  desc = "Project settings float, build/run/test, trust, json",
  complete = function(lead)
    local names = vim.tbl_keys(subs)
    table.sort(names)
    return vim.tbl_filter(function(n) return n:find(lead, 1, true) == 1 end, names)
  end,
})
