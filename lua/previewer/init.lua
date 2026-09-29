-- Build a file into something to look at, show it, and keep it current.
--
-- A preview is per buffer: a spec (from the filetype, vim.b.preview and
-- lines in the file itself), a build that runs on save or while typing, and
-- one viewer. The viewer is started once and told to reload after each
-- build; only when it has gone away is a new one started.

local api, uv = vim.api, vim.uv
local M = {}

M.config = {
  debounce = 300,     -- ms of quiet before a build, for trigger = "change"
  timeout = 60000,    -- ms before a build is killed
  browser = nil,      -- command for browser previews, %u the URL; nil: vim.ui.open
  port = 0,           -- for browser previews; 0 picks a free one
  filetypes = require("previewer.defaults").filetypes,
  viewers = require("previewer.defaults").viewers, -- by output extension, for specs without a view
}

local sessions = {} -- by buffer
local group = api.nvim_create_augroup("previewer", { clear = true })

local function notify(msg, level)
  vim.notify("preview: " .. msg, level or vim.log.levels.INFO)
end

local function exists(path)
  return path and uv.fs_stat(path) ~= nil
end

-- ----------------------------------------------------------------------------
-- Specs
-- ----------------------------------------------------------------------------

local directive_keys = { build = true, output = true, view = true, reload = true, trigger = true }

-- `preview-build: ...` and friends, in the first or last ten lines, in
-- whatever comment the language has. Closing comment marks are dropped.
local function directives(buf)
  local n = api.nvim_buf_line_count(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, math.min(n, 10), false)
  if n > 10 then
    vim.list_extend(lines, api.nvim_buf_get_lines(buf, math.max(10, n - 10), n, false))
  end
  local found = {}
  for _, line in ipairs(lines) do
    local key, value = line:match("preview%-(%a+):%s*(.-)%s*$")
    if key and directive_keys[key] then
      value = value:gsub("%s*%-%->$", ""):gsub("%s*%*/$", "")
      found[key] = value
    end
  end
  return found
end

local function resolve(buf)
  local ft = vim.bo[buf].filetype
  local spec = vim.deepcopy(M.config.filetypes[ft] or {})
  if type(vim.b[buf].preview) == "table" then
    spec = vim.tbl_extend("force", spec, vim.b[buf].preview)
  end
  spec = vim.tbl_extend("force", spec, directives(buf))
  if not (spec.build or spec.view or spec.output) then return nil end
  spec.trigger = spec.trigger or "save"
  return spec
end

-- ----------------------------------------------------------------------------
-- Commands: %f file, %o output, %d directory, %r file without extension,
-- %t file name, %u preview URL, %% a percent sign
-- ----------------------------------------------------------------------------

local function quote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

local function expand(template, ctx, shell)
  return (template:gsub("%%(.)", function(c)
    if c == "%" then return "%" end
    local v = ({ f = ctx.file, o = ctx.output, d = ctx.dir, r = ctx.root, t = ctx.tail, u = ctx.url })[c]
    if not v then return nil end
    return shell and quote(v) or v
  end))
end

-- A plain command is split on spaces and run directly, so a signal sent to
-- the viewer reaches the viewer and not a shell. Anything with shell syntax
-- in it goes through sh.
local function command(x, ctx)
  if type(x) == "function" then x = x(ctx) end
  if type(x) == "table" then
    return vim.tbl_map(function(a) return expand(a, ctx) end, x)
  end
  if x:find("[|&;<>()$`\\\"'*?%[%]{}#~]") then
    return { "sh", "-c", expand(x, ctx, true) }
  end
  return vim.tbl_map(function(a) return expand(a, ctx) end, vim.split(x, "%s+", { trimempty = true }))
end

-- ----------------------------------------------------------------------------
-- Sessions
-- ----------------------------------------------------------------------------

local function context(s, output)
  return {
    buf = s.buf, file = s.file, dir = s.dir, tail = vim.fs.basename(s.file),
    root = s.file:gsub("%.[^./]*$", ""), output = output or s.output, url = s.url,
  }
end

local function kill(proc, signal)
  if proc and not proc:is_closing() then pcall(proc.kill, proc, signal or "sigterm") end
end

local show

