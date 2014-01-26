local ffi = require 'ffi'
local ngx_socket_tcp = ngx.socket.tcp
local str_char = string.char
local str_byte = string.byte
local str_rep = string.rep
local str_gmatch = string.gmatch
local str_lower = string.lower
local str_upper = string.upper
local str_find = string.find
local str_sub = string.sub
local math_floor = math.floor
local tbl_concat = table.concat
local ngx_encode_args = ngx.encode_args
local ngx_re_match = ngx.re.match
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local co_yield = coroutine.yield
local ffi_abi = ffi.abi
local pairs = pairs
local bit_band = bit.band
local binutil = require 'resty.binutil'

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

local FCGI_END_REQ_FORMAT = {
    {"status",4,nil},
    {"protocolStatus",1,nil},
    {"reserved",3,nil}
}

local function _pad(bytes)
    return str_rep(str_char(0), bytes)
end


function _M.new(_)
    local sock, err = ngx_socket_tcp()
    if not sock then
        return nil, err
    end

    local self = {
        sock = sock,
        keepalives = true,
        default_params = {
            SCRIPT_FILENAME     = ngx.var.document_root .. "/index.php",
            QUERY_STRING        = ngx.var.query_string,
            REQUEST_METHOD      = ngx.var.request_method,
            CONTENT_TYPE        = ngx.var.content_type,
            CONTENT_LENGTH      = ngx.var.content_length,
            REQUEST_URI         = ngx.var.request_uri,
            DOCUMENT_ROOT       = ngx.var.document_root,
            SERVER_PROTOCOL     = ngx.var.server_protocol,
            GATEWAY_INTERFACE   = "CGI/1.1",
            SERVER_SOFTWARE     = "lua-resty-fastcgi/" .. _M._VERSION,
            REMOTE_ADDR         = ngx.var.remote_addr,
            REMOTE_PORT         = ngx.var.remote_port,
            SERVER_ADDR         = ngx.var.server_addr,
            SERVER_PORT         = ngx.var.server_port,
            SERVER_NAME         = ngx.var.server_name,
        }
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


function _M._merge_fcgi_params(self,params)
    for k,v in pairs(self.default_params) do
        if not params[k] then
            params[k] = v
        end
    end

    return params
end


function _M._pack_header(self,params)
    local align = 8
    local header = {}

    params.padding_length = bit_band(-(params.content_length or 0),align - 1)

    for index, field in ipairs(FCGI_HEADER_FORMAT) do
        if params[field[1]] == nil then
            header[index] = binutil.ntob(field[3],field[2])
        else
            header[index] = binutil.ntob(params[field[1]],field[2])
        end
    end

    return tbl_concat(header), params.padding_length
end

function _M._unpack_bytes(self,format,str)
    -- If we received nil, return nil
    if not str then
        return nil
    end

    local res = {}
    local idx = 1

    -- Extract bytes based on format. Convert back to number and place in res rable
    for index, field in ipairs(format) do
        ngx_log(ngx_DEBUG,"Unpacking ",field[1]," with length ",field[2]," from ",idx," to ",(idx + field[2]))
        res[field[1]] = binutil.bton(str_sub(str,idx,idx + field[2] - 1))
        idx = idx + field[2]
    end

    return res
end


function _M._format_params(self,params)
    local new_params = ""
    local params = params or {}

    local keylen, valuelen
    -- Iterate over each param
    for key,value in pairs(params) do
        keylen = #key
        valuelen = #value

        -- If length of field is longer than 127, we represent 
        -- it as 4 bytes with high bit set to 1 (+2147483648 or FCGI_PARAM_HIGH_BIT)
        new_params = tbl_concat{
            new_params,
            (keylen < 127) and binutil.ntob(keylen) or binutil.ntob(keylen + FCGI_PARAM_HIGH_BIT,4),
            (valuelen < 127) and binutil.ntob(valuelen) or binutil.ntob(valuelen + FCGI_PARAM_HIGH_BIT,4),
            key,
            value,
        }
    end

    local start_params, padding = self:_pack_header{
        type            = FCGI_PARAMS,
        content_length  = #new_params
    }

    local end_params, _ = self:_pack_header{
        type            = FCGI_PARAMS,
    }

    return tbl_concat{ start_params, new_params, _pad(padding), end_params }
end


function _M._begin_request(self,fcgi_params)
    local sock = self.sock

    local header, padding = self:_pack_header{
        type            = FCGI_BEGIN_REQUEST,
        request_id      = 1,
        content_length  = FCGI_HEADER_LEN,
    }

    -- We only need to do this once so no point complicating things
    local body = tbl_concat{
        binutil.ntob(FCGI_RESPONDER,2), -- Role, 2 bytes
        binutil.ntob(self.keepalives and 1 or 0), -- Flags, 1 byte
        binutil.ntob(0,5),
    }

    local params = self:_format_params(fcgi_params)

    return tbl_concat{header, body, _pad(padding), params}
end

function _M.abort_request(self)
    local header, padding = self:_pack_header{
        type            = FCGI_ABORT_REQUEST,
    }

    local bytes, err = sock:send{ header, _pad(padding) }

    if not bytes then
        return nil, err
    end
end

function _M._format_stdin(self,stdin)
    local chunk_length

    ngx_log(ngx_DEBUG,"Stdin length is " .. #stdin)

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

        header, padding = self:_pack_header{
            type            = FCGI_STDIN,
            content_length  = chunk_length,
        }

        ngx_log(ngx_DEBUG,"Chunk length is " .. chunk_length .. " header length is " .. #header)

        stdin_chunk[1] = header
        stdin_chunk[2] = str_sub(stdin,1,chunk_length)
        stdin_chunk[3] = _pad(padding)

        to_send[#to_send+1] = tbl_concat(stdin_chunk)
        stdin = str_sub(stdin,chunk_length - padding + 1) -- str:sub is inclusive of the first character 
    until #stdin == 0

    return tbl_concat(to_send)
end


function _M.request(self,params)
    local sock = self.sock
    local fcgi_params = self:_merge_fcgi_params(params.fastcgi_params)
    local headers = params.headers
    local body = params.body or ""

    local req = {
        self:_begin_request(fcgi_params), -- Generate start of request
        self:_format_stdin(body), -- Generate body
    }


    local bytes_sent, err = sock:send(req)

    if not bytes_sent then
        return nil, err
    end

    local res = { stdout = {}, stderr = {}, status = {}}

    -- Read response
    while true do
        -- Read and unpack 8 bytes of next record header
        local header_bytes, err = sock:receive(FCGI_HEADER_LEN)
        local header = self:_unpack_bytes(FCGI_HEADER_FORMAT,header_bytes)

        if not header then
            return nil, err or "Unable to parse FCGI record header"
        end

        ngx_log(ngx_DEBUG,"Reading " .. header.content_length + header.padding_length .. " bytes")
        local data = sock:receive(header.content_length + header.padding_length)

        if not data then
            return nil, err
        end

        -- Get data minus the padding bytes
        data = str_sub(data,1,header.content_length)

        -- Assign data to correct attr or end request
        if header.type == FCGI_STDOUT then
            res.stdout[#res.stdout+1] = data
        elseif header.type == FCGI_STDERR then
            res.stderr[#res.stderr+1] = data
        elseif header.type == FCGI_END_REQUEST then
            ngx_log(ngx_DEBUG,"Reading end request")
            local stats = self:_unpack_bytes(FCGI_END_REQ_FORMAT,data)

            if not stats then
                return nil, "Unable to parse FCGI end request data"
            end

            res.status = stats
            return res
        else
            ngx_log(ngx_DEBUG,header.type)
            return nil, "Received unidentified FCGI record"
        end

    end
end


return _M