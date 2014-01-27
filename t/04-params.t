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
=== TEST 1: Packing params returns the correct byte string
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local fcgic = fcgi:new()
        
            local params, padding = fcgic:_format_params({
                PARAM_1 = "foo",
                PARAM_2 = "bar",
                LONG_NAME_LONG_NAME_LONG_NAME_LONG_NAME_LONG_NAME_LONG_NAME_LONG_NAME_LONG_NAME_LONG_NAME_LONG_NAME_LONG_NAME_LONG_NAME_LONG_NAME = "short value",
                SHORT_NAME = "long_value_long_value_long_value_long_value_long_value_long_value_long_value_long_value_long_value_long_value_long_value_long_value",
            })

            local expected_tbl = {1,4,0,1,1,59,5,0,128,0,0,129,11,76,79,78,71,95,78,65,77,69,95,76,79,78,71,95,78,65,77,69,95,76,79,78,71,95,78,65,77,69,95,76,79,78,71,95,78,65,77,69,95,76,79,78,71,95,78,65,77,69,95,76,79,78,71,95,78,65,77,69,95,76,79,78,71,95,78,65,77,69,95,76,79,78,71,95,78,65,77,69,95,76,79,78,71,95,78,65,77,69,95,76,79,78,71,95,78,65,77,69,95,76,79,78,71,95,78,65,77,69,95,76,79,78,71,95,78,65,77,69,95,76,79,78,71,95,78,65,77,69,115,104,111,114,116,32,118,97,108,117,101,7,3,80,65,82,65,77,95,50,98,97,114,10,128,0,0,131,83,72,79,82,84,95,78,65,77,69,108,111,110,103,95,118,97,108,117,101,95,108,111,110,103,95,118,97,108,117,101,95,108,111,110,103,95,118,97,108,117,101,95,108,111,110,103,95,118,97,108,117,101,95,108,111,110,103,95,118,97,108,117,101,95,108,111,110,103,95,118,97,108,117,101,95,108,111,110,103,95,118,97,108,117,101,95,108,111,110,103,95,118,97,108,117,101,95,108,111,110,103,95,118,97,108,117,101,95,108,111,110,103,95,118,97,108,117,101,95,108,111,110,103,95,118,97,108,117,101,95,108,111,110,103,95,118,97,108,117,101,7,3,80,65,82,65,77,95,49,102,111,111,0,0,0,0,0,1,4,0,1,0,0,0,0}

            local expected = {}

            for i,v in ipairs(expected_tbl) do
                expected[i] = string.char(v)
            end

            expected = table.concat(expected)

            if type(params) ~= "string" or
              params ~= expected then
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