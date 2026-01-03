local M = {}

function M.joinpath(...)
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end
  local parts = { ... }
  return table.concat(parts, "/")
end

function M.detect_os()
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    return "windows"
  elseif vim.fn.has("mac") == 1 then
    return "mac"
  else
    return "linux"
  end
end

function M.notify(msg, level)
  local ok = pcall(vim.notify, msg, level or vim.log.levels.INFO, { title = "jls" })
  if not ok then
    pcall(vim.notify, msg, level or vim.log.levels.INFO)
  end
end

function M.pos_in_range(pos, range)
  if not range or not range.start or not range["end"] then
    return false
  end
  if pos.line < range.start.line or pos.line > range["end"].line then
    return false
  end
  if pos.line == range.start.line and pos.character < range.start.character then
    return false
  end
  if pos.line == range["end"].line and pos.character > range["end"].character then
    return false
  end
  return true
end

function M.names_to_patterns(names)
  local patterns = {}
  for _, name in ipairs(names or {}) do
    table.insert(patterns, "^" .. vim.pesc(name) .. "$")
  end
  return patterns
end

function M.supports_code_action_resolve(client)
  if not client or not client.server_capabilities then
    return false
  end
  local provider = client.server_capabilities.codeActionProvider
  if type(provider) == "table" then
    return provider.resolveProvider == true
  end
  return false
end

return M
