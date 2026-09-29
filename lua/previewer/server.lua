-- A small HTTP server for browser previews, on 127.0.0.1 only. Each session
-- serves one directory under /<id>/, puts a live-reload script into every
-- HTML page, and tells open pages to reload over server-sent events. An open
-- page holds its event stream open, so the number of streams says whether
-- the preview is still being looked at.
--
-- Everything here runs in libuv callbacks: no vim.api, no vim.fn.

local uv = vim.uv
local M = {}

local server, port
local sessions, last_id = {}, 0

local types = {
  html = "text/html; charset=utf-8", htm = "text/html; charset=utf-8",
  css = "text/css; charset=utf-8", js = "text/javascript; charset=utf-8",
  mjs = "text/javascript; charset=utf-8", json = "application/json",
  txt = "text/plain; charset=utf-8", md = "text/plain; charset=utf-8",
  xml = "application/xml", svg = "image/svg+xml", png = "image/png",
  jpg = "image/jpeg", jpeg = "image/jpeg", gif = "image/gif",
  webp = "image/webp", avif = "image/avif", ico = "image/x-icon",
  woff = "font/woff", woff2 = "font/woff2", ttf = "font/ttf", otf = "font/otf",
  pdf = "application/pdf", mp4 = "video/mp4", webm = "video/webm",
  mp3 = "audio/mpeg", ogg = "audio/ogg", wasm = "application/wasm",
}

-- Keeps the scroll position across reloads; Firefox mostly does this itself,
-- but not when the page grows or shrinks while loading.
local script = [[
<script>(() => {
  const key = "previewer:" + location.pathname;
  const y = sessionStorage.getItem(key);
  if (y !== null) {
    sessionStorage.removeItem(key);
    addEventListener("load", () => scrollTo(0, +y));
  }
  new EventSource("/%d/__events__").onmessage = () => {
    sessionStorage.setItem(key, scrollY);
    location.reload();
  };
})();</script>
]]

local function inject(html, id)
  local tag = script:format(id)
  local at = html:find("</[bB][oO][dD][yY]%s*>")
  if at then return html:sub(1, at - 1) .. tag .. html:sub(at) end
  return html .. tag
end

local function close(c)
  if not c:is_closing() then c:close() end
end

local function respond(c, status, ctype, body)
  local head = ("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n"
    .. "Cache-Control: no-store\r\nConnection: close\r\n\r\n"):format(status, ctype, #body)
  c:write(head .. body)
  c:shutdown(function() close(c) end)
end

local function read_file(path)
  local st = uv.fs_stat(path)
  if st and st.type == "directory" then
    path = path:gsub("/?$", "/index.html")
  end
  local f = io.open(path, "rb")
  if not f then return end
  local data = f:read("*a")
  f:close()
  return data, path
end

-- Returns true when the connection stays open (an event stream).
local function handle(c, request)
  local method, target = request:match("^(%u+) (%S+)")
  if method ~= "GET" then
    respond(c, "405 Method Not Allowed", "text/plain", "")
    return
  end
  local path = target:gsub("[?#].*", ""):gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  local id, rest = path:match("^/(%d+)(/.*)$")
  local s = id and sessions[tonumber(id)]
  if not s then
    respond(c, "404 Not Found", "text/plain", "no such preview\n")
    return
  end

  if rest == "/__events__" then
    c:write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
      .. "Cache-Control: no-store\r\n\r\n: hello\n\n")
    s.clients[c] = true
    return true
  end

  if ("/" .. rest .. "/"):find("/%.%./") then
    respond(c, "403 Forbidden", "text/plain", "")
    return
  end
  local data, file
  if s.page and rest == s.page_path then
    data, file = read_file(s.page)
  else
    data, file = read_file(s.root .. rest)
  end
  if not data then
    respond(c, "404 Not Found", "text/plain", "not found: " .. rest .. "\n")
    return
  end
  local ext = file:match("%.([%w]+)$")
  ext = ext and ext:lower()
  if ext == "html" or ext == "htm" then data = inject(data, id) end
  respond(c, "200 OK", types[ext] or "application/octet-stream", data)
end

local function accept()
  local c = uv.new_tcp()
  server:accept(c)
  local buf, streaming = "", false
  c:read_start(function(err, chunk)
    if err or not chunk then
      for _, s in pairs(sessions) do s.clients[c] = nil end
      close(c)
      return
    end
    if streaming then return end
    buf = buf .. chunk
    if buf:find("\r\n\r\n", 1, true) then
      local ok, keep = pcall(handle, c, buf)
      if not ok then
        respond(c, "500 Internal Server Error", "text/plain", tostring(keep))
      end
      streaming = ok and keep or false
    elseif #buf > 65536 then
      close(c)
    end
  end)
end

local function start(want_port)
  if server then return true end
  server = uv.new_tcp()
  local ok, err = server:bind("127.0.0.1", want_port or 0)
  if ok then ok, err = server:listen(64, function(e) if not e then accept() end end) end
  if not ok then
    close(server)
    server = nil
    return false, err
  end
  port = server:getsockname().port
  return true
end

--- Serve `root` under a new id. `page`, when given, is a file outside the
--- root that is served at `page_path` instead (a build output next to its
--- sources, so relative links still work). Returns the id, or nil and an error.
function M.add(root, page, page_path, want_port)
  local ok, err = start(want_port)
  if not ok then return nil, err end
  last_id = last_id + 1
  sessions[last_id] = { root = root, page = page, page_path = page_path, clients = {} }
  return last_id
end

function M.url(id, path)
  return ("http://127.0.0.1:%d/%d%s"):format(port, id, path)
end

--- Number of pages currently open on this session.
function M.clients(id)
  local s = sessions[id]
  return s and vim.tbl_count(s.clients) or 0
end

function M.reload(id)
  local s = sessions[id]
  if not s then return end
  for c in pairs(s.clients) do
    if c:is_closing() then
      s.clients[c] = nil
    else
      c:write("data: reload\n\n")
    end
  end
end

--- Drop the session; its pages keep what they show but stop reloading. With
--- no sessions left the server goes too.
function M.remove(id)
  local s = sessions[id]
  if not s then return end
  sessions[id] = nil
  for c in pairs(s.clients) do close(c) end
  if not next(sessions) and server then
    close(server)
    server = nil
  end
end

return M
