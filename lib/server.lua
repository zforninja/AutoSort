--[[
    server.lua — Minimal non-blocking HTTP/1.1 server for AutoSort.

    Design goals:
      * Never block the FFXI game thread. The listening socket is set to a
        zero timeout and polled once per frame via server.tick().
      * Serve the static Web UI from <addon_dir>/ui/.
      * Handle a small set of JSON API endpoints. Because tick() is called on
        the game thread (from the addon's prerender event), request handlers
        may safely call windower.ffxi.* functions directly.

    Only localhost connections are accepted, so requests are tiny and fast; a
    connected client is read to completion within the same tick using a short
    per-socket timeout.

    API handlers are supplied by the main addon via server.start(port, api),
    where `api` is a table:
        api.status()          -> Lua table  (GET  /api/status)
        api.get_settings()    -> Lua table  (GET  /api/settings)
        api.save_settings(t)  -> Lua table  (POST /api/settings)
        api.preview()         -> Lua table  (POST /api/preview)
        api.execute()         -> Lua table  (POST /api/execute)
        api.progress()        -> Lua table  (GET  /api/progress)
        api.stop_sort()       -> Lua table  (POST /api/stop)
]]

local socket = require('socket')
-- Windower's bundled `json` library only DECODES (json.parse) and provides no
-- json.encode/json.decode, so we use our own self-contained encoder/decoder.
local json = require('lib/jsonutil')

local server = {}

server.listener = nil
server.port = nil
server.api = nil
server.running = false

-- MIME types for the static file server.
local MIME = {
    html = 'text/html; charset=utf-8',
    css  = 'text/css; charset=utf-8',
    js   = 'application/javascript; charset=utf-8',
    json = 'application/json; charset=utf-8',
    png  = 'image/png',
    svg  = 'image/svg+xml',
    ico  = 'image/x-icon',
    txt  = 'text/plain; charset=utf-8',
}

local function ext_of(path)
    return path:match('%.([%w]+)$')
end

-- Build a raw HTTP response string.
local function build_response(status, content_type, body, extra_headers)
    body = body or ''
    local headers = {
        ('HTTP/1.1 %s'):format(status),
        ('Content-Type: %s'):format(content_type),
        ('Content-Length: %d'):format(#body),
        'Connection: close',
        'Access-Control-Allow-Origin: *',
        'Access-Control-Allow-Methods: GET, POST, OPTIONS',
        'Access-Control-Allow-Headers: Content-Type',
        'Cache-Control: no-store',
    }
    if extra_headers then
        for _, h in ipairs(extra_headers) do headers[#headers + 1] = h end
    end
    return table.concat(headers, '\r\n') .. '\r\n\r\n' .. body
end

local function json_response(tbl, status)
    local ok, encoded = pcall(json.encode, tbl or {})
    if not ok then
        encoded = '{"error":"encode failed"}'
    end
    return build_response(status or '200 OK', MIME.json, encoded)
end

-- Read and serve a static file from the ui/ directory. Path traversal is
-- blocked by rejecting '..'.
local function serve_static(path)
    if path == '/' or path == '' then
        path = '/index.html'
    end
    if path:find('%.%.') then
        return build_response('403 Forbidden', MIME.txt, 'Forbidden')
    end

    local full = windower.addon_path .. 'ui' .. path
    if not windower.file_exists(full) then
        return build_response('404 Not Found', MIME.txt, 'Not Found: ' .. path)
    end

    local fh = io.open(full, 'rb')
    if not fh then
        return build_response('404 Not Found', MIME.txt, 'Not Found')
    end
    local body = fh:read('*a')
    fh:close()

    local ct = MIME[ext_of(path) or ''] or MIME.txt
    return build_response('200 OK', ct, body)
end

-- Parse the request line + headers + body from a raw request string.
local function parse_request(raw)
    local method, path = raw:match('^(%u+)%s+(%S+)%s+HTTP')
    if not method then return nil end

    -- Strip query string from the path for routing.
    local clean_path = path:gsub('%?.*$', '')

    local header_end = raw:find('\r\n\r\n', 1, true)
    local body = ''
    if header_end then
        body = raw:sub(header_end + 4)
    end
    return { method = method, path = clean_path, body = body, raw = raw }
end

-- Route a parsed request to a handler and return a raw response string.
local function route(req)
    local api = server.api or {}

    -- CORS preflight.
    if req.method == 'OPTIONS' then
        return build_response('204 No Content', MIME.txt, '')
    end

    -- API endpoints.
    if req.path:sub(1, 5) == '/api/' then
        local endpoint = req.path:sub(6)

        if req.method == 'GET' and endpoint == 'status' then
            return json_response(api.status and api.status() or {})
        elseif req.method == 'GET' and endpoint == 'settings' then
            return json_response(api.get_settings and api.get_settings() or {})
        elseif req.method == 'POST' and endpoint == 'settings' then
            local ok, decoded = pcall(json.decode, req.body)
            if not ok or type(decoded) ~= 'table' then
                return json_response({ ok = false, error = 'invalid JSON' }, '400 Bad Request')
            end
            return json_response(api.save_settings and api.save_settings(decoded) or { ok = true })
        elseif req.method == 'POST' and endpoint == 'preview' then
            return json_response(api.preview and api.preview() or {})
        elseif req.method == 'POST' and endpoint == 'execute' then
            return json_response(api.execute and api.execute() or {})
        elseif req.method == 'GET' and endpoint == 'progress' then
            return json_response(api.progress and api.progress() or {})
        elseif req.method == 'POST' and endpoint == 'stop' then
            return json_response(api.stop_sort and api.stop_sort() or { ok = true })
        else
            return json_response({ error = 'unknown endpoint' }, '404 Not Found')
        end
    end

    -- Everything else: static files.
    if req.method == 'GET' then
        return serve_static(req.path)
    end

    return build_response('405 Method Not Allowed', MIME.txt, 'Method Not Allowed')
end

-- Fully read an HTTP request from a client socket. Honors Content-Length for
-- POST bodies. Uses a short timeout so a misbehaving client cannot stall the
-- game thread for long.
local function read_request(client)
    client:settimeout(0.5)
    local buffer = {}
    local data = ''

    -- Read until we have the full header block.
    while not data:find('\r\n\r\n', 1, true) do
        local chunk, err, partial = client:receive('*l')
        if chunk then
            buffer[#buffer + 1] = chunk .. '\r\n'
            data = table.concat(buffer)
        elseif partial and #partial > 0 then
            buffer[#buffer + 1] = partial
            data = table.concat(buffer)
            break
        else
            -- timeout or closed
            break
        end
        if err == 'closed' then break end
    end

    -- Determine content length for the body.
    local len = tonumber(data:match('[Cc]ontent%-[Ll]ength:%s*(%d+)')) or 0
    if len > 0 then
        local header_end = data:find('\r\n\r\n', 1, true)
        local have = 0
        if header_end then
            have = #data - (header_end + 3)
        end
        if have < len then
            local remaining = len - have
            local body_chunk = client:receive(remaining)
            if body_chunk then
                data = data .. body_chunk
            end
        end
    end

    return data
end

--- Start the server on the given port with the supplied api handler table.
function server.start(port, api)
    server.port = port or 9898
    server.api = api

    local listener, err = socket.bind('127.0.0.1', server.port)
    if not listener then
        return false, err
    end
    listener:settimeout(0) -- non-blocking accept
    server.listener = listener
    server.running = true
    return true
end

--- Poll for and handle any pending connections. Call once per frame.
function server.tick()
    if not server.running or not server.listener then return end

    -- Handle as many queued clients as are immediately available this frame.
    for _ = 1, 8 do
        local client = server.listener:accept()
        if not client then break end

        local ok, response = pcall(function()
            local raw = read_request(client)
            local req = parse_request(raw)
            if not req then
                return build_response('400 Bad Request', MIME.txt, 'Bad Request')
            end
            return route(req)
        end)

        if not ok then
            response = build_response('500 Internal Server Error', MIME.txt, 'Internal Server Error')
        end

        client:settimeout(1)
        client:send(response)
        client:close()
    end
end

--- Stop the server and release the port.
function server.stop()
    server.running = false
    if server.listener then
        server.listener:close()
        server.listener = nil
    end
end

return server
