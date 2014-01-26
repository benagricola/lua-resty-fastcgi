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
local ffi_new = ffi.new
local ffi_abi = ffi.abi
local ffi_string = ffi.string
local ffi_sizeof = ffi.sizeof
local ffi_metatype = ffi.metatype
local pairs = pairs
local bit_band = bit.band
local bit_rshift = bit.rshift
local bit_lshift = bit.lshift
local bit_bor = bit.bor

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
local FCGI_PARAM_HIGH_BIT     = 2147483648
local FCGI_BODY_MAX_LENGTH    = 32768
local FCGI_KEEP_CONN          = 0x01
local FCGI_NO_KEEP_CONN       = 0x00
local FCGI_RESPONDER          = 0x01

ffi.cdef[[
    typedef struct {
        unsigned char version;
        unsigned char type;
        unsigned char requestId1;
        unsigned char requestId0;
        unsigned char contentLength1;
        unsigned char contentLength0;
        unsigned char paddingLength;
        unsigned char reserved;
    } FCGI_Header;

    typedef struct {
        unsigned char role1;
        unsigned char role0;
        unsigned char flags;
        unsigned char reserved[5];
    } FCGI_BeginRequestBody;

    typedef struct {
        unsigned char appStatus3;
        unsigned char appStatus2;
        unsigned char appStatus1;
        unsigned char appStatus0;
        unsigned char protocolStatus;
        unsigned char reserved[3];
    } FCGI_EndRequestBody;

    typedef struct {
        FCGI_Header header;
        FCGI_EndRequestBody body;
    } FCGI_EndRequestRecord;


    typedef struct {
        unsigned char nameLength;
        unsigned char valueLength;
    } FCGI_NameValueHeader11;

    typedef struct {
        unsigned char nameLength;
        unsigned char valueLength3;
        unsigned char valueLength2;
        unsigned char valueLength1;
        unsigned char valueLength0;
    } FCGI_NameValueHeader14;

    typedef struct {
        unsigned char nameLength3;
        unsigned char nameLength2;
        unsigned char nameLength1;
        unsigned char nameLength0;
        unsigned char valueLength;
    } FCGI_NameValueHeader41;

    typedef struct {
        unsigned char nameLength3;
        unsigned char nameLength2;
        unsigned char nameLength1;
        unsigned char nameLength0;
        unsigned char valueLength3;
        unsigned char valueLength2;
        unsigned char valueLength1;
        unsigned char valueLength0;
    } FCGI_NameValueHeader44;
]]

local extract_bytes = function (obj,key,len)
    local field
    local val = 0
    for i=0, len-1 do
        field = tbl_concat{key,i}
        val = val + bit_lshift(obj[field],i * 8)
    end
    return val
end

local push_bytes = function(obj,key,value,len)
    local field
    for i=0, len-1 do
        field = tbl_concat{key,i}
        obj[field] = bit_band(bit_rshift(value,i*8),0xff)
    end
end

local fcgi_mt = {
    __index = function(self,key)
        if key == "requestId" or key == "contentLength" or key == "role" then
            return extract_bytes(self,key,2)
        elseif key == "appStatus" then
            return extract_bytes(self,key,4)
        end
    end,
    __newindex = function(self,key,value)
        if key == "requestId" or key == "contentLength" or key == "role" then
            return push_bytes(self,key,value,2)
        elseif key == "appStatus" then
            return push_bytes(self,key,value,4)
        end
    end
}

local fcgi_nvh11_mt = {
    __index = function(self,key)
        return extract_bytes(self,key,1)
    end,
    __newindex = function(self,key,value)
        return push_bytes(self,key,value,1)
    end
}

local fcgi_nvh14_mt = {
    __index = function(self,key)
        return (key == "valueLength") and extract_bytes(self,key,4) or extract_bytes(self,key,1)
    end,
    __newindex = function(self,key,value)
        return (key == "valueLength") and push_bytes(self,key,value + FCGI_PARAM_HIGH_BIT,4) or push_bytes(self,key,value,1)
    end
}

local fcgi_nvh41_mt = {
    __index = function(self,key)
        return (key == "nameLength") and extract_bytes(self,key,4) or extract_bytes(self,key,1)
    end,
    __newindex = function(self,key,value)
        return (key == "nameLength") and push_bytes(self,key,value + FCGI_PARAM_HIGH_BIT,4) or push_bytes(self,key,value,1)
    end
}

local fcgi_nvh44_mt = {
    __index = function(self,key)
        return extract_bytes(self,key,4)
    end,
    __newindex = function(self,key,value)
        return push_bytes(self,key,value + FCGI_PARAM_HIGH_BIT,4)
    end
}

local FCGI_Header = ffi.typeof('FCGI_Header')
local FCGI_BeginRequestBody = ffi.typeof('FCGI_BeginRequestBody')
local FCGI_EndRequestBody = ffi.typeof('FCGI_EndRequestBody')

ffi_metatype(FCGI_Header,fcgi_mt)
ffi_metatype(FCGI_BeginRequestBody,fcgi_mt)
ffi_metatype(FCGI_EndRequestBody,fcgi_mt)

