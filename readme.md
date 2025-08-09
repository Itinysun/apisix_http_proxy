# APISIX HTTP Proxy 插件

## 概述

`http-proxy` 插件为 Apache APISIX 提供了 HTTP 代理功能，允许上游服务通过 HTTP 代理服务器进行连接。该插件支持全局配置，通过配置参数指定代理服务器信息。

## 功能特性

- **全局作用域**: 插件作用于全局
- **配置简洁**: 通过配置参数指定代理服务器
- **认证支持**: 支持代理服务器的用户名密码认证
- **连接复用**: 使用 CONNECT 方法建立隧道，支持 HTTP/HTTPS 流量

## 配置参数

| 参数名                | 类型    | 必填 | 默认值 | 描述                       |
| --------------------- | ------- | ---- | ------ | -------------------------- |
| `proxy_host`          | string  | 是   | -      | 代理服务器主机名或 IP 地址 |
| `proxy_port`          | integer | 是   | -      | 代理服务器端口 (1-65535)   |
| `proxy_auth`          | object  | 否   | -      | 代理服务器认证信息         |
| `proxy_auth.username` | string  | 否   | -      | 代理认证用户名             |
| `proxy_auth.password` | string  | 否   | -      | 代理认证密码               |

## 使用方法

### 1. 基本代理配置

在插件配置中指定代理服务器信息：

```bash
curl -X PUT http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -d '{
    "plugins": {
      "http-proxy": {
        "proxy_host": "proxy.example.com",
        "proxy_port": 8080
      }
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "httpbin.org:80": 1
      }
    },
    "uri": "/anything"
  }'
```

### 2. 带认证的代理配置

```bash
curl -X PUT http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -d '{
    "plugins": {
      "http-proxy": {
        "proxy_host": "proxy.example.com",
        "proxy_port": 8080,
        "proxy_auth": {
          "username": "proxy_user",
          "password": "proxy_pass"
        }
      }
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "httpbin.org:80": 1
      }
    },
    "uri": "/anything"
  }'
```

### 3. 全局插件配置

也可以将插件配置为全局插件：

```bash
curl -X PUT http://127.0.0.1:9180/apisix/admin/global_rules/1 \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -d '{
    "plugins": {
      "http-proxy": {
        "proxy_host": "proxy.example.com",
        "proxy_port": 8080
      }
    }
  }'
```

## 工作原理

1. **代理配置读取**: 从插件配置中读取 `proxy_host` 和 `proxy_port` 参数
2. **建立代理连接**: 使用 HTTP CONNECT 方法向代理服务器发起隧道建立请求
3. **隧道建立**: 代理服务器返回 200 状态码表示隧道建立成功
4. **流量转发**: 后续的所有 HTTP/HTTPS 流量都通过建立的隧道进行转发

## 错误处理

插件包含完善的错误处理机制：

- **连接失败**: 如果无法连接到代理服务器，会记录错误日志并跳过代理
- **CONNECT 请求失败**: 如果 CONNECT 请求返回非 200 状态码，会记录错误日志

## 注意事项

1. **安全性**: 代理认证密码会以明文形式存储在配置中，请确保 APISIX 管理接口的安全性
2. **性能**: 使用代理会增加网络延迟，请根据实际需要启用
3. **兼容性**: 插件支持 HTTP 和 HTTPS 上游服务

## 故障排查

### 常见问题

1. **插件未生效**

   - 检查插件是否正确挂载到 APISIX 容器中
   - 检查路由配置中是否包含插件配置

2. **代理连接失败**

   - 检查代理服务器地址和端口是否正确
   - 检查网络连通性
   - 检查代理服务器是否支持 CONNECT 方法

3. **认证失败**
   - 检查代理认证用户名和密码是否正确
   - 检查代理服务器是否要求认证

### 日志查看

插件会输出详细的日志信息，可通过以下命令查看：

```bash
docker logs apisix-container-name
```

## 配置示例

建议阅读官方文档[Where to put your plugins](https://apisix.apache.org/docs/apisix/plugin-develop/#where-to-put-your-plugins)

### Docker Compose 配置

```yaml
version: "3"
services:
  apisix:
    image: apache/apisix:3.13.0-debian
    volumes:
      - ./apisix_plugins:/usr/local/apisix/plugins:ro
      - ./apisix_conf/config.yaml:/usr/local/apisix/conf/config.yaml:ro
```

### APISIX 配置文件

```yaml
apisix:
  extra_lua_path: "/usr/local/?.lua"
plugins:
  - http-proxy
```

## 版本信息

- **版本**: 0.1
- **优先级**: 1000
- **兼容性**: Apache APISIX 3.x

## 许可证

本插件采用 Apache License 2.0 许可证。