local function spawn(s, cmd)
  local proc
  local ok, err = pcall(function()
    proc = vim.system(cmd, { cwd = s.dir, stdout = false, stderr = false }, function()
      vim.schedule(function()
        if s.viewer ~= proc then return end
        s.viewer = nil
        -- Died of the reload signal (it has no handler for it): open it again
        -- now rather than on the next build.
        if sessions[s.buf] == s and s.signalled and uv.now() - s.signalled < 1000 then
          s.signalled = nil
          show(s)
        end
      end)
    end)
  end)
  if not ok then
    notify("cannot start " .. cmd[1] .. ": " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  return proc
end

local function open_browser(s)
  s.opened = uv.now()
  if M.config.browser then
    local cmd = command(M.config.browser, context(s))
    pcall(vim.system, cmd, { detach = true, stdout = false, stderr = false })
  else
    vim.ui.open(s.url)
  end
end

local function reload(s)
  local r = s.spec.reload
  if not r then return end
  if type(r) == "function" then
    r(context(s), s.viewer)
  elseif r:match("^SIG%u+%d*$") then
    s.signalled = uv.now()
    kill(s.viewer, r:lower())
  else
    pcall(vim.system, command(r, context(s)), { cwd = s.dir, stdout = false, stderr = false })
  end
end

function show(s)
  if s.spec.view == "browser" then
    local server = require("previewer.server")
    if server.clients(s.sid) > 0 then
      server.reload(s.sid)
    elseif not s.opened or uv.now() - s.opened > 3000 then
      open_browser(s) -- a page opened a moment ago may still be loading
    end
    return
  end
  if not exists(s.output) then
    notify("nothing to show, " .. s.output .. " is not there", vim.log.levels.WARN)
    return
  end
  if s.viewer and s.spec.restart then
    kill(s.viewer)
    s.viewer = nil
  end
  if s.viewer then
    reload(s)
  else
    s.viewer = spawn(s, command(s.spec.view, context(s)))
  end
end

local function tail_lines(text, n)
  local lines = vim.split(vim.trim(text or ""), "\n")
  return table.concat(lines, "\n", math.max(1, #lines - n + 1))
end

local function build(s)
  if sessions[s.buf] ~= s then return end
  if s.job then
    s.pending = true -- one more build once this one is done
    return
  end
  if not s.spec.build then return show(s) end

  -- Built next to the output and moved over it only when the build worked:
  -- the viewer never sees half a file, and a failed build leaves the last
  -- good one up. Commands that write elsewhere are left to it.
  local dir, name = vim.fs.dirname(s.output), vim.fs.basename(s.output)
  local tmp = vim.fs.joinpath(dir, "." .. name:gsub("(%.[^.]*)$", ".tmp%1"))
  vim.fn.mkdir(dir, "p")

  local ctx = context(s, tmp)
  local stdin
  if s.spec.stdin then
    ctx.text = table.concat(api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n") .. "\n"
    stdin = type(s.spec.stdin) == "function" and s.spec.stdin(ctx) or ctx.text
  end
  local cmd = command(s.spec.build, ctx)

  local ok, err = pcall(function()
    s.job = vim.system(cmd, { cwd = s.dir, stdin = stdin, text = true, timeout = M.config.timeout },
      vim.schedule_wrap(function(r)
        s.job = nil
        s.log = { "$ " .. table.concat(cmd, " "), ("exit %d%s"):format(r.code,
          r.signal ~= 0 and (", signal " .. r.signal) or "") }
        vim.list_extend(s.log, vim.split(vim.trim((r.stdout or "") .. "\n" .. (r.stderr or "")), "\n"))
        if sessions[s.buf] ~= s then
          os.remove(tmp)
          return
        end
        if r.code ~= 0 then
          os.remove(tmp)
          s.failed = true
          local out = tail_lines(r.stderr ~= "" and r.stderr or r.stdout, 8)
          notify(("build failed (exit %d), :Preview log\n%s"):format(r.code, out), vim.log.levels.ERROR)
        else
          if exists(tmp) then os.rename(tmp, s.output) end
          if s.failed then notify("build ok") end
          s.failed = false
          show(s)
        end
        if s.pending then
          s.pending = false
          build(s)
        end
      end))
  end)
  if not ok then
    notify("cannot run " .. cmd[1] .. ": " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.stop(buf)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  local s = sessions[buf]
  if not s then return end
  sessions[buf] = nil
  api.nvim_clear_autocmds({ group = s.group })
  api.nvim_del_augroup_by_id(s.group)
  if s.timer then s.timer:close() end
  kill(s.job)
  if not s.spec.keep then kill(s.viewer) end
  if s.sid then require("previewer.server").remove(s.sid) end
  if s.cached then os.remove(s.output) end
end

function M.start(buf, spec)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  M.stop(buf)
  spec = spec or resolve(buf)
  local file = api.nvim_buf_get_name(buf)
  if not spec then
    notify("nothing set up for filetype '" .. vim.bo[buf].filetype .. "', see :help previewer-spec",
      vim.log.levels.WARN)
    return
  end
  if file == "" then
    notify("the buffer needs a file name", vim.log.levels.WARN)
    return
  end

  local s = { buf = buf, spec = spec, file = file, dir = vim.fs.dirname(file) }
  local ctx = context(s)
  if spec.output then
    s.output = vim.fs.normalize(vim.fs.joinpath(s.dir, expand(spec.output, ctx)))
    if spec.output:sub(1, 1) == "/" or spec.output:sub(1, 1) == "~" then
      s.output = vim.fs.normalize(expand(spec.output, ctx))
    end
  elseif spec.build then
    local cache = vim.fs.joinpath(vim.fn.stdpath("cache"), "previewer")
    local name = ctx.tail:gsub("[^%w._-]", "_"):gsub("%.[^.]*$", "")
    s.output = vim.fs.joinpath(cache, ("%s-%d.%s"):format(name, buf, spec.ext or "out"))
    s.cached = true
  else
    s.output = file
  end

  if not spec.view then
    local ext = (s.output:match("%.(%w+)$") or ""):lower()
    local viewer = M.config.viewers[ext]
    if not viewer then
      notify("no viewer for ." .. ext .. " files, set one with preview-view:", vim.log.levels.WARN)
      return
    end
    spec = vim.tbl_extend("keep", spec, viewer)
    s.spec = spec
  end

  if spec.view == "browser" then
    -- Served from the file's directory, so relative links work; an output
    -- from somewhere else is put in there as <name>.html.
    local server = require("previewer.server")
    local rel = vim.fs.relpath(s.dir, s.output)
    local page, path = nil, rel and ("/" .. rel)
    if not rel then page, path = s.output, "/" .. ctx.tail .. ".html" end
    local sid, err = server.add(s.dir, page, path, M.config.port)
    if not sid then
      notify("cannot start the server: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    s.sid = sid
    s.url = server.url(sid, (path:gsub("[^%w/._~-]", function(c) return ("%%%02X"):format(c:byte()) end)))
  end

  sessions[buf] = s
  s.group = api.nvim_create_augroup("previewer." .. buf, { clear = true })
  api.nvim_create_autocmd("BufWritePost", {
    group = s.group, buffer = buf, callback = function() build(s) end,
  })
  if spec.trigger == "change" then
    s.timer = uv.new_timer()
    api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = s.group, buffer = buf,
      callback = function()
        s.timer:start(M.config.debounce, 0, vim.schedule_wrap(function() build(s) end))
      end,
    })
  end
  api.nvim_create_autocmd({ "BufWipeout", "BufFilePost" }, {
    group = s.group, buffer = buf, callback = function() M.stop(buf) end,
  })
  build(s)
  return s
end

function M.toggle(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if sessions[buf] then M.stop(buf) else M.start(buf) end
end

function M.build(buf)
  local s = sessions[(buf == nil or buf == 0) and api.nvim_get_current_buf() or buf]
  if s then build(s) else M.start(buf) end
end

--- True while the buffer has a preview; for status lines.
function M.active(buf)
  return sessions[(buf == nil or buf == 0) and api.nvim_get_current_buf() or buf] ~= nil
end

function M.log(buf)
  local s = sessions[(buf == nil or buf == 0) and api.nvim_get_current_buf() or buf]
  if not (s and s.log) then return notify("no build has run here") end
  vim.cmd("botright new")
  local b = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(b, 0, -1, false, s.log)
  vim.bo[b].buftype, vim.bo[b].bufhidden, vim.bo[b].modifiable = "nofile", "wipe", false
  api.nvim_buf_set_name(b, "preview log " .. b)
end

function M.setup(opts)
  opts = opts or {}
  local fts = M.config.filetypes
  for ft, spec in pairs(opts.filetypes or {}) do
    fts[ft] = spec and vim.tbl_extend("force", fts[ft] or {}, spec) or nil
  end
  opts.filetypes = nil
  M.config = vim.tbl_extend("force", M.config, opts)
end

-- Saving a stylesheet, script or picture a browser preview uses reloads it.
api.nvim_create_autocmd("BufWritePost", {
  group = group,
  callback = function(a)
    local path = api.nvim_buf_get_name(a.buf)
    for buf, s in pairs(sessions) do
      if buf ~= a.buf and s.spec.view == "browser" and vim.startswith(path, s.dir .. "/") then
        build(s)
      end
    end
  end,
})

api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    for buf in pairs(sessions) do M.stop(buf) end
  end,
})

return M
