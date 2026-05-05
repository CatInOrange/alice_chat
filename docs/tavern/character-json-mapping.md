# Character JSON Mapping

## 目标

v1 仅支持 JSON 角色导入。这里定义外部角色 JSON 到 AliceChat Tavern 内部模型的映射规则。

设计目标：

- 优先兼容 SillyTavern / Tavern 常见角色 JSON
- 保留原始 JSON，避免导入时损失信息
- 对未识别字段保持宽容，统一落到 metadata
- 为未来 PNG / CharX 导入预留稳定内部模型

## 内部目标模型

`TavernCharacterRecord`

- `id: string`
- `name: string`
- `description: string`
- `personality: string`
- `scenario: string`
- `first_message: string`
- `example_dialogues: string`
- `avatar_path: string`
- `tags: string[]`
- `source_type: "json" | "manual"`
- `source_name: string`
- `raw_json: string`
- `metadata_json: string`
- `created_at: float`
- `updated_at: float`

## 常见字段映射

### 基础字段

优先按下面顺序取值：

- `name`
- `char_name`

映射到：
- `name`

---

- `description`
- `char_description`

映射到：
- `description`

---

- `personality`

映射到：
- `personality`

---

- `scenario`
- `world_scenario`

映射到：
- `scenario`

---

- `first_mes`
- `firstMessage`
- `first_message`

映射到：
- `first_message`

---

- `mes_example`
- `example_dialogues`
- `exampleMessages`

映射到：
- `example_dialogues`

---

- `avatar`
- `avatar_path`

映射到：
- `avatar_path`

> v1 仅保留路径/标记，不处理 PNG/二进制资源抽取。

---

- `tags`

映射到：
- `tags`

规则：
- 若是字符串数组，直接使用
- 若是逗号分隔字符串，拆分后 trim
- 其他情况回退为空数组

## 扩展字段

以下字段不直接映射到一等字段，但应保留到 metadata：

- `creator`
- `creator_notes`
- `system_prompt`
- `alternate_greetings`
- `extensions`
- `character_book`
- `character_version`
- `post_history_instructions`
- `data`
- 任意未知字段

## 原始 JSON 保留策略

导入时必须完整保留：

- `raw_json`: 原始 JSON 字符串
- `metadata_json`: 规范化后的额外字段 JSON

这样后续可以：

- 重新导出
- 补充更完整字段支持
- 在未来接入 PNG / CharX 时避免模型翻修

## 角色书字段策略

如果导入 JSON 中已经包含角色书/知识库结构：

- v1 不要求完整还原所有高级语义
- 但应完整保留原始字段到 `metadata_json`
- 若结构可识别，可在导入阶段转换为后续的 `character_lore_bindings`

## 导入校验

最低校验要求：

- 必须是合法 JSON 对象
- `name` 不能为空（可从备选字段回退）

其余字段允许缺失，默认空字符串或空数组。

## 导入结果建议

导入接口返回：

- 标准化后的 character 记录
- 可选 `warnings: string[]`

典型 warning：

- 未识别的角色书结构仅保留原始 metadata
- avatar 字段已保留但未处理资源
- 缺少 first message / examples
