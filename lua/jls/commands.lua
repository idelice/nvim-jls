local M = {}

--- Refreshes all known file-explorer plugins independently.
--- Each plugin is tried in isolation via pcall; errors are silently ignored.
local function refresh_explorers()
  -- nvim-tree
  pcall(function()
    local api = package.loaded["nvim-tree.api"]
    if api and api.tree and type(api.tree.reload) == "function" then
      api.tree.reload()
    end
  end)

  -- neo-tree
  pcall(function()
    local manager = package.loaded["neo-tree.sources.manager"]
    if manager and type(manager.refresh) == "function" then
      manager.refresh("filesystem")
    end
  end)

  -- mini.files
  pcall(function()
    local mf = package.loaded["mini.files"]
    if mf and type(mf.refresh) == "function" then
      mf.refresh()
    end
  end)

  -- snacks.nvim explorer
  pcall(function()
    local snacks = package.loaded["snacks"]
    if snacks and snacks.explorer and type(snacks.explorer.refresh) == "function" then
      snacks.explorer.refresh()
    end
  end)
end

---@param args { oldPath: string, newPath: string }|nil
function M.handle_rename_file(args)
  if not args or not args.oldPath or not args.newPath then
    vim.notify("[jls] java.renameFile: missing oldPath or newPath", vim.log.levels.ERROR)
    return
  end
  vim.lsp.util.rename(args.oldPath, args.newPath)
  refresh_explorers()
  vim.notify(
    "[jls] Renamed: " .. vim.fn.fnamemodify(args.oldPath, ":t") .. " → " .. vim.fn.fnamemodify(args.newPath, ":t")
  )
end

return M
