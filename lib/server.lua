--[[
    server.lua — Local HTTP server for the AutoSort Web UI.

    Security. The old version set `Access-Control-Allow-Origin: *` with no
    authentication, so any web page you had open could read your inventory and
    trigger a sort. This version:

      * generates a random session token each time it starts; every /api/
        request must carry it (header X-AutoSort-Token or ?token=). The token
        is in the URL AutoSort prints, so opening the UI just works.
      * rejects requests whose Host header is not localhost, which blocks DNS
        rebinding.
      * rejects requests carrying an Origin header, since the UI is same-origin
        and never sends one. A cross-site request always does.
      * sends no CORS headers at all.
      * binds to 127.0.0.1 only.

    Responsiveness. The old version blocked the game thread for up to half a
    second per connection. Here sockets are fully non-blocking: a client that
    has not finished sending is kept in a queue and polled again next frame, so
    no single request can stall rendering. Stale clients are dropped after a
    few seconds.
]]

local socket = require('socket')
local json = require('lib/jsonutil')

local server = {}

server.listener = nil
server.running = false
server.port = nil
server.token = nil
server.api = nil

local clients = {}          -- in-flight requests
local CLIENT_TIMEOUT = 5    -- seconds before an unfinished request is dropped
local MAX_REQUEST = 256 * 1024

local MIME = {
    html = 'text/html; charset=utf-8',
    css  = 'text/css; charset=utf-8',
    js   = 'application/javascript; charset=utf-8',
    json = 'application/json; charset=utf-8',
    svg  = 'image/svg+xml',
    ico  = 'image/x-icon',
    txt  = 'text/plain; charset=utf-8',
}

-- ---------------------------------------------------------------------------
-- Responses
-- ---------------------------------------------------------------------------

local function respond(status, content_type, body)
    body = body or ''
    return table.concat({
        'HTTP/1.1 ' .. status,
        'Content-Type: ' .. content_type,
        'Content-Length: ' .. #body,
        'Connection: close',
        'Cache-Control: no-store',
        'X-Content-Type-Options: nosniff',
        -- The UI needs no framing, no plugins and no outside scripts. Icons
        -- are the one external resource, so images stay unrestricted.
        "Content-Security-Policy: default-src 'self'; img-src * data:; "
            .. "style-src 'self' 'unsafe-inline'; frame-ancestors 'none'",
        '', body,
    }, '\r\n')
end

local function json_response(tbl, status)
    local ok, encoded = pcall(json.encode, tbl or {})
    if not ok then
        encoded = '{"ok":false,"error":"encode failed"}'
    end
    return respond(status or '200 OK', MIME.json, encoded)
end

-- ---------------------------------------------------------------------------
-- Request parsing
-- ---------------------------------------------------------------------------

local function parse(raw)
    local method, target = raw:match('^(%u+)%s+(%S+)%s+HTTP')
    if not method then return nil end

    local path = target:gsub('%?.*$', '')
    local query = target:match('%?(.*)$') or ''

    local headers = {}
    local head = raw:match('^(.-)\r\n\r\n') or raw
    for line in head:gmatch('[^\r\n]+') do
        local k, v = line:match('^([%w%-]+):%s*(.*)$')
        if k then headers[k:lower()] = v end
    end

    local body = ''
    local cut = raw:find('\r\n\r\n', 1, true)
    if cut then body = raw:sub(cut + 4) end

    return { method = method, path = path, query = query,
             headers = headers, body = body }
end

local function query_value(query, key)
    for pair in query:gmatch('[^&]+') do
        local k, v = pair:match('^([^=]+)=?(.*)$')
        if k == key then return (v:gsub('%%(%x%x)', function(h)
            return string.char(tonumber(h, 16))
        end)) end
    end
    return nil
end

-- Is this request allowed to touch the API?
local function authorized(req)
    local host = (req.headers.host or ''):gsub(':%d+$', '')
    if host ~= '127.0.0.1' and host ~= 'localhost' then
        return false, 'bad host'
    end
    -- Browsers attach an Origin header to every POST, including ones from our
    -- own page, so its mere presence proves nothing. What matters is whether it
    -- names THIS server. Anything else (another site, "null" from a sandboxed
    -- frame, or the right host on the wrong port) is refused.
    local origin = req.headers.origin
    if origin then
        local allowed = {
            ['http://127.0.0.1:' .. tostring(server.port)] = true,
            ['http://localhost:' .. tostring(server.port)] = true,
        }
        if not allowed[origin] then
            return false, 'cross-origin request refused'
        end
    end
    local token = req.headers['x-autosort-token'] or query_value(req.query, 'token')
    if token ~= server.token then
        return false, 'bad or missing token'
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Static files
-- ---------------------------------------------------------------------------

