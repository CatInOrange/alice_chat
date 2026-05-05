# Tavern API Spec (v1)

## 目标

定义 Tavern v1 的前后端边界，优先保证：

- 角色 JSON 导入
- 单角色聊天
- 流式响应
- 世界书 / Prompt Order 管理

## 通用约定

- 所有接口走现有 AliceChat backend 认证
- JSON 响应使用现有 backend 的简洁风格
- v1 优先返回清晰、稳定的数据结构，而不是过度包装

---

## 1. Characters

### `GET /api/tavern/characters`

返回角色列表。

### `POST /api/tavern/characters/import-json`

导入角色 JSON。

请求体建议：

```json
{
  "filename": "character.json",
  "content": { "name": "..." }
}
```

返回：

```json
{
  "ok": true,
  "character": { ... },
  "warnings": []
}
```

### `GET /api/tavern/characters/{id}`

返回角色详情。

### `DELETE /api/tavern/characters/{id}`

删除角色。

---

## 2. Chats

### `GET /api/tavern/chats`

返回 Tavern 聊天列表。

### `POST /api/tavern/chats`

创建会话。

请求体建议：

```json
{
  "characterId": "char_xxx",
  "presetId": "preset_xxx"
}
```

### `GET /api/tavern/chats/{id}`

返回单个聊天信息。

### `GET /api/tavern/chats/{id}/messages`

返回聊天消息列表。

### `DELETE /api/tavern/chats/{id}`

删除聊天。

---

## 3. Chat Generation

### `POST /api/tavern/chats/{id}/send`

发送用户消息并启动生成。

请求体建议：

```json
{
  "text": "你好",
  "presetId": "preset_xxx"
}
```

返回：

```json
{
  "ok": true,
  "chatId": "chat_xxx",
  "requestId": "req_xxx",
  "assistantMessageId": "msg_xxx"
}
```

### `GET /api/tavern/chats/{id}/stream?requestId=req_xxx`

SSE 输出建议包含：

- `start`
- `delta`
- `final`
- `error`

#### delta 示例

```text
event: delta
data: {"messageId":"msg_xxx","delta":"你好"}
```

#### final 示例

```text
event: final
data: {"messageId":"msg_xxx","text":"你好，郎君。"}
```

### `POST /api/tavern/chats/{id}/stop`

停止当前生成。

### `POST /api/tavern/chats/{id}/regenerate`

重新生成最后一条 assistant 消息。

---

## 4. WorldBooks

### `GET /api/tavern/worldbooks`
### `POST /api/tavern/worldbooks`
### `GET /api/tavern/worldbooks/{id}`
### `PUT /api/tavern/worldbooks/{id}`
### `DELETE /api/tavern/worldbooks/{id}`

### `GET /api/tavern/worldbooks/{id}/entries`
### `POST /api/tavern/worldbooks/{id}/entries`
### `PUT /api/tavern/worldbooks/{id}/entries/{entryId}`
### `DELETE /api/tavern/worldbooks/{id}/entries/{entryId}`

---

## 5. Prompt Blocks / Prompt Orders

### `GET /api/tavern/prompt-blocks`
### `POST /api/tavern/prompt-blocks`
### `PUT /api/tavern/prompt-blocks/{id}`
### `DELETE /api/tavern/prompt-blocks/{id}`

### `GET /api/tavern/prompt-orders`
### `POST /api/tavern/prompt-orders`
### `PUT /api/tavern/prompt-orders/{id}`
### `DELETE /api/tavern/prompt-orders/{id}`

---

## 6. Presets

### `GET /api/tavern/presets`
### `POST /api/tavern/presets`
### `PUT /api/tavern/presets/{id}`
### `DELETE /api/tavern/presets/{id}`

Preset 至少应包含：

- provider
- model
- sampling params
- promptOrderId

---

## 7. Debug / Introspection (推荐)

为了后续调 prompt，不建议把调试信息埋掉。

### `GET /api/tavern/chats/{id}/prompt-debug`

返回建议：

- current preset
- current prompt order
- matched worldbook entries
- character lore bindings
- rendered block summary

这个接口对后续稳定迭代价值很高。
