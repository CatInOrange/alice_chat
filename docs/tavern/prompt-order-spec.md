# Prompt Order Spec

## 目标

Prompt Order 是 Tavern v1 的核心。它不能退化成单一 system prompt，而应建模为：

- 一组 prompt blocks
- 每个 block 可启用/禁用
- 每个 block 有类型与注入位置
- 每个 preset 绑定一个 prompt order

这套规范参考了 SillyTavern / NativeTavern 的思路，但按 AliceChat 当前代码风格做了更适合渐进实现的收敛。

## 核心对象

### PromptBlock

表示一个可复用的 prompt 内容块。

字段建议：

- `id: string`
- `name: string`
- `enabled: bool`
- `content: string`
- `kind: string`
- `injection_mode: "static" | "depth" | "position"`
- `depth: int | null`
- `role_scope: "global" | "character" | "chat" | "preset"`
- `created_at: float`
- `updated_at: float`

#### kind 建议枚举

- `system`
- `persona`
- `jailbreak`
- `character`
- `scenario`
- `example_messages`
- `world_info`
- `author_note`
- `custom`

### PromptOrder

表示某种编排模板。

字段建议：

- `id: string`
- `name: string`
- `items: PromptOrderItem[]`
- `created_at: float`
- `updated_at: float`

### PromptOrderItem

表示某个 block 在当前编排中的位置与开关。

字段建议：

- `block_id: string`
- `enabled: bool`
- `order_index: int`
- `position: string`
- `depth: int | null`

## position 语义

v1 建议先支持以下位置：

- `before_system`
- `after_system`
- `before_character`
- `after_character`
- `before_example_messages`
- `after_example_messages`
- `before_chat_history`
- `after_chat_history`
- `before_last_user`
- `at_depth`

其中：

- `at_depth` 表示在最近聊天历史的某个深度位置插入
- depth 的具体解释建议使用“距末尾消息向前第 N 层”语义，并在实现时保持统一

## 绑定关系

### Preset -> PromptOrder

每个 preset 必须绑定一个 `prompt_order_id`。

### PromptOrder -> PromptBlocks

PromptOrder 通过 `PromptOrderItem.block_id` 引用具体 blocks。

## 组装原则

Prompt 构建时，应先拿到语义分段，再由 PromptOrder 决定最终顺序。

推荐的基础语义分段：

1. system base
2. preset static blocks
3. persona
4. character definition
5. character scenario
6. matched worldbook entries
7. character lore entries
8. example dialogues
9. chat history
10. depth injections
11. last user message

PromptOrder 的职责不是“生成内容”，而是“编排这些内容块的顺序和位置”。

## v1 实现约束

为保持 clean 和可扩展，v1 先不做：

- 复杂脚本宏执行
- provider-specific prompt dialect
- 过于动态的运行时 block 生成 DSL

但数据结构必须允许未来扩展。

## 调试建议

调试输出应能展示：

- 生效的 prompt order 名称
- 生效 block 列表
- 每个 block 的 position / order
- depth 注入结果
- 最终渲染出的 messages 摘要
