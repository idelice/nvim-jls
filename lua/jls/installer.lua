local util = require("jls.util")

local GITHUB_REPO = "idelice/jls"
local INSTALL_DIR_NAME = "jls"

local M = {}

---@return string
function M.managed_install_dir()
  return util.joinpath(vim.fn.stdpath("data"), INSTALL_DIR_NAME)
end

---@return string|nil
function M.installed_version()
  local version_file = util.joinpath(M.managed_install_dir(), "VERSION")
  if vim.fn.filereadable(version_file) == 0 then
    return nil
  end
  local lines = vim.fn.readfile(version_file)
  if lines and #lines > 0 then
    return vim.trim(lines[1])
  end
  return nil
end

---@return string artifact filename, boolean is_tar
local function artifact_name()
  local os_id = util.detect_os()
  local uname = vim.uv.os_uname()
  local machine = (uname and uname.machine) or ""
  local arch = (machine:find("arm64") or machine:find("aarch64")) and "aarch64" or "x64"
  if os_id == "windows" then
    return "jls-windows-" .. arch .. ".zip", false
  elseif os_id == "mac" then
    return "jls-macos-" .. arch .. ".tar.gz", true
  else
    return "jls-linux-" .. arch .. ".tar.gz", true
  end
end

---Async: fetches the latest release tag from GitHub.
---@param callback fun(err: string|nil, tag: string|nil)
function M.latest_tag(callback)
  local url = "https://api.github.com/repos/" .. GITHUB_REPO .. "/releases/latest"
  vim.system(
    { "curl", "-fsSL", "--max-time", "10", "-H", "Accept: application/vnd.github+json", url },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback("network error: " .. (result.stderr or "unknown"), nil)
          return
        end
        local ok, decoded = pcall(vim.json.decode, result.stdout or "")
        if not ok or type(decoded) ~= "table" or not decoded.tag_name then
          callback("failed to parse GitHub API response", nil)
          return
        end
        callback(nil, decoded.tag_name)
      end)
    end
  )
end

---Async: downloads and installs a specific release tag.
---@param tag string e.g. "v1.0.0"
---@param callback fun(err: string|nil)
function M.install(tag, callback)
  local artifact, is_tar = artifact_name()
  local base_url = "https://github.com/" .. GITHUB_REPO .. "/releases/download/" .. tag .. "/"
  local artifact_url = base_url .. artifact
  local checksum_url = artifact_url .. ".sha256"

  local tmp_dir = vim.fn.tempname()
  vim.fn.mkdir(tmp_dir, "p")
  local artifact_path = util.joinpath(tmp_dir, artifact)
  local checksum_path = artifact_path .. ".sha256"

  local function cleanup()
    vim.fn.delete(tmp_dir, "rf")
  end

  util.notify("JLS: downloading " .. artifact .. " ...", vim.log.levels.INFO)

  vim.system(
    { "curl", "-fsSL", "--max-time", "300", "-o", artifact_path, artifact_url },
    {},
    function(dl)
      vim.schedule(function()
        if dl.code ~= 0 then
          cleanup()
          callback("download failed: " .. (dl.stderr or "unknown"))
          return
        end

        vim.system(
          { "curl", "-fsSL", "--max-time", "15", "-o", checksum_path, checksum_url },
          {},
          function(cs)
            vim.schedule(function()
              local skip_verify = cs.code ~= 0
              if skip_verify then
                util.notify("JLS: checksum unavailable, skipping verification", vim.log.levels.WARN)
              end

              local function do_extract()
                M._extract(artifact_path, is_tar, tmp_dir, tag, cleanup, callback)
              end

              if skip_verify then
                do_extract()
                return
              end

              local expected_lines = vim.fn.readfile(checksum_path)
              local expected = expected_lines
                and #expected_lines > 0
                and vim.trim(expected_lines[1]):match("^(%x+)")
              if not expected then
                do_extract()
                return
              end

              vim.system(
                { "shasum", "-a", "256", artifact_path },
                { text = true },
                function(hash)
                  vim.schedule(function()
                    if hash.code == 0 then
                      local actual = hash.stdout and hash.stdout:match("^(%x+)")
                      if actual and actual ~= expected then
                        cleanup()
                        callback("checksum mismatch — download may be corrupt (expected " .. expected .. ")")
                        return
                      end
                    end
                    do_extract()
                  end)
                end
              )
            end)
          end
        )
      end)
    end
  )
end

---@private
function M._extract(artifact_path, is_tar, tmp_dir, tag, cleanup, callback)
  util.notify("JLS: extracting ...", vim.log.levels.INFO)

  local staging = util.joinpath(tmp_dir, "staging")
  vim.fn.mkdir(staging, "p")

  local extract_cmd = is_tar
    and { "tar", "-xzf", artifact_path, "-C", staging }
    or { "unzip", "-q", artifact_path, "-d", staging }

  vim.system(extract_cmd, {}, function(ex)
    vim.schedule(function()
      if ex.code ~= 0 then
        cleanup()
        callback("extraction failed: " .. (ex.stderr or "unknown"))
        return
      end

      -- Ensure VERSION file exists (CI always writes it, but guard for manual installs)
      local version_file = util.joinpath(staging, "VERSION")
      if vim.fn.filereadable(version_file) == 0 then
        vim.fn.writefile({ tag }, version_file)
      end

      -- Fix permissions before moving into place
      if util.detect_os() ~= "windows" then
        vim.fn.system("chmod +x " .. vim.fn.shellescape(staging) .. "/dist/*.sh 2>/dev/null; true")
        local os_id = util.detect_os()
        local bin_dir = util.joinpath(staging, "dist", os_id, "bin")
        vim.fn.system("chmod -R +x " .. vim.fn.shellescape(bin_dir) .. " 2>/dev/null; true")
      end

      local install_dir = M.managed_install_dir()
      local parent = vim.fn.fnamemodify(install_dir, ":h")
      vim.fn.mkdir(parent, "p")

      -- Replace existing install atomically via rename
      local old_dir = install_dir .. ".old"
      vim.fn.delete(old_dir, "rf")
      if vim.fn.isdirectory(install_dir) == 1 then
        vim.fn.rename(install_dir, old_dir)
      end

      if vim.fn.rename(staging, install_dir) == 0 then
        vim.fn.delete(old_dir, "rf")
        cleanup()
        util.notify("JLS: installed " .. tag, vim.log.levels.INFO)
        callback(nil)
      else
        -- Cross-device fallback: cp -r
        vim.system({ "cp", "-r", staging, install_dir }, {}, function(cp)
          vim.schedule(function()
            vim.fn.delete(old_dir, "rf")
            cleanup()
            if cp.code ~= 0 then
              callback("install failed: could not move files into place")
            else
              util.notify("JLS: installed " .. tag, vim.log.levels.INFO)
              callback(nil)
            end
          end)
        end)
      end
    end)
  end)
end

return M
