# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (12);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    init_by_lua '
        fcgi = require "resty.fastcgi"
    ';
};


our sub pack_padding {
    my ($paddinglength) = @_;
    return pack("x[$paddinglength]");
}


our sub pack_fcgi_header {
    my ($version,$rectype,$reqid,$contentlength,$paddinglength) = @_;
    return pack("CCnnCx",$version,$rectype,$reqid,$contentlength,$paddinglength);
}


our sub calculate_padding_length {
    my ($contentLength) = @_;
    my $align = 8;
    return (-$contentLength) & ($align - 1);
}


our sub pack_fcgi_record {
    my($recordType,$content) = @_;
    my $contentLength = length $content;
    my $paddingLength = calculate_padding_length($contentLength);

    return pack_fcgi_header(1,$recordType,1,$contentLength,$paddingLength) . $content . pack_padding($paddingLength)
}


our sub pack_fcgi_begin_request {
    my ($role,$flags) = @_;
    my $reqBody = pack("nCx[5]",$role,$flags);
    return pack_fcgi_record(1,$reqBody);
}


our sub pack_fcgi_params {
    my(%params) = @_;
    my $paramStr = "";
  
    while(my ($key, $value) = each %params ) {
        my $keylen = length $key;
        my $valuelen = length $value;
        if($keylen <= 127) {
            if($valuelen <= 127) {
                $paramStr .= pack("CCA[$keylen]A[$valuelen]",$keylen,$valuelen,$key,$value);
            } else {
                $paramStr .= pack("CNA[$keylen]A[$valuelen]",$keylen,$valuelen + 2147483648,$key,$value);
            }
           } else {
            if($valuelen <= 127) {
                $paramStr .= pack("NCA[$keylen]A[$valuelen]",$keylen + 2147483648,$valuelen,$key,$value);
            } else {
                $paramStr .= pack("NNA[$keylen]A[$valuelen]",$keylen + 2147483648,$valuelen + 2147483648,$key,$value);
            }
        }
    }
    return pack_fcgi_record(4,$paramStr) . pack_fcgi_record(4,"")
}


our sub pack_fcgi_stdin {
    my ($content) = @_;
    my $n = 32768;
    my @records = unpack("a$n" x ((length($content)/$n)) . "a*", $content);

    my $out = "";
    foreach my $item (@records) {
        $out .= pack_fcgi_record(5,$item);
    }
    return $out . pack_fcgi_record(5,"");
}


our sub pack_fcgi_stdout {
    my ($content) = @_;
    my $n = 32768;
    my @records = unpack("a$n" x ((length($content)/$n)) . "a*", $content);

    my $out = "";
    foreach my $item (@records) {
        $out .= pack_fcgi_record(6,$item);
    }
    return $out . pack_fcgi_record(6,"");
}


our sub pack_fcgi_stderr {
    my ($content) = @_;
    my $n = 32768;
    my @records = unpack("a$n" x ((length($content)/$n)) . "a*", $content);

    my $out = "";
    foreach my $item (@records) {
        $out .= pack_fcgi_record(7,$item);
    }
    return $out . pack_fcgi_record(7,"");
}


our sub pack_fcgi_end_request {
    my ($appStatus,$protoStatus) = @_;
    my $reqBody = pack("NCx[3]",$appStatus,$protoStatus);
    return pack_fcgi_record(3,$reqBody);
}

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Validate short request / response
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '

            local fcgic = fcgi.new()

            fcgic:set_timeout(2000)
            fcgic:connect("127.0.0.1",31498)

            fcgic:set_timeout(60000)

            local res, err = fcgic:request({
              params = {
                PARAM_1 = "val1",
                PARAM_2 = "val2",
              },
              stdin    = "TEST 1",
            })

            if res then -- We sent the request successfully
                local reader = fcgic:get_response_reader()
                local stdout, stderr = "",""

                repeat
                    chunk, err = reader()
    
                    if chunk then 
                        if chunk.stdout then

                            stdout = stdout .. chunk.stdout
                        end
                        if chunk.stderr then
                            stderr = stderr .. chunk.stderr
                        end
                    elseif err then
                        ngx.status = 501
                        ngx.say("ERR")
                        ngx.exit(501)
                    end
                until not chunk

                fcgic:close()

                if stdout ~= "TEST STDOUT 1" or #stderr > 0 then
                    ngx.status = 501
                    ngx.say("ERR")
                    ngx.exit(501)
                else
                    ngx.say("OK")
                    ngx.status = 200
                end
            else
                ngx.status = 502
                ngx.say("ERR")
                ngx.exit(502)
            end


        ';
    }
