# 御姐版基线 commit 备忘录

## 对应关系
- Git commit: c1b3c6cf (HEAD)
- 线上前端包: main-C2zAN40t.js
- 后端接口: /api/debug/live2d-drag 等，已确认兼容

## Tease 三句（已验证）
```
"哎呀，1分钟里偷偷摸我四次啦，弟弟你这是在故意撩我嘛？姐姐都要被你逗笑了。"
"喂喂喂，这么短时间逗我四次，坏心思都写脸上啦，要不要我也反过来撩你一下？"
"你今天很会嘛，一分钟内逗我四回，是想让我主动黏你一点嘛，嗯？"
```

## 如何重建
```bash
cd desktop
git checkout c1b3c6cf
npm run build:web
# 产物在 dist/web/assets/，取 hash 匹配 main-C2zAN40t.js 的那个
```

## 注意事项
- c1b3c6cf 之后还有后续 commit（92eb8337, e7d7cbb1 等），不要 reset 到 c1b3c6cf 之后
- 如果要继续开发新功能，从 e7d7cbb1 或更新分支拉出
- 如果要修改 tease 文案，基于 c1b3c6cf 新建分支
