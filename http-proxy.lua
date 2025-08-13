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
local ngx = ngx

local schema = {
    type = "object",
    properties = {
        proxy_host = {
            description = "代理服务器主机名或IP地址",
            type = "string"
        },
        proxy_port = {
            description = "代理服务器端口",
            type = "integer",
            minimum = 1,
            maximum = 65535,
        },
    },
    required = {"proxy_host", "proxy_port"},
    additionalProperties = false,
}

local plugin_name = "my-proxy"

local _M = {
    version = 0.1,
    priority = 1000,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    core.log.warn("=== my-proxy plugin started ===")
    core.log.warn("my-proxy plugin called with host: ", conf.proxy_host, " port: ", conf.proxy_port)
    
    -- 获取上游信息
    local matched_route = ctx.matched_route
    if not matched_route then
        core.log.error("no matched route found")
        return
    end
    core.log.warn("matched route found, id: ", matched_route.value.id or "unknown")

    local upstream = matched_route.value.upstream
    if not upstream then
        core.log.error("no upstream found")
        return
    end
    core.log.warn("upstream found, type: ", upstream.type or "unknown", " scheme: ", upstream.scheme or "unknown")

    -- 使用HTTP代理发起请求
    local httpc = http.new()
    httpc:set_timeout(5000)  -- 减少超时时间

    -- 设置代理选项
    local proxy_options = {
        http_proxy = "http://" .. conf.proxy_host .. ":" .. conf.proxy_port,
        https_proxy = "http://" .. conf.proxy_host .. ":" .. conf.proxy_port,
    }
    httpc:set_proxy_options(proxy_options)

    -- 获取目标服务器信息
    local nodes = upstream.nodes
    core.log.warn("nodes type: ", type(nodes))
    if type(nodes) == "table" then
        core.log.warn("nodes array length: ", #nodes)
        local node_count = 0
        for k, v in pairs(nodes) do
            node_count = node_count + 1
            core.log.warn("node key: ", k, " value type: ", type(v))
            if node_count >= 3 then break end -- 只显示前3个
        end
    else
        core.log.warn("nodes content: ", tostring(nodes))
    end
    
    local target_host, target_port
    
    if type(nodes) == "table" then
        if #nodes > 0 then
            -- 数组格式的nodes
            core.log.warn("using array format nodes")
            for i, node in ipairs(nodes) do
                if type(node) == "table" then
                    core.log.warn("checking node ", i, ": host=", node.host, " port=", node.port, " weight=", node.weight)
                    if node.host and node.port then
                        local weight = node.weight or 1
                        if weight > 0 then
                            target_host = node.host
                            target_port = node.port
                            core.log.warn("selected target: ", target_host, ":", target_port)
                            break
                        end
                    end
                else
                    core.log.warn("checking node ", i, ": ", tostring(node))
                end
            end
        else
            -- 键值对格式的nodes
            core.log.warn("using key-value format nodes")
            for host_port, weight in pairs(nodes) do
                local weight_str = type(weight) == "table" and "table" or tostring(weight)
                core.log.warn("checking host_port: ", host_port, " (type: ", type(host_port), "), weight: ", weight_str)
                if type(host_port) == "string" then
                    local actual_weight = type(weight) == "table" and weight.weight or weight
                    core.log.warn("actual_weight: ", actual_weight)
                    if actual_weight and actual_weight > 0 then
                        local host, port = host_port:match("([^:]+):?(%d*)")
                        target_host = host
                        target_port = tonumber(port) or 80
                        core.log.warn("selected target from key-value: ", target_host, ":", target_port)
                        break
                    end
                end
            end
        end
    end

    if not target_host then
        core.log.error("no valid upstream node found")
        return
    end
    
    core.log.warn("final target selected: ", target_host, ":", target_port)

    -- 构建目标URL
    local scheme = upstream.scheme or "http"
    local target_url = scheme .. "://" .. target_host .. ":" .. target_port .. ngx.var.request_uri
    core.log.warn("target_url: ", target_url)
    
    -- 获取请求方法和头部
    local method = ngx.req.get_method()
    local headers = ngx.req.get_headers()
    
    -- 读取请求体
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    
    core.log.warn("发起代理请求: ", method, " ", target_url)
    
    -- 通过代理发起请求
    local res, err = httpc:request_uri(target_url, {
        method = method,
        body = body,
        headers = headers,
        keepalive_timeout = 5000,
        keepalive_pool = 5,
        ssl_verify = false
    })
    
    -- 关闭连接以避免连接复用问题
    httpc:close()
    
    if not res then
        core.log.error("代理请求失败: ", err)
        ngx.status = 502
        ngx.say("代理请求失败: " .. (err or "unknown error"))
        ngx.exit(502)
    end
    
    core.log.warn("代理请求成功，状态码: ", res.status)
    
    -- 设置响应状态码
    ngx.status = res.status
    
    -- 设置响应头，排除可能导致问题的头部
    for k, v in pairs(res.headers) do
        local lower_k = string.lower(k)
        if lower_k ~= "connection" 
           and lower_k ~= "transfer-encoding" 
           and lower_k ~= "content-length"
           and lower_k ~= "keep-alive" then
            ngx.header[k] = v
        end
    end
    
    -- 直接输出响应体并结束
    if res.body then
        ngx.print(res.body)
    end
    ngx.eof()
    return
end

return _M