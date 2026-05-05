# AliceChat Tavern v1

## 目标

在 AliceChat 中新增一个独立的 Tavern 子系统，面向角色卡驱动的人设聊天场景。

v1 目标不是追求功能面完整，而是先把最关键的骨架做对：

1. JSON 角色导入
2. 世界书 / 角色书
3. 完整 prompt order
4. 单角色流式聊天
5. 可扩展的前后端架构

## 设计原则

- 与现有联系人/Agent 聊天系统保持隔离
- 与 AliceChat 现有 feature/module 风格保持一致
- 首页尽量简单，配置复用设置页与管理页
- prompt order 作为一等公民，不退化成单一 system prompt
- 先做 clean、可扩展的骨架，后续再补 PNG / CharX / 群聊 / 完整编辑器

## v1 范围

### 必做
- 独立 Tavern tab
- JSON 角色导入
- 角色列表 / 角色详情
- 单角色聊天
- 流式响应
- 世界书 / 角色书
- Prompt Blocks / Prompt Order
- Preset 管理
- 设置页 Tavern 分区

### 暂不做
- PNG / CharX 导入
- 完整角色编辑器
- 群聊
- swipe 候选
- 书签 / 分支
- TTS / STT / 图像生成
- 正则脚本 / 变量系统 / 扩展生态

## 推荐阅读顺序

1. `character-json-mapping.md`
2. `prompt-order-spec.md`
3. `worldbook-spec.md`
4. `api-spec.md`
5. `architecture.md`
