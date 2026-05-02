# Netease OpenAPI / ncm-cli 路径约定

当前 AliceChat 后端对网易云官方 CLI 的正式约定如下：

## 1. CLI 程序目录

- 默认值：`/root/.openclaw/AliceChat/tools/ncm-cli/package`
- 入口文件：`/root/.openclaw/AliceChat/tools/ncm-cli/package/dist/index.js`
- 可用环境变量覆盖：`ALICECHAT_NETEASE_OPENAPI_CLI_DIR`

> 这里放的是 ncm-cli 程序包本体，不放账号配置或登录态。
> 不要长期依赖 `/tmp` 作为程序目录；`/tmp` 只适合临时调试。

## 2. CLI HOME / 数据目录

- 默认值：`/root/.openclaw/AliceChat/data/netease-openapi`
- 可用环境变量覆盖：`ALICECHAT_NETEASE_OPENAPI_HOME`

后端会把这个目录作为 `HOME` 传给 ncm-cli。登录态和配置必须都落在这里。

## 3. 必需文件

位于：`/root/.openclaw/AliceChat/data/netease-openapi/.config/ncm-cli/`

至少需要：

- `credentials.enc.json`
- `tokens.enc.json`

缺少其中任意一个，后端会拒绝调用 heartbeat/favorite 等官方能力。

## 4. 维护原则

1. 不要把登录态或凭据写到 `/tmp` 的随机目录。
2. 不要让不同脚本各自使用不同 HOME。
3. 如果需要迁移路径，优先通过环境变量统一覆盖，不要在代码里散改。
4. 故障排查时，先确认：
   - CLI 程序目录存在
   - `dist/index.js` 存在
   - HOME 目录存在
   - `credentials.enc.json` 存在
   - `tokens.enc.json` 存在
