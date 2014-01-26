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
        binutil = require "resty.binutil"
    ';
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: binutil.ntob correctly encodes 1, 2 and 4 byte numbers.
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local test = {
                {binutil.ntob(41,1),string.char(41)},
                {binutil.ntob(41,2),string.char(0,41)},
                {binutil.ntob(41,4),string.char(0,0,0,41)},
                {binutil.ntob(125,1),string.char(125)},
                {binutil.ntob(65410,2),string.char(255,130)},
                {binutil.ntob(2342349,4),string.char(0,35,189,205)},
                {binutil.ntob(549583953,4),string.char(32,193,252,81)}
            }
            
            for _, pair in ipairs(test) do
                if pair[1] ~= pair[2] then
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

=== TEST 2: binutil.bton correctly decodes 1, 2 and 4 byte numbers.
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local test = {
                {binutil.bton(string.char(41)),41},
                {binutil.bton(string.char(0,41)),41},
                {binutil.bton(string.char(0,0,0,41)),41},
                {binutil.bton(string.char(125)),125},
                {binutil.bton(string.char(255,130)),65410},
                {binutil.bton(string.char(0,35,189,205)),2342349},
                {binutil.bton(string.char(32,193,252,81)),549583953},
            }
            
            for _, pair in ipairs(test) do
                if pair[1] ~= pair[2] then
                    -- ngx.status = 500
                    ngx.say(pair[1])
                    -- ngx.exit(500)
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