-- Highlight groups. All are `default` links, so a colorscheme or the user's
-- config (setup({ highlights = … }) or plain :hi on ColorScheme) wins.

local config = require("projectrc.config")

local M = {}

M.links = {
  ProjectRCNormal = "NormalFloat",
  ProjectRCBorder = "FloatBorder",
  ProjectRCTitle = "Title",
  ProjectRCAccent = "Function",
  ProjectRCMuted = "Comment",
  ProjectRCWarn = "DiagnosticWarn",
  ProjectRCSel = "CursorLine",
}

function M.setup()
  for name, target in pairs(M.links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  -- transparent variant: the float's text colour, no background
  local normal = vim.api.nvim_get_hl(0, { name = "ProjectRCNormal", link = false })
  vim.api.nvim_set_hl(0, "ProjectRCNormalTransparent", { fg = normal.fg, bg = "NONE" })
  for name, spec in pairs(config.options.highlights or {}) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

-- Style a float: blend off (a global 'winblend' over a bg-less float blends
-- against black and draws a solid block) and, when transparent, no bg.
function M.style(win, extra)
  local normal = config.transparent() and "ProjectRCNormalTransparent" or "ProjectRCNormal"
  local s = ("Normal:%s,NormalFloat:%s,NormalNC:%s,FloatBorder:ProjectRCBorder,FloatTitle:ProjectRCTitle,FloatFooter:ProjectRCMuted")
    :format(normal, normal, normal)
  vim.wo[win].winhighlight = extra and (s .. "," .. extra) or s
  vim.wo[win].winblend = 0
end

return M
