# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (8);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    init_by_lua '
        fcgi = require "resty.fastcgi"
    ';
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Pack header returns the correct byte string
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local fcgic = fcgi:new()

            local header, padding = fcgi:_pack_header{
                type            = 3,
                request_id      = 420,
                content_length  = 65525,
            }

            local bytes1 = {string.byte(header,1,#header)}
            local bytes2 = {1,3,1,164,255,245,3,0}

            for i=1, #bytes2 do
                if bytes1[i] ~= bytes2[i] then
                    ngx.status = 500
                    ngx.say("ERR")
                    ngx.exit(500)
                end
            end

            if type(header) ~= "string" or not padding == 3 
              or #header ~= 8 then
                ngx.status = 500
                ngx.say("ERR")
                ngx.exit(500)
            end

            ngx.say("OK")
        ';
    }
--- request
GET /a
--- response_body
OK
--- no_error_log
[error]
[warn]

=== TEST 2: Unpacking header returns the correct object
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local fcgic = fcgi:new()
        
            local header_bytes = string.char(1,3,1,164,255,245,3,0)
            
            local header = fcgic:_unpack_header(header_bytes)

            if type(header) ~= "table" or
              header.version ~= 1 or
              header.type ~= 3 or
              header.request_id ~= 420 or
              header.content_length ~= 65525 or
              header.padding_length ~= 3 or
              header.reserved ~= 0 then
        
                ngx.status = 500
                ngx.say("ERR")
                ngx.exit(500)
            end

            ngx.say("OK")
        ';
    }
--- request
GET /a
--- response_body
OK
--- no_error_log
[error]
[warn]