--- request
GET /a
--- response_body
OK
--- tcp_listen: 31498
--- tcp_reply_delay: 100ms
--- tcp_query_len: 88
--- tcp_reply eval
return ::pack_fcgi_stdout("TEST STDOUT 1") . ::pack_fcgi_end_request(0,0)
--- tcp_query eval
my(%params) = ('PARAM_1' => 'val1','PARAM_2' => 'val2');
return ::pack_fcgi_begin_request(1,1) . ::pack_fcgi_params(%params) . ::pack_fcgi_stdin("TEST 1")


=== TEST 2: Validate long request headers
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '

            local fcgic = fcgi.new()

            fcgic:set_timeout(2000)
            fcgic:connect("127.0.0.1",31498)

            fcgic:set_timeout(60000)

            local res, err = fcgic:request({
              params = {
                FOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBAR = "val1",
                val1 = "FOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBAR",

              },
              stdin    = "TEST 2",
            })

            if res then -- We sent the request successfully
                local reader = fcgic:get_response_reader()
                local stdout, stderr = "",""

                repeat
                    chunk, err = reader()
    
                    if chunk then 
                        if chunk.stdout then

                            stdout = stdout .. chunk.stdout
                        end
                        if chunk.stderr then
                            stderr = stderr .. chunk.stderr
                        end
                    elseif err then
                        ngx.status = 501
                        ngx.say("ERR")
                        ngx.exit(501)
                    end
                until not chunk

                fcgic:close()

                if stdout ~= "TEST STDOUT 2" or #stderr > 0 then
                    ngx.status = 501
                    ngx.say("ERR")
                    ngx.exit(501)
                else
                    ngx.status = 200
                    ngx.say("OK")
                end
            else
                ngx.status = 502
                ngx.say("ERR")
                ngx.exit(502)
            end


        ';
    }
--- request
GET /a
--- response_body
OK
--- tcp_listen: 31498
--- tcp_reply_delay: 100ms
--- tcp_query_len: 344
--- tcp_reply eval
return ::pack_fcgi_stdout("TEST STDOUT 2") . ::pack_fcgi_end_request(0,0)
--- tcp_query eval
my(%params) = (
    'FOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBAR' => 'val1',
    'val1' => 'FOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBARFOOBAR',
);
return ::pack_fcgi_begin_request(1,1) . ::pack_fcgi_params(%params) . ::pack_fcgi_stdin("TEST 2")


=== TEST 3: Validate long request / response body
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '

            local fcgic = fcgi.new()

            fcgic:set_timeout(2000)
            fcgic:connect("127.0.0.1",31498)

            fcgic:set_timeout(60000)

            local bodycontent = string.rep("FOOBARRABOOF",6000)
            local res, err = fcgic:request({
              params = {
                PARAM_1 = "val1",
                PARAM_2 = "val2",
              },
              stdin    = bodycontent,
            })

            if res then -- We sent the request successfully
                local reader = fcgic:get_response_reader()
                local stdout, stderr = "",""

                repeat
                    chunk, err = reader()
    
                    if chunk then 
                        if chunk.stdout then

                            stdout = stdout .. chunk.stdout
                        end
                        if chunk.stderr then
                            stderr = stderr .. chunk.stderr
                        end
                    elseif err then
                        ngx.status = 501
                        ngx.say("ERR")
                        ngx.exit(501)
                    end
                until not chunk

                fcgic:close()

                if stdout ~= bodycontent or #stderr > 0 then
                    ngx.status = 501
                    ngx.say("ERR")
                    ngx.exit(501)
                else
                    ngx.status = 200
                    ngx.say("OK")
                end
            else
                ngx.status = 502
                ngx.say("ERR")
                ngx.exit(502)
            end


        ';
    }
--- request
GET /a
--- response_body
OK
--- tcp_listen: 31498
--- tcp_reply_delay: 500ms
--- tcp_query_len: 72096
--- tcp_reply eval
return ::pack_fcgi_stdout("FOOBARRABOOF" x 6000) . ::pack_fcgi_end_request(0,0)
--- tcp_query eval
my(%params) = ('PARAM_1' => 'val1','PARAM_2' => 'val2');
return ::pack_fcgi_begin_request(1,1) . ::pack_fcgi_params(%params) . ::pack_fcgi_stdin("FOOBARRABOOF" x 6000)
