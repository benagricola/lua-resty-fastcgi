# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (11);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    init_by_lua '
        fcgi = require "resty.fastcgi"
    ';
};

our sub pack_fcgi {
    my($version,$rectype,$reqid,$content,$padding) = @_;
    my $packStr = "CCnnCxa*x[$padding]H*";
    return pack($packStr,$version,$rectype,$reqid,length $content,$padding,$content,"01030001000800000000000000504850");
}

our $standard_query_request = pack('H*','0101000100080000000101000000000001040001019305000b015343524950545f4e414d452f0f085343524950545f46494c454e414d452f666f6f2f6261720b0452454d4f54455f504f5254313131310f075345525645525f534f465457415245414243313233340e03524551554553545f4d4554484f444745540c00434f4e54454e545f545950450e00434f4e54454e545f4c454e4754480b02524551554553545f5552492f610c0051554552595f535452494e470d36444f43554d454e545f524f4f542f55736572732f6261677269636f6c612f6465762f6c75612d72657374792d666173746367692f742f73657276726f6f742f68746d6c0f085345525645525f50524f544f434f4c485454502f312e311107474154455741595f494e544552464143454347492f312e310b0952454d4f54455f414444523132372e302e302e310b095345525645525f414444523132372e302e302e310b045345525645525f504f5254313938340b095345525645525f4e414d456c6f63616c686f73740909485454505f484f53546c6f63616c686f73740f05485454505f434f4e4e454354494f4e436c6f7365000000000001040001000000000105000100000000');

my $longer_request_body = qq{
Header1: Header Value1
Header2: Header Value2
Header-3: Header Value3
Header4: x=y

Body Value1
Body Value2
Body Value3};

my $standard_request_body = qq{
Header1: Header Value1
Header2: Header Value2

Body Value1
Body Value2};

our $standard_request_packed = pack_fcgi(1,6,1,$standard_request_body,6);
our $longer_request_packed = pack_fcgi(1,6,1,$longer_request_body,0);

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Sends correct request format
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '

            local fcgic = fcgi.new()

            fcgic:set_timeout(2000)
            fcgic:connect("127.0.0.1",9999)

            fcgic:set_timeout(60000)

            local res, err = fcgic:request{
              fastcgi_params = {
                SCRIPT_FILENAME = "/foo/bar",
                SCRIPT_NAME = "/",
                QUERY_STRING = ngx.var.args,
                CONTENT_LENGTH = ngx.header.content_length,
                REMOTE_PORT = "1111",
                SERVER_SOFTWARE = "ABC1234"
              },
              headers = ngx.req.get_headers(),
              body    = "",
            }

            fcgic:close()
            
            if not res then
                ngx.say("OK")
              
            else
                ngx.status = 500
                ngx.say("ERR")
                ngx.exit(500)
            end
        ';
    }
--- request
GET /a
--- response_body
OK
--- tcp_listen: 9999
--- tcp_reply
--- tcp_query eval
$::standard_query_request

=== TEST 2: Decodes short response accurately
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '

            local fcgic = fcgi.new()

            fcgic:set_timeout(2000)
            fcgic:connect("127.0.0.1",9999)

            fcgic:set_timeout(60000)

            local res, err = fcgic:request{
              fastcgi_params = {
                SCRIPT_FILENAME = "/foo/bar",
                SCRIPT_NAME = "/",
                QUERY_STRING = ngx.var.args,
                CONTENT_LENGTH = ngx.header.content_length,
                REMOTE_PORT = "1111",
                SERVER_SOFTWARE = "ABC1234"
              },
              headers = ngx.req.get_headers(),
              body    = "",
            }

            fcgic:close()
            
            if not res then
              ngx.status = 500
              ngx.exit(500)
            end

            if res.headers["Header1"] ~= "Header Value1" or
              res.headers["Header2"] ~= "Header Value2" or
              res.body ~= "Body Value1\\nBody Value2" then
                ngx.status = 500
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
--- tcp_listen: 9999
--- tcp_reply_delay: 20ms
--- tcp_reply eval
$::standard_request_packed

=== TEST 3: Decodes longer response accurately
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '

            local fcgic = fcgi.new()

            fcgic:set_timeout(2000)
            fcgic:connect("127.0.0.1",9999)

            fcgic:set_timeout(60000)

            local res, err = fcgic:request{
              fastcgi_params = {
                SCRIPT_FILENAME = "/foo/bar",
                SCRIPT_NAME = "/",
                QUERY_STRING = ngx.var.args,
                CONTENT_LENGTH = ngx.header.content_length,
                REMOTE_PORT = "1111",
                SERVER_SOFTWARE = "ABC1234"
              },
              headers = ngx.req.get_headers(),
              body    = "",
            }

            fcgic:close()
            
            if not res then
              ngx.status = 500
              ngx.exit(500)
            end

            if res.headers["Header1"] ~= "Header Value1" or
              res.headers["Header2"] ~= "Header Value2" or
              res.headers["Header-3"] ~= "Header Value3" or 
              res.headers["Header4"] ~= "x=y" or
              res.body ~= "Body Value1\\nBody Value2\\nBody Value3" then
                ngx.status = 500
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
--- tcp_listen: 9999
--- tcp_reply_delay: 20ms
--- tcp_reply eval
$::longer_request_packed