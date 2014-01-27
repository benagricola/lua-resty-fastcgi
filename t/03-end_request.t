# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (4);

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
=== TEST 1: Unpacking end request returns the correct object
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local fcgic = fcgi:new()
        
            local endreq_bytes = string.char(0,0,1,229,9,0,0,0)
            
            local endreq = fcgic:_unpack_end_request(endreq_bytes)

            if type(endreq) ~= "table" or
              endreq.status ~= 485 or
              endreq.protocolStatus ~= 9 or
              endreq.reserved ~= 0 then
        
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