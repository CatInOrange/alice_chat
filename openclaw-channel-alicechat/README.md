# AliceChat Channel Plugin for OpenClaw

AliceChat 的 Python 后端通过这个插件接入 OpenClaw Gateway，实现 AI 聊天功能。

## 工作原理

```
AliceChat Python Backend
        ↓ WebSocket (ws://127.0.0.1:18791)
AliceChat Channel Plugin (本插件)
        ↓ 内部调用
OpenClaw AI 处理
        ↓ 逐帧返回
AliceChat Python Backend
```

## 协议帧

### 后端 → 插件

| 帧类型 | 说明 |
|--------|------|
| `bridge.register` | 注册推送监听，接收 AI 回复 |
| `chat.request` | 发送聊天请求 |
| `ping` | 心跳保活 |

### 插件 → 后端

| 帧类型 | 说明 |
|--------|------|
| `bridge.registered` | 注册确认 |
| `chat.accepted` | 请求已接受 |
| `chat.typing` | AI 正在输入 |
| `chat.delta` | 增量文本回复 |
| `chat.media` | 媒体消息 |
| `chat.final` | 回复结束标记 |
| `push.message` | 服务器推送消息 |
| `pong` | 心跳响应 |

## 安装配置

### 1. 修改 `openclaw.json`

在 `channels.alicechat` 中添加配置：

```json
{
  "channels": {
    "alicechat": {
      "enabled": true,
      "websocketHost": "127.0.0.1",
      "websocketPort": 18791
    }
  },
  "plugins": {
    "entries": {
      "alicechat": {
        "enabled": true,
        "sourcePath": "/root/.openclaw/AliceChat/openclaw-channel-alicechat"
      }
    }
  }
}
```

### 2. 设置访问密钥

在环境变量中设置 `ALICECHAT_SECRET`（后端连接时需要提供 token）：

```bash
export ALICECHAT_SECRET="your-secret-token-here"
```

### 3. 重启 OpenClaw Gateway

```bash
openclaw gateway restart
```

## Python 后端配置

AliceChat Python Backend 需要连接到插件的 WebSocket 地址：

```json
{
  "bridgeUrl": "ws://127.0.0.1:18791?token=${ALICECHAT_SECRET}"
}
```

## 与 Live2D Channel 的关系

本插件基于 `openclaw-channel-live2d` 的架构，将其中硬编码的 Live2D 字符串参数化为可配置的选项。主要区别：

| 参数 | Live2D | AliceChat |
|------|--------|-----------|
| 监听端口 | 18790 | 18791 |
| Channel 标签 | Live2D | AliceChat |
| Provider ID | live2d | alicechat |
| Client 前缀 | live2d:backend: / live2d:user: | alicechat:backend: / alicechat:user: |

## 可配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `websocketHost` | 127.0.0.1 | WebSocket 绑定地址 |
| `websocketPort` | 18791 | WebSocket 监听端口 |
| `channelLabel` | AliceChat | 消息信封中的 channel 标签 |
| `providerId` | alicechat | Provider ID |
| `backendPrefix` | alicechat:backend: | 后端 client key 前缀 |
| `userPrefix` | alicechat:user: | 用户 client key 前缀 |