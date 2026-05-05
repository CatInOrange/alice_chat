# WorldBook Spec

## 目标

世界书和角色书是一期开局就必须具备的核心能力。

本规范定义：

- WorldBook
- WorldBookEntry
- Character Lore Binding
- 匹配与注入的最小规则

设计重点：

- 统一数据结构
- 支持未来扩展到更完整 ST 语义
- v1 先把关键词匹配 + 位置注入做扎实

## 核心对象

### WorldBook

字段建议：

- `id: string`
- `name: string`
- `description: string`
- `enabled: bool`
- `created_at: float`
- `updated_at: float`

### WorldBookEntry

字段建议：

- `id: string`
- `worldbook_id: string`
- `keys: string[]`
- `secondary_keys: string[]`
- `content: string`
- `enabled: bool`
- `priority: int`
- `recursive: bool`
- `constant: bool`
- `insertion_position: string`
- `group_name: string`

#### insertion_position 建议枚举

- `before_character`
- `after_character`
- `before_example_messages`
- `before_chat_history`
- `before_last_user`

### CharacterLoreBinding

v1 不额外造一套独立角色书 schema，先复用 worldbook 绑定。

字段建议：

- `id: string`
- `character_id: string`
- `worldbook_id: string`
- `enabled: bool`
- `priority_override: int | null`

## 匹配规则（v1）

### constant 条目

若 entry `constant = true`，则不依赖关键词，始终注入。

### keys 匹配

若 `constant = false`：

- 在最近用户消息、聊天历史窗口、角色上下文中查找 `keys`
- 命中任意 key 即视为匹配

### secondary_keys

v1 可选支持：

- 若提供 secondary_keys，则要求 primary 命中后，再按 secondary 进一步筛选
- 若实现复杂度过高，可先保留字段不启用强语义

### recursive

v1 可先保留字段；若实现递归扫描，则应限制层数和最大命中数量。

## 优先级规则

- priority 越高，越优先
- 角色绑定的 worldbook 在同等条件下优先于全局 worldbook
- 后续若需要组评分，可在保持字段兼容的情况下扩展

## 注入策略

匹配出的 entries 不直接拼接到任意位置，而应转换为 prompt blocks，再交给 prompt builder / prompt order 统一编排。

也就是说：

- 世界书系统负责“选出哪些知识条目生效”
- Prompt 系统负责“这些条目最终怎么注入”

## v1 范围建议

### 必须支持
- WorldBook CRUD
- Entry CRUD
- enabled
- priority
- constant
- insertion_position
- 角色绑定 worldbook
- 命中结果调试查看

### 可以后续增强
- secondary key 强语义
- 递归组匹配
- token budget 裁剪
- group scoring
- selective de-duplication
