# Tavern Architecture

## 总览

Tavern 是 AliceChat 中的一个独立 feature，不与现有 contacts/chat agent 会话语义混用。

它的核心是：

- Character
- Chat
- WorldBook
- Prompt Blocks
- Prompt Order
- Preset
- Prompt Builder Pipeline

## 前端结构

```text
lib/features/tavern/
  application/
  data/
    models/
    repositories/
  domain/
  presentation/
```

### 分层职责

#### application
- Store / ChangeNotifier
- 页面状态
- 调用 repository

#### data
- API model
- repository
- 远端数据源

#### domain
- 轻量领域对象与常量
- 未来可放 prompt 相关前端调试逻辑

#### presentation
- Tavern 首页
- 聊天页
- 角色详情
- 后续管理页

## 后端结构

```text
backend/app/
  routes/tavern.py
  services/tavern/
  store/tavern/
```

### 分层职责

#### routes
- API 路由
- 参数接收与响应封装

#### services/tavern
- 角色导入
- 世界书匹配
- prompt order 应用
- prompt 构建
- 生成调度

#### store/tavern
- SQLite 持久化
- 各 Tavern 资源 CRUD

## 关键设计

### 1. Prompt Builder Pipeline

建议统一流水线：

1. 读取 Character
2. 读取 Preset
3. 读取 PromptOrder / Blocks
4. 读取全局 WorldBooks
5. 读取 Character Lore Bindings
6. 匹配知识条目
7. 构建语义块
8. 应用 PromptOrder
9. 渲染成最终 messages
10. 调用 provider 流式生成

### 2. Character Lore 不单独裂变 schema

v1 中角色书先实现为：

- Character -> WorldBook binding

这样能保持系统 clean，同时兼容未来更复杂的角色知识体系。

### 3. Prompt 管理是核心，不是附属

Preset 不能只是 temperature/top_p。它必须绑定 PromptOrder。

### 4. 前端首页保持轻

Tavern 首页只做：

- 角色列表
- 最近会话
- 导入入口
- 管理入口

不要把复杂配置堆到首页。

## 与 AliceChat 现有模块的关系

### 复用
- MultiProvider / ChangeNotifier 风格
- 现有 FastAPI backend
- 现有 SQLite store 风格
- 现有 SSE / 流式思路

### 保持隔离
- 不复用联系人聊天 session 语义
- 不把 Tavern 塞进现有 `features/chat`
- 不让 prompt 编排逻辑散落在 UI 层

## 后续扩展方向

该骨架后续应能平滑扩展到：

- PNG / CharX 导入
- 完整角色编辑器
- 群聊
- Author note
- swipe / bookmark / branch
- 更完整的 ST preset / prompt preset 兼容
