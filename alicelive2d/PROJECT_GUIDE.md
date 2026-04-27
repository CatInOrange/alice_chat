# AliceClaw 项目完整指南

> 最后更新：2026-04-19

---

## 🏗️ 一、架构概览

```
用户浏览器
    ↓
┌─────────────────────────────────────────┐
│           Nginx (端口 80/443/8080)      │
│  • 80/443: 前端静态文件                  │
│  • 8080: 代理到后端 18080                │
└─────────────────────────────────────────┘
    ↓                    ↓
┌────────────┐    ┌────────────────────┐
│  前端静态    │    │   Python Flask     │
│  /var/www/ │    │   后端 (18080)      │
│  lunaria/  │    │                    │
└────────────┘    └────────┬───────────┘
                            ↓
                 ┌─────────────────────┐
                 │  OpenClaw Gateway   │
                 │  (WebSocket 18800) │
                 └─────────────────────┘
```

### 三层架构
1. **前端**：静态网页 + React
2. **后端**：Python Flask API
3. **OpenClaw Channel**：WebSocket 网关

---

## 🌐 二、服务端口

| 端口 | 服务 | 说明 |
|------|------|------|
| 80 | Nginx | 前端 HTTP |
| 443 | Nginx | 前端 HTTPS |
| 8080 | Nginx | 后端 API 代理 → 18080 |
| **18080** | Flask 后端 | 实际后端服务 |
| **18800** | OpenClaw Gateway | WebSocket 网关 |

---

## 📁 三、目录结构

```
/root/.openclaw/AliceClaw/
├── config.json              # 后端配置（含 Gateway 连接信息）
├── run.py                  # 后端启动入口
├── venv/                   # Python 虚拟环境
├── backend/                # 后端源码
│   └── app/
│       ├── routes/        # API 路由
│       └── agents/        # OpenClaw 通道
├── desktop/                # 前端源码 ⚠️重要
│   └── src/renderer/       # 前端 React 源码
│       └── src/
│           ├── app/        # 页面组件
│           ├── domains/    # 业务逻辑
│           └── hooks/      # 自定义 hooks
└── debug_logs/            # 调试日志

/var/www/lunaria/           # 前端部署位置（Nginx 静态文件根目录）
└── assets/                # 构建后的 JS/CSS
```

---

## 🔧 四、修改流程

### 1. 修改后端文件

```bash
# 后端入口和配置
vim /root/.openclaw/AliceClaw/run.py
vim /root/.openclaw/AliceClaw/config.json

# 后端 API 路由
vim /root/.openclaw/AliceClaw/backend/app/routes/*.py
```

### 2. 修改前端文件 ⚠️ 重要

```bash
# ❌ 错误：直接改部署文件（会被构建覆盖）
vim /var/www/lunaria/assets/main.js

# ✅ 正确：修改源码
vim /root/.openclaw/AliceClaw/desktop/src/renderer/src/app/shell/root-shell.tsx
```

### 常见源码路径

| 功能 | 源码路径 |
|------|----------|
| 页面布局 | `desktop/src/renderer/src/app/shell/root-shell.tsx` |
| 聊天气泡 | `desktop/src/renderer/src/domains/chat/ui/` |
| Live2D 模型 | `desktop/src/renderer/src/hooks/canvas/` |
| API 调用 | `desktop/src/renderer/src/platform/backend/openclaw-api.ts` |

### 3. 修改 Nginx 配置

```bash
vim /etc/nginx/sites-enabled/chat.newthu.com
vim /etc/nginx/sites-enabled/alicechat8081
nginx -t && systemctl reload nginx
```

### AliceChat 反向代理说明

当前 AliceChat 走两层反代：

1. `chat.newthu.com:443 -> 127.0.0.1:18081`
2. `alicechat8081:8081 -> 127.0.0.1:18081`

对流式输出、SSE、聊天接口，必须显式关闭 Nginx 缓冲，否则前端可能出现消息攒住后一起刷出的情况。

建议在相关 `location` 中保留以下配置：

```nginx
proxy_http_version 1.1;
proxy_buffering off;
proxy_cache off;
add_header X-Accel-Buffering "no" always;
chunked_transfer_encoding on;
proxy_read_timeout 86400;
proxy_connect_timeout 60s;
send_timeout 86400;
```

如果后端已经返回 `X-Accel-Buffering: no`，也不要省略 Nginx 侧的 `proxy_buffering off;`，两边都配更稳。

---

## 🚀 五、部署流程

### 完整部署步骤

```bash
# 1. 修改源码（前端或后端）

# 2. 前端构建（如果改了前端）
cd /root/.openclaw/AliceClaw/desktop
npm run build
cp -r out/renderer/* /var/www/lunaria/

# 3. 重载 Nginx
nginx -t && systemctl reload nginx

# 4. 重启后端（如果改了后端）
cd /root/.openclaw/AliceClaw
pkill -f "python3 run.py"
source venv/bin/activate
nohup python3 run.py > /tmp/lunaria-backend.log 2>&1 &

# 5. 验证
# 前端：https://alice.newthu.com
# 后端：http://localhost:18080
# Gateway：http://localhost:18800
```

### 快速部署命令

```bash
# 前端修改后一键部署
cd /root/.openclaw/AliceClaw/desktop && npm run build && cp -r out/renderer/* /var/www/lunaria/ && nginx -t && systemctl reload nginx
```

---

## 🛠️ 六、常用运维命令

```bash
# 查看后端进程
ps aux | grep "python3 run.py"

# 查看后端日志
tail -f /tmp/lunaria-backend.log

# 重启后端
pkill -f "python3 run.py" && cd /root/.openclaw/AliceClaw && source venv/bin/activate && nohup python3 run.py > /tmp/lunaria-backend.log 2>&1 &

# 检查 Nginx 状态
systemctl status nginx

# 重载 Nginx
nginx -t && systemctl reload nginx

# 检查端口占用
netstat -tlnp | grep -E '80|443|8080|18080|18800'
```

---

## ✅ 七、验证清单

- [ ] 后端运行中：`ps aux | grep python3`
- [ ] Gateway 响应：`curl http://localhost:18800/`
- [ ] 后端 API 响应：`curl http://localhost:18080/`
- [ ] 前端可访问：`https://alice.newthu.com`
- [ ] WebSocket 连接：浏览器控制台无报错

---

## 🔌 八、Gateway 配置说明

后端通过 `config.json` 中的 `bridgeUrl` 连接 OpenClaw Gateway：

```json
{
  "bridgeUrl": "ws://127.0.0.1:18800?token=..."
}
```

- **服务器本机**：必须使用 `127.0.0.1`，不能用公网 IP
- **Token**：认证令牌，用于 WebSocket 连接验证

---

## 📝 九、注意事项

1. **修改前端必须改源码**：直接改 `/var/www/lunaria/` 下的文件会被构建覆盖
2. **后端改完必须重启**：`pkill` + 重启命令
3. **前端改完必须构建**：`npm run build` + 部署
4. **Nginx 改完重载**：`systemctl reload nginx`
5. **浏览器缓存**：修改 CSS/JS 后用 `Ctrl+Shift+R` 强制刷新

---

## 🔗 相关文件

- 后端配置：`/root/.openclaw/AliceClaw/config.json`
- 后端入口：`/root/.openclaw/AliceClaw/run.py`
- 前端源码：`/root/.openclaw/AliceClaw/desktop/src/renderer/`
- 前端部署：`/var/www/lunaria/`
- 后端日志：`/tmp/lunaria-backend.log`
- Nginx 配置：`/etc/nginx/sites-available/alice_claw`
