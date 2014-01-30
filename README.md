#lua-resty-fcgi

Lua FastCGI client driver for ngx_lua based on the cosocket API.

#Table of Contents

* [Status](#status)
* [Overview](#overview)
* [fastcgi](#fastcgi)
    * [new](#new)
    * [connect](#connect)
    * [request_simple](#request_simple)
    * [request](#request)

#Status

Experimental, API may change without warning.

Requires ngx_lua > 0.9.5

#Overview

Require the resty.fastcgi module in init_by_lua.

Create an instance of the `fastcgi` class in your content_by_lua.

Call the `connect` method with a socket path or hostname:port combination to connect.

Use the `request_simple` method to make a basic FastCGI request which returns a result object containing http body and headers, or nil, err.

```lua
init_by_lua '
  fcgi = require("resty.fastcgi")
';

server {
    root /var/www;

    location / {

        content_by_lua '
            local fcgic = fcgi.new()

            fcgic:set_timeout(2000)
            fcgic:connect("127.0.0.1",9000)

            ngx.req.read_body()

            fcgic:set_timeout(60000)

            local res, err = fcgic:request_simple({
                fastcgi_params = {
                    DOCUMENT_ROOT     = ngx.var.document_root,
                    SCRIPT_FILENAME   = ngx.var.document_root .. "/index.php",
                    SCRIPT_NAME       = "/",
                    REQUEST_METHOD    = ngx.var.request_method,
                    CONTENT_TYPE      = ngx.var.content_type,
                    CONTENT_LENGTH    = ngx.var.content_length,
                    REQUEST_URI       = ngx.var.request_uri,
                    QUERY_STRING      = ngx.var.args,
                    SERVER_PROTOCOL   = ngx.var.server_protocol,
                    GATEWAY_INTERFACE = "CGI/1.1",
                    SERVER_SOFTWARE   = "lua-resty-fastcgi",
                    REMOTE_ADDR       = ngx.var.remote_addr,
                    REMOTE_PORT       = ngx.var.remote_port,
                    SERVER_ADDR       = ngx.var.server_addr,
                    SERVER_PORT       = ngx.var.server_port,
                    SERVER_NAME       = ngx.var.server_name
                },
                headers = ngx.req.get_headers(),
                body    = ngx.req.get_body_data(),
            })

            if not res then
                ngx.status = 500
                ngx.log(ngx.ERR,"Error making FCGI request: ",err)
                ngx.exit(500)
            else
                for k,v in pairs(res.headers) do
                  ngx.header[k] = v
                end
                ngx.status = res.status
                ngx.say(res.body)
            end

            fcgic:close()
        ';
    }
}

```

# fastcgi

### new
`syntax: fcgi_client = fcgi.new()`

Returns a new fastcgi object.

### connect
`syntax: ok, err = fcgi_client:connect(host or sockpath[,port])`

Attempts to connect to the FastCGI server details given.


```lua
fcgi_class = require('resty.fastcgi')
local fcgi_client = fcgi_class.new()

local ok, err = fcgi_client:connect("127.0.0.1",9000)

if not ok then
    ngx.log(ngx.ERR, err)
    ngx.status = 500
    return ngx.exit(ngx.status)
end

ngx.log(ngx.info, 'Connected to ' .. err.host.host .. ':' .. err.host.port)
```

### request_simple
`syntax: res, err = fcgi_client:request_simple({params...})`

Makes a FCGI request to the connected socket using the details given in params.

Returns a result object containing HTTP body and headers. Internally this uses the streaming API.

e.g.
```lua
local params = {
    fastcgi_params = {
        DOCUMENT_ROOT     = ngx.var.document_root,
        SCRIPT_FILENAME   = ngx.var.document_root .. "/index.php",
        SCRIPT_NAME       = "/",
        REQUEST_METHOD    = ngx.var.request_method,
        CONTENT_TYPE      = ngx.var.content_type,
        CONTENT_LENGTH    = ngx.var.content_length,
        REQUEST_URI       = ngx.var.request_uri,
        QUERY_STRING      = ngx.var.args,
        SERVER_PROTOCOL   = ngx.var.server_protocol,
        GATEWAY_INTERFACE = "CGI/1.1",
        SERVER_SOFTWARE   = "lua-resty-fastcgi",
        REMOTE_ADDR       = ngx.var.remote_addr,
        REMOTE_PORT       = ngx.var.remote_port,
        SERVER_ADDR       = ngx.var.server_addr,
        SERVER_PORT       = ngx.var.server_port,
        SERVER_NAME       = ngx.var.server_name
    },
    headers = ngx.req.get_headers(),
    body    = ngx.req.get_body_data(),
}

res, err = fcgi_client:request_simple(params)

if not res then
    ngx.log(ngx.ERR, err)
    ngx.status = 500
    return ngx.exit(ngx.status)
end

local res_headers = res.headers
local res_body = res.body
```

### request
`syntax: res, err = fcgi_client:request({params...})`

Makes a FCGI request to the connected socket using the details given in params.

Returns number of bytes written to socket or nil, err. This method is intended to be used with the response streaming functions.

e.g.
```lua
local params = {
    fastcgi_params = {
        DOCUMENT_ROOT     = ngx.var.document_root,
        SCRIPT_FILENAME   = ngx.var.document_root .. "/index.php",
        SCRIPT_NAME       = "/",
        REQUEST_METHOD    = ngx.var.request_method,
        CONTENT_TYPE      = ngx.var.content_type,
        CONTENT_LENGTH    = ngx.var.content_length,
        REQUEST_URI       = ngx.var.request_uri,
        QUERY_STRING      = ngx.var.args,
        SERVER_PROTOCOL   = ngx.var.server_protocol,
        GATEWAY_INTERFACE = "CGI/1.1",
        SERVER_SOFTWARE   = "lua-resty-fastcgi",
        REMOTE_ADDR       = ngx.var.remote_addr,
        REMOTE_PORT       = ngx.var.remote_port,
        SERVER_ADDR       = ngx.var.server_addr,
        SERVER_PORT       = ngx.var.server_port,
        SERVER_NAME       = ngx.var.server_name
    },
    headers = ngx.req.get_headers(),
    body    = ngx.req.get_body_data(),
}

res, err = fcgi_client:request(params)

if not res then
    ngx.log(ngx.ERR, err)
    ngx.status = 500
    return ngx.exit(ngx.status)
end

local body_reader = fcgic:get_response_reader()
local chunk, err
repeat
    chunk, err = body_reader(32768)

    if err then
        return nil, err, tbl_concat(chunks)
    end

    if chunk then
        -- Parse stdout here for e.g. HTTP headers
        ngx.print(chunk.stdout)
    end
until not chunk

```

## TODO
 * Streaming request support
 * Better testing, including testing streaming functionality

