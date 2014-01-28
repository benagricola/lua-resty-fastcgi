local binutil           = require 'resty.binutil'
local ntob              = binutil.ntob
local bton              = binutil.bton

local bit_band          = bit.band

local ngx_socket_tcp    = ngx.socket.tcp
local ngx_encode_args   = ngx.encode_args
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

local math_floor        = math.floor

local tbl_concat        = table.concat
local pairs             = pairs
local ipairs            = ipairs


local _M = {
    _VERSION = '0.01',
}

local mt = { __index = _M }


local FCGI_HEADER_LEN         = 0x08
local FCGI_VERSION_1          = 0x01
local FCGI_BEGIN_REQUEST      = 0x01
local FCGI_ABORT_REQUEST      = 0x02
local FCGI_END_REQUEST        = 0x03
local FCGI_PARAMS             = 0x04
local FCGI_STDIN              = 0x05
local FCGI_STDOUT             = 0x06
local FCGI_STDERR             = 0x07
local FCGI_DATA               = 0x08
local FCGI_GET_VALUES         = 0x09
local FCGI_GET_VALUES_RESULT  = 0x10
local FCGI_UNKNOWN_TYPE       = 0x11
local FCGI_MAXTYPE            = 0x11
local FCGI_PARAM_HIGH_BIT     = 2147483648
local FCGI_BODY_MAX_LENGTH    = 32768
local FCGI_KEEP_CONN          = 0x01
local FCGI_NO_KEEP_CONN       = 0x00
local FCGI_NULL_REQUEST_ID    = 0x00
local FCGI_RESPONDER          = 0x01
local FCGI_AUTHORIZER         = 0x02
local FCGI_FILTER             = 0x03


local FCGI_HEADER_FORMAT = {
    {"version",1,FCGI_VERSION_1},
    {"type",1,nil},
    {"request_id",2,1},
    {"content_length",2,0},
    {"padding_length",1,0},
    {"reserved",1,0}
}


local FCGI_BEGIN_REQ_FORMAT = {
    {"role",2,FCGI_RESPONDER},
    {"flags",1,0},
    {"reserved",5,0}
}


local FCGI_END_REQ_FORMAT = {
    {"status",4,nil},
    {"protocolStatus",1,nil},
    {"reserved",3,nil}
}


local FCGI_HIDE_HEADERS = {
    "Status",
    "X-Accel-Expires",
    "X-Accel-Redirect",
    "X-Accel-Limit-Rate",
    "X-Accel-Buffering",
    "X-Accel-Charset"
}


local FCGI_DEFAULT_PARAMS = {
    {"SCRIPT_FILENAME", "document_root"},
    {"REQUEST_METHOD", "request_method"},
    {"CONTENT_TYPE", "content_type"},
    {"CONTENT_LENGTH", "content_length"},
    {"REQUEST_URI", "request_uri"},
    {"QUERY_STRING", "args"},
    {"DOCUMENT_ROOT", "document_root"},
    {"SERVER_PROTOCOL", "server_protocol"},
    {"GATEWAY_INTERFACE", "","CGI/1.1"},
    {"SERVER_SOFTWARE", "","lua-resty-fastcgi/" .. _M._VERSION},
    {"REMOTE_ADDR", "remote_addr"},
    {"REMOTE_PORT", "remote_port"},
    {"SERVER_ADDR", "server_addr"},
    {"SERVER_PORT", "server_port"},
    {"SERVER_NAME", "server_name"},
}


local FCGI_PADDING_BYTES = {
    str_char(0),
    str_char(0,0),
    str_char(0,0,0),
    str_char(0,0,0,0),
    str_char(0,0,0,0,0),
    str_char(0,0,0,0,0,0),
    str_char(0,0,0,0,0,0,0),
}

