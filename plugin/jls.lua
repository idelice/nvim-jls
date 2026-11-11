local jls = require("jls")

local function jls_running()
  return #vim.lsp.get_clients({ name = "jls" }) > 0
end

local DIAG_TITLE = "JlsCompile"

-- Unloaded files are previewed in a scratch buffer, so copy the diagnostics of the real buffer onto it.
local preview_ns = vim.api.nvim_create_namespace("jls_diag_preview")
-- The snacks picker input is in insert mode.
vim.diagnostic.config({ update_in_insert = true }, preview_ns)
local function preview_with_diagnostics(ctx)
  local ret = require("snacks").picker.preview.file(ctx)
  local src = ctx.item.buf
  if not (src and vim.api.nvim_buf_is_loaded(src)) and ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) then
    pcall(function()
      vim.diagnostic.reset(preview_ns, ctx.buf)
      local bufnr = src or (ctx.item.file and vim.fn.bufnr(vim.fn.fnamemodify(ctx.item.file, ":p"))) or -1
      local client = vim.lsp.get_clients({ name = "jls" })[1]
      if client and bufnr > 0 then
        local ns = vim.lsp.diagnostic.get_namespace(client.id, false)
        local diags = vim.diagnostic.get(bufnr, { namespace = ns })
        vim.diagnostic.show(preview_ns, ctx.buf, diags)
      end
    end)
  end
  return ret
end

local function build_diag_qflist(client)
  local ns = vim.lsp.diagnostic.get_namespace(client.id, false)
  local cur = vim.api.nvim_get_current_buf()
  local diags = vim.tbl_filter(function(d)
    return d.severity <= vim.diagnostic.severity.WARN or vim.api.nvim_buf_is_loaded(d.bufnr)
  end, vim.diagnostic.get(nil, { namespace = ns }))
  if #diags == 0 then
    return 0
  end
  local items = vim.diagnostic.toqflist(diags)
  local function name(item)
    return item.filename or vim.api.nvim_buf_get_name(item.bufnr)
  end
  local rank = { E = 1, W = 2, I = 3, N = 4 }
  table.sort(items, function(a, b)
    local ar, br = rank[a.type] or 5, rank[b.type] or 5
    if ar ~= br then
      return ar < br
    end
    if (a.bufnr == cur) ~= (b.bufnr == cur) then
      return a.bufnr == cur
    end
    local an, bn = name(a), name(b)
    if an ~= bn then
      return an < bn
    end
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.col < b.col
  end)
  vim.fn.setqflist({}, " ", { title = DIAG_TITLE, items = items })
  return #items
end

local function open_diag_list()
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker and snacks.picker.qflist then
    snacks.picker.qflist({ title = DIAG_TITLE, preview = preview_with_diagnostics })
  else
    vim.cmd("botright copen")
  end
end

local function show_compile_diagnostics(client)
  vim.schedule(function()
    if build_diag_qflist(client) > 0 then
      open_diag_list()
    end
  end)
end

local function toggle_diagnostics()
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker and snacks.picker.qflist then
    local closed = false
    for _, p in ipairs(snacks.picker.get({ source = "qflist" })) do
      if p.opts.title == DIAG_TITLE then
        p:close()
        closed = true
      end
    end
    if closed then
      return
    end
  elseif vim.fn.getqflist({ winid = 0 }).winid ~= 0 and vim.fn.getqflist({ title = 0 }).title == DIAG_TITLE then
    vim.cmd("cclose")
    return
  end
  local client = vim.lsp.get_clients({ name = "jls" })[1]
  if not client then
    vim.notify("[jls] not running", vim.log.levels.WARN)
    return
  end
  if build_diag_qflist(client) == 0 then
    vim.notify("[jls] no diagnostics", vim.log.levels.INFO)
    return
  end
  open_diag_list()
end

local function compile_workspace()
  local client = vim.lsp.get_clients({ name = "jls" })[1]
  if not client then
    vim.notify("[jls] not running", vim.log.levels.WARN)
    return
  end
  vim.notify("[jls] Compiling workspace...")
  client:request("workspace/executeCommand", { command = "java.compileWorkspace", arguments = {} }, function(err, result)
    if err then
      vim.notify("[jls] compileWorkspace failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
    elseif not result then
      vim.notify("[jls] compileWorkspace returned no result", vim.log.levels.WARN)
    else
      vim.notify(("[jls] Compiled %d files (%d ms)"):format(result.files, result.ms), vim.log.levels.INFO)
      show_compile_diagnostics(client)
    end
  end, 0)
end

local commands = {
  { "JlsCompile", compile_workspace, { desc = "Compile the whole workspace" } },
  { "JlsShowDiagnostics", toggle_diagnostics, { desc = "Toggle the JLS diagnostics list" } },
  { "JlsLog", function() jls.log() end, { desc = "Open Neovim's LSP log in a read-only buffer" } },
  { "JlsClearCache", function() jls.clear_cache() end, { desc = "Clear the JLS cache of the current workspace and restart JLS" } },
}

vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("JlsCommands", { clear = true }),
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not (client and client.name == "jls") then
      return
    end
    -- Never deleted, so it stays available after a server crash.
    if not vim.api.nvim_get_commands({}).JlsRestart then
      vim.api.nvim_create_user_command("JlsRestart", function() jls.restart() end, { desc = "Restart (or start) the JLS language server" })
    end
    for _, c in ipairs(commands) do
      if not vim.api.nvim_get_commands({})[c[1]] then
        vim.api.nvim_create_user_command(c[1], c[2], c[3])
      end
    end
  end,
})

vim.api.nvim_create_autocmd("LspDetach", {
  group = "JlsCommands",
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not (client and client.name == "jls") then
      return
    end
    vim.schedule(function()
      if jls_running() then
        return
      end
      for _, c in ipairs(commands) do
        if vim.api.nvim_get_commands({})[c[1]] then
          vim.api.nvim_del_user_command(c[1])
        end
      end
    end)
  end,
})

-- Ensure JLS server processes are killed when Neovim exits.
-- Neovim's built-in shutdown may not wait for the LSP handshake to complete,
-- leaving orphaned java processes consuming GBs of memory.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("JlsCleanup", { clear = true }),
  callback = function()
    for _, client in ipairs(vim.lsp.get_clients({ name = "jls" })) do
      -- Force stop sends SIGTERM to the spawned process
      pcall(function()
        client:stop(true)
      end)
    end
    -- Give the process a moment to die
    vim.wait(100, function()
      return false
    end)
  end,
})
