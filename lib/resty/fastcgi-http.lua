local fcgi = require 'resty.fastcgi'
local http = require 'resty.http'

local ngx_var           = ngx.var
local ngx_re_gsub       = ngx.re.gsub
local ngx_re_gmatch     = ngx.re.gmatch
local ngx_re_match      = ngx.re.match
local ngx_re_find       = ngx.re.find
local ngx_log           = ngx.log
local ngx_DEBUG         = ngx.DEBUG
local ngx_ERR           = ngx.ERR

local str_char          = string.char
local str_byte          = string.byte
local str_rep           = string.rep
local str_lower         = string.lower
local str_upper         = string.upper
local str_sub           = string.sub


local tbl_concat        = table.concat
local pairs             = pairs
local ipairs            = ipairs


local FCGI_HIDE_HEADERS = {
    "Status"                = true,
    "X-Accel-Expires"       = true,
    "X-Accel-Redirect"      = true,
    "X-Accel-Limit-Rate"    = true,
    "X-Accel-Buffering"     = true,
    "X-Accel-Charset"       = true
}


local _M = {
    _VERSION = '0.01',
}


local mt = { __index = _M }


local function _should_receive_body(method, code)
    if method == "HEAD" then return nil end
    if code == 204 or code == 304 then return nil end
    if code >= 100 and code < 200 then return nil end
    return true
end


local function _hide_headers(headers)
    for _,v in ipairs(FCGI_HIDE_HEADERS) do
        headers[v] = nil
    end
    return headers
end


local function _parse_headers(str)

    -- Only look in the first header_buffer_len bytes
    local header_buffer_len = 1024
    local header_buffer = str_sub(str,1,header_buffer_len)
    local found, header_boundary

    -- Find header boundary
    found, header_boundary, err = ngx_re_find(header_buffer,"\\r?\\n\\r?\\n","jo")

    -- If we can't find the header boundary then return an error
    if not found then
        ngx_log(ngx_ERR,"Unable to find end of HTTP header in first ",header_buffer_len," bytes - aborting")
        return nil, "Error reading HTTP header"
    end

    local http_headers = {}

    for line in ngx_re_gmatch(str_sub(header_buffer,1,header_boundary),"[^\r\n]+","jo") do
        for header_pairs in ngx_re_gmatch(line[0], "([\\w\\-]+)\\s*:\\s*(.+)","jo") do
            local header_name   = header_pairs[1]
            local header_value  = header_pairs[2]
            if not FCGI_HIDE_HEADERS[header_name] then 
                if http_headers[header_name] then
                    http_headers[header_name] = http_headers[header_name] .. ", " .. tostring(header_value)
                else
                    http_headers[header_name] = tostring(header_value)
                end
            end
        end
    end

    return http_headers, str_sub(str,header_boundary+1)
end


function _M.new(_)
    local self = {
        fcgi = fcgi.new(),
        stdout_buffer = "",
    }

    return setmetatable(self, mt)
end


function _M.set_timeout(self, timeout)
    local fcgi = self.fcgi
    return fcgi.sock:settimeout(timeout)
end


function _M.connect(self, ...)
    local fcgi = self.fcgi
    return fcgi.sock:connect(...)
end


function _M.set_keepalive(self, ...)
    local fcgi = self.fcgi
    return fcgi.sock:setkeepalive(...)
end


function _M.get_reused_times(self)
    local fcgi = self.fcgi
    return fcgi,sock:getreusedtimes()
end


function _M.close(self)
    local fcgi = self.fcgi
    return fcgi.sock:close()
end

function _M.get_response_reader(self)
    local buffer            = self.stdout_buffer
    local fcgi              = self.fcgi
    local buffer_length     = #buffer
    local response_reader   = fcgi:get_response_reader()

    return function(chunk_size)
        local chunk_size = chunk_size or 65536
        local data, err

        -- If we have buffered data then return from the buffer 
        if buffer_length > 0 then
            local return_data
            if chunk_size > buffer_length then
                return_data     = buffer
                buffer          = ""
                buffer_length   = 0
            else
                return_data     = str_sub(buffer,1,chunk_size)
                buffer          = str_sub(buffer,chunk_size+1)
                buffer_length   = #buffer
            end
            
            return return_data

        -- Otherwise simply return from the fcgi response reader
        else
            data, err = response_reader(chunk_size)
            if data then
                if data.stderr ~= nil then
                    ngx_log(ngx_ERR,"FastCGI Stderr: ",data.stderr)
                end
                return data.stdout or ""
            else
                return nil, err
            end
        end

    end

