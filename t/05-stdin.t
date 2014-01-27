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
=== TEST 1: Packing stdin returns the correct byte strings
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local fcgic = fcgi:new()

            local ngx_log = ngx.log
            local ngx_DEBUG = ngx.DEBUG
            local ngx_ERR = ngx.ERR
            
            local tests = {
                0,
                8,
                130,
                22645,
                67585,
            }
            
            for _, bytes in ipairs(tests) do
                local stdin_str = ""
                for i=1, bytes do
                    stdin_str = table.concat{stdin_str,string.char(math.random(0,255))}
                end

                local stdin = fcgic:_format_stdin(stdin_str)

                local stdout_str = ""
                repeat
                    local header_bytes = string.sub(stdin,1,8)
                    local header = fcgic:_unpack_header(header_bytes)
                    chunk_body = string.sub(stdin,9,9 + header.content_length - 1)
                    
                    stdout_str = table.concat{stdout_str,chunk_body}
                    stdin = string.sub(stdin,9 + header.content_length + header.padding_length)
                until #stdin == 0

                if stdin_str ~= stdout_str then
                    ngx.status = 500
                    ngx.say("ERR")
                    ngx.exit(500)
                end
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