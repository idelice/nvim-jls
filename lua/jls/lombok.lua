local util = require("jls.util")

local M = {}

local function pick_latest_path(paths)
  if not paths or #paths == 0 then
    return nil
  end
  table.sort(paths)
  return paths[#paths]
end

local function find_lombok_in_paths(paths)
  if not paths then
    return nil
  end
  for _, p in ipairs(paths) do
    if type(p) == "string" and p ~= "" then
      if p:match("%.jar$") and vim.fn.filereadable(p) == 1 then
        return p
      end
      local matches = vim.fn.glob(p, 1, 1)
      if matches and #matches > 0 then
        local jar = pick_latest_path(matches)
        if jar and vim.fn.filereadable(jar) == 1 then
          return jar
        end
      end
      local globbed = vim.fn.globpath(p, "**/lombok-*.jar", 1, 1)
      if globbed and #globbed > 0 then
        local jar = pick_latest_path(globbed)
        if jar and vim.fn.filereadable(jar) == 1 then
          return jar
        end
      end
    end
  end
  return nil
end

function M.detect(cfg)
  cfg.lombok = cfg.lombok or {}
  if cfg.lombok.path and cfg.lombok.path ~= "" then
    return cfg
  end
  local env_path = os.getenv("LOMBOK_PATH")
  if env_path and env_path ~= "" and vim.fn.filereadable(env_path) == 1 then
    cfg.lombok.path = env_path
    return cfg
  end

  local search = cfg.lombok.search_paths or {}
  local found = find_lombok_in_paths(search)
  if found then
    cfg.lombok.path = found
    return cfg
  end

  local home = os.getenv("HOME")
  if home and home ~= "" then
    local m2 = util.joinpath(
      home,
      ".m2",
      "repository",
      "org",
      "projectlombok",
      "lombok",
      "*",
      "lombok-*.jar"
    )
    local m2_hits = vim.fn.glob(m2, 1, 1)
    local m2_found = pick_latest_path(m2_hits)
    if m2_found and vim.fn.filereadable(m2_found) == 1 then
      cfg.lombok.path = m2_found
      return cfg
    end
  end
  return cfg
end

return M