local function _merge_fcgi_params(params)
    local new_params = {}

    local set_params = {}
    for k,v in pairs(params) do
        if v then 
            new_params[#new_params+1] = {k,v}
            set_params[k] = true
        end
    end

    -- Populate default params if they don't exist in user params
    for _,v in ipairs(FCGI_DEFAULT_PARAMS) do
        if not set_params[v[1]] then
            local nginx_var = ngx.var[v[2]]
            if v[2] ~= "" then
                new_params[#new_params+1] = {v[1],nginx_var or ""}
            else
                new_params[#new_params+1] = {v[1],v[3] or ""}
            end
        end
    end

    return new_params
end


local function _pack(format,params)
    local bytes = ""

    for index, field in ipairs(format) do
        if params[field[1]] == nil then
            bytes = bytes .. ntob(field[3],field[2])
        else
            bytes = bytes .. ntob(params[field[1]],field[2])
        end
    end

    return bytes
end


local function _pack_header(params)
    local align = 8

    params.padding_length = bit_band(-(params.content_length or 0),align - 1)
    local header = _pack(FCGI_HEADER_FORMAT,params)
    return header, params.padding_length
end


local function _unpack(format,str)
    -- If we received nil, return nil
    if not str then
        return nil
    end

    local res = {}
    local idx = 1

    -- Extract bytes based on format. Convert back to number and place in res rable
    for _, field in ipairs(format) do
        res[field[1]] = binutil.bton(str_sub(str,idx,idx + field[2] - 1))
        idx = idx + field[2]
    end

    return res
end


local FCGI_PREPACKED = {
    end_params = _pack_header{
        type    = FCGI_PARAMS,
    },
    begin_request = _pack_header{
        type            = FCGI_BEGIN_REQUEST,
        request_id      = 1,
        content_length  = FCGI_HEADER_LEN,
    } .. _pack(FCGI_BEGIN_REQ_FORMAT,{
        role    = FCGI_RESPONDER,
        flags   = 1,
    }),
    abort_request = _pack_header{
        type            = FCGI_ABORT_REQUEST,
    },
    empty_stdin = _pack_header{
        type            = FCGI_STDIN,
        content_length  = 0,
    },
}


local function _pad(bytes)
    return (bytes == 0) and "" or FCGI_PADDING_BYTES[bytes]
end


function _M.new(_)
    local sock, err = ngx_socket_tcp()
    if not sock then
        return nil, err
    end

    local self = {
        sock = sock,
        keepalives = false,
    }

    return setmetatable(self, mt)
end


function _M.set_timeout(self, timeout)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:settimeout(timeout)
end


function _M.connect(self, ...)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    self.host = select(1, ...)

    return sock:connect(...)
end


function _M.set_keepalive(self, ...)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:setkeepalive(...)
end


function _M.get_reused_times(self)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:getreusedtimes()
end


function _M.close(self)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:close()
end

local function _parse_headers(str)
    local headers = {}

    for line in ngx_re_gmatch(str,"[^\r\n]+","jo") do
        for header_pairs in ngx_re_gmatch(line[0], "([\\w\\-]+)\\s*:\\s*(.+)","jo") do
            if headers[header_pairs[1]] then
                headers[header_pairs[1]] = headers[header_pairs[1]] .. ", " .. tostring(header_pairs[2])
            else
                headers[header_pairs[1]] = tostring(header_pairs[2])
            end
        end
    end
    return headers
end

-- Remove 
local function _hide_headers(headers)
    for _,v in ipairs(FCGI_HIDE_HEADERS) do
        headers[v] = nil
    end
    return headers
end

local function _format_params(params)
    local new_params = ""

    local keylen, valuelen, key, value

    -- Iterate over each param
    for _,pair in ipairs(params) do
        key = pair[1]
        value = pair[2]
        keylen = #key
        valuelen = #value

        -- If length of field is longer than 127, we represent 
        -- it as 4 bytes with high bit set to 1 (+2147483648 or FCGI_PARAM_HIGH_BIT)
        new_params = new_params ..
            ((keylen < 127) and ntob(keylen) or ntob(keylen + FCGI_PARAM_HIGH_BIT,4)) ..
            ((valuelen < 127) and ntob(valuelen) or ntob(valuelen + FCGI_PARAM_HIGH_BIT,4)) ..
            key ..
            value
    end

    local start_params, padding = _pack_header{
        type            = FCGI_PARAMS,
        content_length  = #new_params
    }

    return tbl_concat{ start_params, new_params, _pad(padding), FCGI_PREPACKED.end_params }
end


local function _format_stdin(stdin)
    if #stdin == 0 then
        return FCGI_PREPACKED.empty_stdin
    end

    local chunk_length

    local to_send = {}

    local stdin_chunk = {
        "",
        "",
        ""
    }

    local header = ""
    local padding = 0

    repeat
        -- While we still have stdin data, build up STDIN record
        -- Max 65k data in each
        chunk_length = (#stdin > FCGI_BODY_MAX_LENGTH) and FCGI_BODY_MAX_LENGTH or #stdin

        header, padding = _pack_header{
            type            = FCGI_STDIN,
            content_length  = chunk_length,
        }

        stdin_chunk[1] = header
        stdin_chunk[2] = str_sub(stdin,1,chunk_length)
        stdin_chunk[3] = _pad(padding)

        to_send[#to_send+1] = tbl_concat(stdin_chunk)
        stdin = str_sub(stdin,chunk_length+1) -- str:sub is inclusive of the first character so we want to chunk at the next index
    until #stdin == 0

    return tbl_concat(to_send)
end


function _M.request(self,params)
    local sock = self.sock
    local body = params.body or ""

    local merged_params = _merge_fcgi_params(params.fastcgi_params)
    local http_params = params.headers

    local clean_header = ""
    for header,value in pairs(http_params) do
        clean_header = ngx_re_gsub(str_upper(header),"-","_","jo")
        merged_params[#merged_params+1] = {"HTTP_" .. clean_header,value}
    end

    -- Send both of these in one packet if possible, to reduce RTT for request
    local req = {
        FCGI_PREPACKED.begin_request,   -- Generate start of request
        _format_params(merged_params),  -- Generate params (HTTP / FCGI headers)
        _format_stdin(body),            -- Generate body
    }

    local bytes_sent, err = sock:send(req)

    if not bytes_sent then
        return nil, err
    end

    local res = { headers = {}, body = "", status = 200 }

    local stdout = ""
    local stderr = ""

    local reading_http_headers  = true
    local header_boundary       = 0
    local data                  = ""
    local http_headers          = ""

    -- Read fastcgi records and parse
    while true do
        -- Read and unpack 8 bytes of next record header
        local header_bytes, err = sock:receive(FCGI_HEADER_LEN)
        local header = _unpack(FCGI_HEADER_FORMAT,header_bytes)

        if not header then
            return nil, err or "Unable to parse FCGI record header"
        end

        -- Read data and discard padding
        data, err = sock:receive(header.content_length)
        _ = sock:receive(header.padding_length)

        if not data then
            return nil, err
        end

        -- If this is a stdout packet, attempt to read and parse HTTP headers first.
        -- Once done, read the remaining data to stdout buffer
        if header.type == FCGI_STDOUT then
            
            if reading_http_headers then
                -- Attempt to find header boundary (2 x newlines)
                found, header_boundary, err = ngx_re_find(data,"\\r?\\n\\r?\\n","jo")

                -- If we can't find the header boundary in the first record, this means
                -- it's either very long (> FCGI_BODY_MAX_LENGTH) or not formatted correctly.
                if not found then
                    ngx_log(ngx_ERR,"Unable to find end of HTTP header in first FCGI_STDOUT - aborting")
                    return nil, "Error reading HTTP header"
                end
                -- Parse headers into table and stop attempting to parse
                http_headers = _parse_headers(str_sub(data,1,header_boundary))
                reading_http_headers = false

                -- Push rest of request body into stdout
                stdout = stdout .. str_sub(data,(header_boundary+1))
            else
                stdout = stdout .. data
            end
            

        -- If this is stderr, read contents into stderr buffer
        elseif header.type == FCGI_STDERR then
            stderr = stderr .. data

        -- If this is end request, put buffers into result table and return
        elseif header.type == FCGI_END_REQUEST then

            -- Unpack EoR
            local stats = _unpack(FCGI_END_REQ_FORMAT,data)

            if not stats then
                return nil, "Error parsing FCGI record"
            end

            -- If we've been given a specific HTTP status, extract it
            if http_headers['Status'] then
                res.status = tonumber(str_sub(http_headers['Status'], 1, 3))
                res.status_line = http_headers['Status']

            -- If a HTTP location is given but no HTTP status, this is a redirect
            elseif http_headers['Location'] then
                res.status = 302
                res.status_line = "302 Moved Temporarily"

            -- Otherwise assume this request was OK and return 200
            else
                res.status = 200
                res.status_line = "200 OK"
            end

            if #stderr > 0 then
                ngx_log(ngx_ERR,"Fastcgi STDERR: ",stderr)
            end

            res.headers = _hide_headers(http_headers)
            res.body = stdout

            return res

        -- Otherwise we received an FCGI record we don't understand - ERROR
        else
            return nil, "Received unidentified FCGI record, type: " .. header.type
        end

    end
end

return _M