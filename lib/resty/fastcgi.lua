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

local FCGI_PADDING_BYTES = {
    str_char(0),
    str_char(0,0),
    str_char(0,0,0),
    str_char(0,0,0,0),
    str_char(0,0,0,0,0),
    str_char(0,0,0,0,0,0),
    str_char(0,0,0,0,0,0,0),
}

local function _merge_params(fcgi_params,http_params)
    local new_params = {}

    local idx = 1
    for k,v in pairs(fcgi_params) do
        if v then
            new_params[idx] = {k,v}
            idx = idx + 1
        end
    end

    for header,value in pairs(http_params) do
        clean_header = ngx_re_gsub(str_upper(header),"-","_","jo")
        new_params[idx] = {"HTTP_" .. clean_header,value}
        idx = idx + 1
    end

    return new_params
end


local function _pack(format,params)
    local bytes = ""

    for index, field in ipairs(format) do
        local fieldname = field[1]
        local fieldlength = field[2]
        local defaulval = field[3]

        if params[fieldname] == nil then
            bytes = bytes .. ntob(defaulval,fieldlength)
        else
            bytes = bytes .. ntob(params[fieldname],fieldlength)
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
        res[field[1]] = bton(str_sub(str,idx,idx + field[2] - 1))
        idx = idx + field[2]
    end

    return res
end


