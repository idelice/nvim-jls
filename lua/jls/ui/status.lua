local M = {}

local status_state = { message = "", done = true }

local function set_status(msg, done)
  status_state.message = msg or ""
  status_state.done = done ~= false
end

function M.statusline()
  if status_state.message == "" then
    return ""
  end
  return "[JLS] " .. status_state.message
end

function M.setup(cfg, notify)
  if not (cfg.status and cfg.status.enable) then
    return
  end
  local group = vim.api.nvim_create_augroup("JlsStatus", { clear = true })
  vim.api.nvim_create_autocmd("LspProgress", {
    group = group,
    callback = function(ev)
      local client_id = ev.data and ev.data.client_id or nil
      local client = client_id and vim.lsp.get_client_by_id(client_id) or nil
      if not client or client.name ~= "jls" then
        return
      end
      local value = ev.data and ev.data.params and ev.data.params.value or nil
      if type(value) == "table" then
        local title = value.title or ""
        local message = value.message or ""
        local percentage = value.percentage and (" " .. value.percentage .. "%%") or ""
        local text = (title .. " " .. message .. percentage):gsub("%s+", " "):gsub("^%s+", "")
        local done = value.kind == "end"
        set_status(text, done)
        if cfg.status.notify and text ~= "" then
          notify("JLS: " .. text, vim.log.levels.INFO)
        end
      end
    end,
  })
end

return M
