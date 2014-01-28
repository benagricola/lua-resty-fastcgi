#lua-resty-fcgi

Lua FastCGI client driver for ngx_lua based on the cosocket API.

#Table of Contents

* [Status](#status)
* [Overview](#overview)
* [fcgi.request](#fastcgi.request)
    * [new](#new)
    * [connect](#connect)
    * [request](#request)

#Status

Experimental, API may change without warning.

Requires ngx_lua > 0.9.5

#Overview

Require the resty.fastcgi module in init_by_lua.

Create an instance of the `fastcgi` class in your content_by_lua.

Call the `connect` method with a socket path or hostname:port combination to connect.

Use the `request` method to make a basic FastCGI request which returns a result object, or nil, err.

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

            local res, err = fcgic:request({
            fastcgi_params = {
                SCRIPT_FILENAME = ngx.var.document_root .. "/index.php",
                SCRIPT_NAME = "/",
                QUERY_STRING = ngx.var.args,
                CONTENT_LENGTH = ngx.header.content_length,
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

### request
`syntax: res, err = fcgi_client:request({params...})`

Makes a FCGI request to the connected socket using the details given in params.

e.g.
```lua
local params = {
  fastcgi_params = {
    SCRIPT_FILENAME = ngx.var.document_root .. "/index.php",
    SCRIPT_NAME = "/",
    QUERY_STRING = ngx.var.args,
    CONTENT_LENGTH = ngx.header.content_length,
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

local res_headers = res.headers
local res_body = res.body
```

## TODO
 * Streaming API to work in conjunction with lua-resty-http
 * Better tests