local function serve_static(path)
    if path == '/' or path == '' then path = '/index.html' end
    -- Reject traversal and anything that is not a simple file name.
    if path:find('%.%.') or not path:match('^/[%w%-%._/]+$') then
        return respond('403 Forbidden', MIME.txt, 'Forbidden')
    end

    local full = windower.addon_path .. 'ui' .. path
    if not windower.file_exists(full) then
        return respond('404 Not Found', MIME.txt, 'Not found')
    end

    local fh = io.open(full, 'rb')
    if not fh then return respond('404 Not Found', MIME.txt, 'Not found') end
    local body = fh:read('*a')
    fh:close()

    local ext = path:match('%.([%w]+)$') or ''
    return respond('200 OK', MIME[ext] or MIME.txt, body)
end

-- ---------------------------------------------------------------------------
-- Routing
-- ---------------------------------------------------------------------------

local ROUTES = {
    GET = {
        status   = 'status',
        settings = 'get_settings',
        progress = 'progress',
        items    = 'items',
    },
    POST = {
        settings = 'save_settings',
        preview  = 'preview',
        execute  = 'execute',
        stop     = 'stop_sort',
        reload   = 'reload',
    },
}

local function route(req)
    if req.path:sub(1, 5) == '/api/' then
        local ok, why = authorized(req)
        if not ok then
            return json_response({ ok = false, error = why }, '403 Forbidden')
        end

        local endpoint = req.path:sub(6)
        local handler = ROUTES[req.method] and ROUTES[req.method][endpoint]
        if not handler or not server.api[handler] then
            return json_response({ ok = false, error = 'unknown endpoint' }, '404 Not Found')
        end

        local payload
        if req.method == 'POST' and #req.body > 0 then
            local decoded, err = json.decode(req.body)
            if type(decoded) ~= 'table' then
                return json_response({ ok = false, error = 'invalid JSON: ' .. tostring(err) },
                    '400 Bad Request')
            end
            payload = decoded
        end

        local called, result = pcall(server.api[handler], payload)
        if not called then
            return json_response({ ok = false, error = tostring(result) },
                '500 Internal Server Error')
        end
        return json_response(result)
    end

    if req.method == 'GET' then
        return serve_static(req.path)
    end
    return respond('405 Method Not Allowed', MIME.txt, 'Method not allowed')
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function make_token()
    math.randomseed(os.time() + math.floor(os.clock() * 100000))
    local chars = '0123456789abcdefghijklmnopqrstuvwxyz'
    local out = {}
    for i = 1, 24 do
        local n = math.random(#chars)
        out[i] = chars:sub(n, n)
    end
    return table.concat(out)
end

--- Start listening. Returns true, or false plus an error.
function server.start(port, api)
    server.stop()
    server.port = tonumber(port) or 9898
    if server.port < 1024 or server.port > 65535 then
        return false, 'port must be between 1024 and 65535'
    end
    server.api = api
    server.token = make_token()

    local listener, err = socket.bind('127.0.0.1', server.port)
    if not listener then return false, err end
    listener:settimeout(0)

    server.listener = listener
    server.running = true
    clients = {}
    return true
end

function server.stop()
    server.running = false
    for _, c in ipairs(clients) do pcall(function() c.sock:close() end) end
    clients = {}
    if server.listener then
        pcall(function() server.listener:close() end)
        server.listener = nil
    end
end

--- The URL to open, token included.
function server.url()
    return ('http://127.0.0.1:%d/?token=%s'):format(server.port or 9898, server.token or '')
end

-- Has this client sent a complete request yet?
local function complete(c)
    local cut = c.data:find('\r\n\r\n', 1, true)
    if not cut then return false end
    local len = tonumber(c.data:match('[Cc]ontent%-[Ll]ength:%s*(%d+)')) or 0
    return #c.data - (cut + 3) >= len
end

--- Poll the listener and any in-flight clients. Call once per frame.
function server.tick()
    if not server.running or not server.listener then return end
    local now = os.clock()

    -- Accept whatever is waiting, without blocking.
    for _ = 1, 8 do
        local sock = server.listener:accept()
        if not sock then break end
        sock:settimeout(0)
        clients[#clients + 1] = { sock = sock, data = '', started = now }
    end

    local still_open = {}
    for _, c in ipairs(clients) do
        local keep = true

        -- Non-blocking read: `partial` carries whatever arrived so far.
        local chunk, err, partial = c.sock:receive(8192)
        local got = chunk or partial
        if got and #got > 0 then c.data = c.data .. got end

        if #c.data > MAX_REQUEST then
            pcall(function() c.sock:send(respond('413 Payload Too Large', MIME.txt, 'Too large')) end)
            pcall(function() c.sock:close() end)
            keep = false
        elseif complete(c) or err == 'closed' then
            local response
            local ok, result = pcall(function()
                local req = parse(c.data)
                if not req then
                    return respond('400 Bad Request', MIME.txt, 'Bad request')
                end
                return route(req)
            end)
            response = ok and result
                or respond('500 Internal Server Error', MIME.txt, 'Internal error')

            c.sock:settimeout(0.2)
            pcall(function() c.sock:send(response) end)
            pcall(function() c.sock:close() end)
            keep = false
        elseif now - c.started > CLIENT_TIMEOUT then
            pcall(function() c.sock:close() end)
            keep = false
        end

        if keep then still_open[#still_open + 1] = c end
    end
    clients = still_open
end

return server