end


function _M.request(self,params)
    local fcgi          = self.fcgi
    local sock          = fcgi.sock
    local headers       = params.headers or {}
    local body          = params.body
    local user_params   = params.fastcgi or {}

    local request_method = user_params.request_method or ngx_var.request_method
    local script_name = user_params.script_name or ngx_re_gsub(user_params.request_uri or ngx.var.request_uri, "\\?.*", "","jo")

    -- Set default headers if we can
    if type(body) == 'string' and not headers["Content-Length"] then
        headers["Content-Length"] = #body
    end
    if not headers["Host"] then
        headers["Host"] = self.host
    end
    if params.version == 1.0 and not headers["Connection"] then
        headers["Connection"] = "Keep-Alive"
    end

    local fcgi_params = {
        SCRIPT_NAME       = script_name,
        SCRIPT_FILENAME   = user_params.script_filename or "index.php",
        DOCUMENT_ROOT     = user_params.document_root or ngx_var.document_root,
        REQUEST_METHOD    = request_method,
        CONTENT_TYPE      = user_params.content_type or ngx_var.content_type,
        CONTENT_LENGTH    = headers["Content-Length"] or ngx_var.content_length,
        REQUEST_URI       = user_params.request_uri or ngx_var.request_uri,
        DOCUMENT_URI      = script_name,
        QUERY_STRING      = user_params.args or (ngx_var.args or ""),
        SERVER_PROTOCOL   = user_params.server_protocol or ngx_var.server_protocol,
        GATEWAY_INTERFACE = "CGI/1.1",
        SERVER_SOFTWARE   = "lua-resty-fastcgi",
        REMOTE_ADDR       = ngx_var.remote_addr,
        REMOTE_PORT       = ngx_var.remote_port,
        SERVER_ADDR       = ngx_var.server_addr,
        SERVER_PORT       = ngx_var.server_port,
        SERVER_NAME       = ngx_var.server_name or "host",
    }

    for k,v in pairs(headers) do
        local clean_header = ngx_re_gsub(str_upper(k),"-","_","jo")
        fcgi_params["HTTP_" .. clean_header] = v
    end

    local res, err, chunk

    res, err = fcgi:request({
        params  = fcgi_params,
        stdin   = body,
    })

    if not res then
        return nil, err
    end

    local body_reader = self:get_response_reader()
    local have_http_headers = false
    local res = {status = nil, headers = nil, has_body = false}

    -- Read chunks off the network until we get the first stdout chunk.
    -- Buffer remaining stdout data and log any Stderr info to nginx error log
    repeat
        chunk, err, partial = body_reader()

        if err then
            return nil, err
        end

        -- We can't have stderr and stdout in the same chunk
        if not have_http_headers and #chunk > 0 then
            http_headers,remaining_stdout = _parse_headers(chunk)

            if not http_headers then
                res.status = 500
                return
            end

            self.stdout_buffer = tbl_concat({self.stdout_buffer,remaining_stdout})
            
            res.headers = http_headers

            local status_header = http_headers['Status']

            -- If FCGI response contained a status header, then assume that status
            if status_header then 
                res.status = tonumber(str_sub(status_header, 1, 3))

            -- If a HTTP location is given but no HTTP status, this is a redirect
            elseif http_headers['Location'] then
                res.status = 302

            -- Otherwise assume this request was OK and return 200
            else
                res.status = 200
            end

            res.has_body = _should_receive_body(request_method,res.status)

            return res
        end
    until not chunk

    return res
end

function _M.get_client_body_reader(self,chunksize)
    return http.get_client_body_reader(nil,chunksize)
end

return _M