local FCGI_NameValueHeader11 = ffi.typeof('FCGI_NameValueHeader11')
local FCGI_NameValueHeader14 = ffi.typeof('FCGI_NameValueHeader14')
local FCGI_NameValueHeader41 = ffi.typeof('FCGI_NameValueHeader41')
local FCGI_NameValueHeader44 = ffi.typeof('FCGI_NameValueHeader44')

ffi_metatype(FCGI_NameValueHeader11,fcgi_nvh11_mt)
ffi_metatype(FCGI_NameValueHeader14,fcgi_nvh14_mt)
ffi_metatype(FCGI_NameValueHeader41,fcgi_nvh41_mt)
ffi_metatype(FCGI_NameValueHeader44,fcgi_nvh44_mt)


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
        },
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
    local align             = 8
    local content_length    = params.content_length or 0
    local padding           = bit_band(-(content_length or 0),align - 1)

    local header            = FCGI_Header()
    header.version          = FCGI_VERSION_1
    header.type             = params.type
    header.requestId        = 1
    header.contentLength    = content_length
    header.paddingLength    = padding

    return ffi_string(header, ffi_sizeof(header)), padding
end


function _M._unpack_bytes(self,format,str)
    -- If we received nil, return nil
    if not str then
        return nil
    end

    local struct = format()
    ffi.copy(struct,str,#str)
    return struct
end


function _M._format_params(self,params)
    local new_params = ""
    local params = params or {}

    local keylen, valuelen
    -- Iterate over each param
    for key,value in pairs(params) do
        keylen = #key
        valuelen = #value

        local paramheader

        if keylen < 127 then
            if valuelen < 127 then
                paramheader = FCGI_NameValueHeader11()
            else
                paramheader = FCGI_NameValueHeader14()
            end
        else
            if valuelen < 127 then
                paramheader = FCGI_NameValueHeader41()
            else
                paramheader = FCGI_NameValueHeader44()
            end
        end

        paramheader.nameLength = keylen
        paramheader.valueLength = valuelen

        -- If length of field is longer than 127, we represent 
        -- it as 4 bytes with high bit set to 1 (+2147483648 or FCGI_PARAM_HIGH_BIT)
        new_params = tbl_concat{
            new_params,
            ffi_string(paramheader,ffi_sizeof(paramheader)),
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
        content_length  = FCGI_HEADER_LEN,
    }

    -- Build up the BeginRequestBody
    local body  = FCGI_BeginRequestBody()
    body.role   = FCGI_RESPONDER
    body.flags  = self.keepalives and FCGI_KEEP_CONN or FCGI_NO_KEEP_CONN

    -- Format fcgi parameter records
    local params = self:_format_params(fcgi_params)

    -- Return formatted request packet
    return tbl_concat{header, ffi_string(body, ffi_sizeof(body)), _pad(padding), params}
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
    local stdin_len = #stdin
    local chunks = 1
    repeat
        -- While we still have stdin data, build up STDIN record
        chunk_length = (stdin_len > FCGI_BODY_MAX_LENGTH) and FCGI_BODY_MAX_LENGTH or stdin_len

        header, padding = self:_pack_header{
            type            = FCGI_STDIN,
            content_length  = chunk_length,
        }

        stdin_chunk[1] = header
        stdin_chunk[2] = str_sub(stdin,1,chunk_length)
        stdin_chunk[3] = _pad(padding)

        to_send[chunks] = tbl_concat(stdin_chunk)
        stdin = str_sub(stdin,chunk_length - padding + 1) -- str:sub is inclusive of the first character 
        stdin_len = #stdin
        chunks = chunks + 1
    until stdin_len == 0

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
        local header = self:_unpack_bytes(FCGI_Header,header_bytes)

        if not header then
            return nil, err or "Unable to parse FCGI record header"
        end

        ngx_log(ngx_DEBUG,"Reading " .. header.contentLength + header.paddingLength .. " bytes")
        local data = sock:receive(header.contentLength + header.paddingLength)

        if not data then
            return nil, err
        end

        -- Get data minus the padding bytes
        data = str_sub(data,1,header.content_length)

        -- If stdout packet, assign data to stdout
        if header.type == FCGI_STDOUT then
            res.stdout[#res.stdout+1] = data

        -- Otherwise if stderr packet, assign data to stderr
        elseif header.type == FCGI_STDERR then
            res.stderr[#res.stderr+1] = data

        -- Otherwise if this is the end of the request, return saved data
        elseif header.type == FCGI_END_REQUEST then
            ngx_log(ngx_DEBUG,"Reading end request")
            local stats = self:_unpack_bytes(FCGI_EndRequestBody,data)

            if not stats then
                return nil, "Unable to parse FCGI end request data"
            end

            res.status = stats
            return res

        -- Otherwise this is an unidentified record. Throw error.
        else
            ngx_log(ngx_DEBUG,header.type)
            return nil, "Received unidentified FCGI record"
        end
    end
end

return _M