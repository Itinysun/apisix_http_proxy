--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

local core = require("apisix.core")
local http = require("resty.http")
local tonumber = tonumber
local os = os

local plugin_name = "http-proxy"

local schema = {
    type = "object",
    properties = {
        proxy_host = {
            type = "string",
            description = "代理服务器主机名或IP地址"
        },
        proxy_port = {
            type = "integer",
            minimum = 1,
            maximum = 65535,
            description = "代理服务器端口"
        },
        proxy_auth = {
            type = "object",
            properties = {
                username = {
                    type = "string",
                    description = "代理认证用户名"
                },
                password = {
                    type = "string",
                    description = "代理认证密码"
                }
            },
            additionalProperties = false,
            description = "代理服务器认证信息（可选）"
        }
    },
    required = {"proxy_host", "proxy_port"},
    additionalProperties = false,
    description = "HTTP代理插件配置，必须提供proxy_host和proxy_port"
}

local _M = {
    version = 0.1,
    priority = 1000,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function setup_proxy_headers(proxy_conf)
    local headers = {}

    if proxy_conf.proxy_auth and proxy_conf.proxy_auth.username and proxy_conf.proxy_auth.password then
        local auth = ngx.encode_base64(proxy_conf.proxy_auth.username .. ":" .. proxy_conf.proxy_auth.password)
        headers["Proxy-Authorization"] = "Basic " .. auth
    end

    headers["Proxy-Connection"] = "Keep-Alive"

    return headers
end

function _M.access(conf, ctx)
    core.log.info("HTTP代理插件被调用: host=", conf.proxy_host, ", port=", conf.proxy_port)
    
    local proxy_conf = {
        host = conf.proxy_host,
        port = conf.proxy_port,
        proxy_auth = conf.proxy_auth
    }

    local upstream_node = ctx.picked_server
    if not upstream_node then
        core.log.error("无法获取上游服务节点信息")
        return
    end

    local upstream_host = upstream_node.host
    local upstream_port = upstream_node.port or 80

    local httpc = http.new()
    httpc:set_timeout(30000)

    local ok, err = httpc:connect(proxy_conf.host, proxy_conf.port)
    if not ok then
        core.log.error("连接HTTP代理失败: ", err)
        return
    end

    local proxy_headers = setup_proxy_headers(proxy_conf)

    local connect_req = "CONNECT " .. upstream_host .. ":" .. upstream_port .. " HTTP/1.1\r\n"
    connect_req = connect_req .. "Host: " .. upstream_host .. ":" .. upstream_port .. "\r\n"

    for k, v in pairs(proxy_headers) do
        connect_req = connect_req .. k .. ": " .. v .. "\r\n"
    end

    connect_req = connect_req .. "\r\n"

    local bytes, send_err = httpc:send(connect_req)
    if not bytes then
        core.log.error("发送CONNECT请求失败: ", send_err)
        httpc:close()
        return
    end

    local line, recv_err = httpc:receive("*l")
    if not line then
        core.log.error("读取CONNECT响应失败: ", recv_err)
        httpc:close()
        return
    end

    local status_code = line:match("HTTP/%d%.%d (%d+)")
    if not status_code or tonumber(status_code) ~= 200 then
        core.log.error("HTTP代理CONNECT请求失败: ", line)
        httpc:close()
        return
    end

    repeat
        line, recv_err = httpc:receive("*l")
    until not line or line == ""

    if recv_err and recv_err ~= "timeout" then
        core.log.error("读取CONNECT响应头失败: ", recv_err)
        httpc:close()
        return
    end

    local sock = httpc.sock
    if not sock then
        core.log.error("无法获取HTTP代理socket")
        httpc:close()
        return
    end

    ctx.proxy_sock = sock
    ctx.proxy_httpc = httpc

    core.log.info("HTTP代理隧道建立成功: ", proxy_conf.host, ":", proxy_conf.port, " -> ", upstream_host, ":", upstream_port)
end

function _M.balancer(_, ctx)
    if not ctx.proxy_sock then
        return
    end

    local balancer = require "ngx.balancer"
    local sock = ctx.proxy_sock
    
    local ok, err = balancer.set_current_peer("unix:" .. sock:getfd())
    if not ok then
        core.log.error("设置代理socket失败: ", err)
        return
    end
    
    balancer.set_more_tries(0)
end

function _M.log(_, ctx)
    if ctx.proxy_httpc then
        ctx.proxy_httpc:close()
    end
end

return _M