# claude-glm-conc-hud

> Claude Code 状态栏插件：实时显示 GLM（智谱）API 的**活跃并发请求数**，帮助你把多 agent / 多会话的并发量控制在账户配额之内。

## 解决什么问题

用 Claude Code 接智谱 GLM（通过 `open.bigmodel.cn/api/anthropic` 这个 Anthropic 兼容入口）时，GLM 会按账户限制**并发请求数**，超限返回错误码 `1302`（HTTP 表现通常为 429）。同时开多个 agent、多个子任务或多个会话时，很容易撞到上限，导致请求被拒、需要重试。

直观的监控思路是"数当前到 GLM 的连接数"，但**直接数 TCP 连接数会严重虚高**：

1. **HTTP keep-alive 连接池**：客户端对同一个域名默认池化多个 socket，空闲时也保持 `ESTABLISHED`；
2. **跨回合残留**：Claude Code 的主 socket 在回合之间是"开着但不传数据"的空闲态，仍会被数成 1 条连接；
3. **无关域名**：如 `api.z.ai` 等其他 socket 也会被匹配进来。

> 实测：账户里同时只有约 3 个真正在跑的请求时，"连接数"能显示成 10+。

如果按这个虚高数字去给 agent 限流，会严重**低用**配额（不敢放开并发）；而反过来误判则可能**撞上限**。两种都不对。

## 关键结论（实测 + 官方文档）

GLM 的并发配额**只统计"同一时刻正在处理中的请求数"**，**空闲的 keep-alive socket 不占配额**。

- 依据：[智谱 AI 速率限制文档](https://docs.bigmodel.cn/cn/api/rate-limit) —— *"并发数指的是：同一时刻正在处理中的请求数量"*。
- 实测验证：持有 8 个空闲 keep-alive socket + 并发 3 个活跃流（mihomo 里峰值 13 条连接），3 个活跃流**全部成功、0 个被拒**。证明空闲 socket 不挤占配额位。

结论：监控器应当只数**正在传数据的活跃连接**，而不是所有打开的连接。

## 它怎么工作

### `glm-conc.sh`（核心）

通过 mihomo（clash-verge 内核）的 Unix socket 查询 `/connections`，过滤出 `open.bigmodel.cn` 的连接，然后只把**活跃**的计入：

- 下行（`download`）或上行（`upload`）相对上次采样有增长 → 活跃；
- 新出现的连接 → 活跃（请求刚发出，正在上传 prompt）；
- 涨动后给 **1 帧宽限**，覆盖 GLM "思考 / 首 token"（TTFT）阶段下行短暂冻结的情况；
- 连续 2 帧无增长 → 判为空闲 keep-alive，剔除。

两次采样之间用 `/tmp/glm-conc.state` 保存上次的每连接字节计数。状态栏每次刷新 = 一次采样，自然形成增量。输出形如 `GLM:<n>`。

### `hud-with-conc.sh`

仿 Powerlevel10k 风格组装状态栏：

```
 目录 | git 分支状态 | 模型 | GLM 并发 | 时间
```

并发段按阈值上色（默认 `≥9 红(满) / ≥7 黄 / 其余青`），可按你的账户上限自行修改。

## 依赖

- **clash-verge / mihomo**：内核开启 `external-controller-unix`，路径 `/tmp/verge/verge-mihomo.sock`（clash-verge 默认值）。路径不同就改 `glm-conc.sh` 顶部的 `SOCK`。
- **Claude Code** 走 GLM：`ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic`。
- **Nerd Font**（状态栏图标）；可选 **Powerlevel10k** 配色（仅影响观感）。

## 安装

1. 拷贝两个脚本到 `~/.claude/hud/` 并赋予执行权限：

   ```bash
   mkdir -p ~/.claude/hud
   cp glm-conc.sh hud-with-conc.sh ~/.claude/hud/
   chmod +x ~/.claude/hud/glm-conc.sh ~/.claude/hud/hud-with-conc.sh
   ```

2. 在 Claude Code 的 `settings.json` 里配置状态栏：

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash $HOME/.claude/hud/hud-with-conc.sh"
     }
   }
   ```

## 配置项

| 想改什么 | 在哪里改 |
|---|---|
| 并发阈值 / 颜色 | `hud-with-conc.sh` 里 `fmt_conc()` 的 `-ge` 判断 |
| 监控的域名 | `glm-conc.sh` 顶部 `API_HOST`（默认 `bigmodel`，即 `open.bigmodel.cn`） |
| 代理 socket 路径 | `glm-conc.sh` 顶部 `SOCK` |
| 状态过期阈值 | `glm-conc.sh` 顶部 `STALE`（秒，超过则退化为当前总连接数） |

## 验证方式

- 单独跑计数器：`bash ~/.claude/hud/glm-conc.sh` → 输出 `GLM:<n>`。
- 在 Claude Code 会话里观察状态栏 `GLM:N`：开多 agent 时 N 上升，空闲时回落到 0~1。
- 极端情况排查：`curl -s --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/connections | jq '.connections[] | select(.metadata.host|test("bigmodel"))'` 可直接看原始连接。

## 文件

- `glm-conc.sh` — 活跃并发计数（mihomo 连接 → 正在处理中的请求数）。
- `hud-with-conc.sh` — 状态栏组装（目录 / git / 模型 / 并发 / 时间）。

## License

MIT