local FCGI_PREPACKED = {
    end_params = _pack_header({
        type    = FCGI_PARAMS,
    }),
    begin_request = _pack_header({
        type            = FCGI_BEGIN_REQUEST,
        request_id      = 1,
        content_length  = FCGI_HEADER_LEN,
    }) .. _pack(FCGI_BEGIN_REQ_FORMAT,{
        role    = FCGI_RESPONDER,
        flags   = 1,
    }),
    abort_request = _pack_header({
        type            = FCGI_ABORT_REQUEST,
    }),
    empty_stdin = _pack_header({
        type            = FCGI_STDIN,
        content_length  = 0,
    }),
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
        buffer = {},
        buffer_length = 1024,
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

    -- If we can't find the header boundary  then return an error
    if not found then
        ngx_log(ngx_ERR,"Unable to find end of HTTP header in first ",header_buffer_len," bytes - aborting")
        return nil, "Error reading HTTP header"
    end

    local http_headers = {}

    for line in ngx_re_gmatch(str_sub(header_buffer,1,header_boundary),"[^\r\n]+","jo") do
        for header_pairs in ngx_re_gmatch(line[0], "([\\w\\-]+)\\s*:\\s*(.+)","jo") do
            local header_name   = header_pairs[1]
            local header_value  = header_pairs[2]
            if http_headers[header_name] then
                http_headers[header_name] = http_headers[header_name] .. ", " .. tostring(header_value)
            else
                http_headers[header_name] = tostring(header_value)
            end
        end
    end

    return http_headers, str_sub(str,header_boundary+1)
end


local function _format_params(params)
    local new_params = {}
    local idx = 1

    -- Iterate over each param
    for _,pair in ipairs(params) do
        local key = pair[1]
        local value = pair[2]
        local keylen = #key
        local valuelen = #value

        -- If length of field is longer than 127, we represent 
        -- it as 4 bytes with high bit set to 1 (+2147483648 or FCGI_PARAM_HIGH_BIT)
        new_params[idx] = tbl_concat({
            ((keylen < 127) and ntob(keylen) or ntob(keylen + FCGI_PARAM_HIGH_BIT,4)),
            ((valuelen < 127) and ntob(valuelen) or ntob(valuelen + FCGI_PARAM_HIGH_BIT,4)),
            key,
            value,
        })
        idx = idx + 1
    end

    local new_params_str = tbl_concat(new_params)

    local start_params, padding = _pack_header({
        type            = FCGI_PARAMS,
        content_length  = #new_params_str
    })

    return tbl_concat({ start_params, new_params_str, _pad(padding), FCGI_PREPACKED.end_params })
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
    local idx = 1

    repeat
        -- While we still have stdin data, build up STDIN record in chunks
        chunk_length = (#stdin > FCGI_BODY_MAX_LENGTH) and FCGI_BODY_MAX_LENGTH or #stdin

        header, padding = _pack_header({
            type            = FCGI_STDIN,
            content_length  = chunk_length,
        })

        stdin_chunk[1] = header
        stdin_chunk[2] = str_sub(stdin,1,chunk_length)
        stdin_chunk[3] = _pad(padding)

        to_send[idx] = tbl_concat(stdin_chunk)
        stdin = str_sub(stdin,chunk_length+1)
        idx = idx + 1
    until #stdin == 0

    return tbl_concat(to_send)
end


function _M.get_response_reader(self)
    local sock              = self.sock
    local record_type       = nil
    local content_length    = 0
    local padding_length    = 0


    return function(chunksize)
        local chunksize = chunksize or 65536
        local res = { stdout = "", stderr = ""}
        local err, header_bytes, bytes_to_read, data

        -- If we don't have a length of data to read yet, attempt to read a FCGI record header
        if not record_type then
            ngx_log(ngx_DEBUG,"Attempting to grab next FCGI record")
            local header_bytes, err = sock:receive(FCGI_HEADER_LEN)
            local header = _unpack(FCGI_HEADER_FORMAT,header_bytes)

            if not header then
                return nil, err or "Unable to parse FCGI record header"
            end

            record_type     = header.type
            content_length  = header.content_length
            padding_length  = header.padding_length

            ngx_log(ngx_DEBUG,"New content length is ",content_length," padding ",padding_length)

            -- If we've reached the end of the request, return nil
            if record_type == FCGI_END_REQUEST then
                ngx_log(ngx_DEBUG,"Attempting to read end request")
                read_bytes, err = sock:receive(content_length)

                if not read_bytes then
                    return nil, err or "Unable to parse FCGI end request body"
                end

                return nil -- TODO: Return end request format correctly without breaking
            end
        end

        -- Calculate maximum readable buffer size
        bytes_to_read = (chunksize >= content_length) and content_length or chunksize

        -- If we have any bytes to read, read these now
        if bytes_to_read > 0 then
            data, err = sock:receive(bytes_to_read)

            if not data then
                return nil, err or "Unable to retrieve request body"
            end

            -- Reduce content_length by the amount that we've read so far
            content_length = content_length - bytes_to_read
            ngx_log(ngx_DEBUG,"Reducing content length by ", bytes_to_read," bytes to ",content_length)
        end

        -- Place received data into correct result attribute based on record type
        if record_type == FCGI_STDOUT then
            res.stdout = data
        elseif record_type == FCGI_STDERR then
            res.stderr = data
        else
            return nil, err or "Attempted to receive an unknown FCGI record"
        end

        -- If we've read all of the data that we have 'available' in this record, then start again
        -- by attempting to parse another record the next time this function is called.
        if content_length == 0 then
            _ = sock:receive(padding_length)
            ngx_log(ngx_DEBUG,"Resetting record type")
            record_type = nil
        end

        return res, nil
    end

end


function _M.request_simple(self,params)
    local bytes, err = self:request(params)
    if not bytes then
        return nil, err
    end

    local body_reader = self:get_response_reader()

    local chunks = {}
    local idx = 1
    local chunk

    repeat
        chunk, err = body_reader()

        if err then
            return nil, err, tbl_concat(chunks)
        end

        if chunk then
            chunks[idx] = chunk.stdout
            idx = idx + 1
        end
    until not chunk

    local body = tbl_concat(chunks)


    local http_headers, body = _parse_headers(body)
    local status_header = http_headers['Status']

    local res = { body = "", headers = {}, status = 200}

    -- If we've been given a specific HTTP status, extract it
    if status_header then
        res.status = tonumber(str_sub(status_header, 1, 3))
        res.status_line = status_header

    -- If a HTTP location is given but no HTTP status, this is a redirect
    elseif http_headers['Location'] then
        res.status = 302
        res.status_line = "302 Moved Temporarily"

    -- Otherwise assume this request was OK and return 200
    else
        res.status = 200
        res.status_line = "200 OK"
    end

    res.headers = _hide_headers(http_headers)

    res.body = body

    return res, err
end


function _M.request(self,params)
    local sock = self.sock
    local body = params.body or ""

    local merged_params = _merge_params(params.fastcgi_params,params.headers)

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

    return bytes_sent, nil
end

return _M