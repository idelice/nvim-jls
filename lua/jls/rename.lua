local M = {}

---@return boolean
function M.can_show()
  return vim.fn.has("nvim-0.10") == 1
    and type(vim.api.nvim_open_win) == "function"
    and type(vim.lsp.util.apply_workspace_edit) == "function"
end

---@param result table
---@return table<string, table[]>
local function edits_by_uri(result)
  local out = {}
  if result.changes then
    for uri, edits in pairs(result.changes) do
      out[uri] = edits
    end
  elseif result.documentChanges then
    for _, dc in ipairs(result.documentChanges) do
      if dc.textDocument and dc.edits then
        out[dc.textDocument.uri] = dc.edits
      end
    end
  end
  for _, edits in pairs(out) do
    table.sort(edits, function(a, b)
      if a.range.start.line ~= b.range.start.line then
        return a.range.start.line < b.range.start.line
      end
      return a.range.start.character < b.range.start.character
    end)
  end
  return out
end

---@param fname string
---@param cache table<string, string[]>
---@return string[]
local function file_lines(fname, cache)
  local lines = cache[fname]
  if lines == nil then
    local bufnr = vim.fn.bufnr(fname)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    else
      local ok, disk = pcall(vim.fn.readfile, fname)
      lines = ok and disk or {}
    end
    cache[fname] = lines
  end
  return lines
end

---@param result table WorkspaceEdit
---@param ctx table LSP handler ctx
function M.show(result, ctx)
  local lsp = require("jls.lsp")
  local util = require("jls.util")
  local by_uri = edits_by_uri(result)

  local files = vim.tbl_keys(by_uri)
  table.sort(files)
  local total = 0
  for _, edits in pairs(by_uri) do
    total = total + #edits
  end
  if total == 0 then
    util.notify("JLS: rename produced no changes", vim.log.levels.INFO)
    return
  end

  local cache = {}
  local cwd = vim.fn.getcwd()
  local lines = {} ---@type string[]
  local hl = {} ---@type { row: integer, col: integer, len: integer, group: string }[]
  local jumps = {} ---@type table<integer, { fname: string, line0: integer, col0: integer }>
  local arrow = " → "

  for fi, uri in ipairs(files) do
    local fname = vim.uri_to_fname(uri)
    local rel = fname:sub(1, #cwd + 1) == cwd .. "/" and fname:sub(#cwd + 2) or fname
    local src = file_lines(fname, cache)

    if fi > 1 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = rel
    hl[#hl + 1] = { row = #lines - 1, col = 0, len = #rel, group = "Directory" }

    for _, e in ipairs(by_uri[uri]) do
      local lno = e.range.start.line
      local orig = src[lno + 1] or ""
      local sc, ec = e.range.start.character, e.range["end"].character
      local old_tok = orig:sub(sc + 1, ec)
      local new_tok = e.newText or ""
      -- Show the original line (trimmed) with the old token in place, then "→ new".
      local trimmed = orig:gsub("^%s+", "")
      local lead = #orig - #trimmed
      local prefix = ("  %d  "):format(lno + 1)
      local line = prefix .. trimmed .. arrow .. new_tok
      lines[#lines + 1] = line
      local row = #lines - 1 -- 0-based row for extmarks
      jumps[#lines] = { fname = fname, line0 = lno, col0 = sc } -- 1-based for cursor lookup

      -- Gutter (dim), old token in context (red), arrow (dim), new token (green).
      hl[#hl + 1] = { row = row, col = 0, len = #prefix, group = "LineNr" }
      local old_col = #prefix + (sc - lead)
      if old_col >= #prefix and #old_tok > 0 then
        hl[#hl + 1] = { row = row, col = old_col, len = #old_tok, group = "DiffDelete" }
      end
      local arrow_col = #prefix + #trimmed
      hl[#hl + 1] = { row = row, col = arrow_col, len = #arrow, group = "Comment" }
      hl[#hl + 1] = { row = row, col = arrow_col + #arrow, len = #new_tok, group = "DiffAdd" }
    end
  end

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.max(math.min(width + 2, math.floor(vim.o.columns * 0.9)), 40)
  local height = math.min(#lines, math.floor(vim.o.lines * 0.8))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local ns = vim.api.nvim_create_namespace("jls_rename_preview")
  for _, h in ipairs(hl) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.row, h.col, {
      end_col = h.col + h.len,
      hl_group = h.group,
    })
  end

  local target_win = vim.api.nvim_get_current_win()

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = (" rename · %d change%s · %d file%s "):format(
      total,
      total == 1 and "" or "s",
      #files,
      #files == 1 and "" or "s"
    ),
    title_pos = "center",
    footer = " ⏎ apply   ⇥ jump   q cancel ",
    footer_pos = "center",
  })
  vim.wo[win].cursorline = true

  pcall(vim.api.nvim_win_set_cursor, win, { 2, 0 })

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function apply()
    close()
    lsp.apply_rename_result(result, ctx)
    util.notify(
      ("renamed · %d change%s · %d file%s"):format(total, total == 1 and "" or "s", #files, #files == 1 and "" or "s")
    )
  end

  local function jump()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local j = jumps[row]
    if not j then
      return
    end
    close()
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(target_win) then
        vim.api.nvim_set_current_win(target_win)
      end
      vim.cmd("edit " .. vim.fn.fnameescape(j.fname))
      pcall(vim.api.nvim_win_set_cursor, 0, { j.line0 + 1, j.col0 })
    end)
  end

  local kmopts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", apply, kmopts)
  vim.keymap.set("n", "<Tab>", jump, kmopts)
  vim.keymap.set("n", "q", close, kmopts)
  vim.keymap.set("n", "<Esc>", close, kmopts)
end

return M
