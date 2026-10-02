# Agent 协作部署指南

本文件用于让同事指示 agent 将本仓库适配为自己的 Cloudflare Worker。部分工具不会自动读取单数文件名 `AGENT.md`，请在任务开始时明确要求阅读它。

## 可直接交给 agent 的指令

```text
先阅读 AGENT.md 和 README.md，再将本仓库适配到我的 Cloudflare 账户。

目标账户名称：<账户名称或邮箱>
目标 Account ID：<账户 ID>
Worker 名称：<我的 Worker 名称>
自定义域名：<我的子域名，或明确不使用自定义域名>
放置区域：<例如 azure:japanwest，或明确使用默认边缘放置>
KV 命名空间名称：<我的命名空间名称>
KV 处理方式：<新建，或复用我指定的命名空间 ID>
操作范围：<仅修改和 dry-run，或核验后实际发布>
操作环境：<Windows PowerShell，或 WSL2/Linux>

凭据由我在本机 .env 中提供，不要显示、提交或把它们写入源码。
保留唯一的 wrangler.jsonc；不得覆盖原账户的 Worker、域名绑定或 KV。
需要我设置 ADMIN / UUID 时使用交互式 Secret 命令，不要擅自轮换现有凭据。
若要求客户端节点，请生成可直接导入 v2rayN 的完整分享链接，
保存在 Git 忽略的私密文件中，而不是只给 IP 列表或占位 UUID。
```

首次创建的新资源和复用已有资源必须区分。信息不全时先确认目标，不要沿用仓库中的账户、域名、KV ID 或私密节点。

## Agent 执行规则

### 1. 检查与授权

- 先检查工作区变更并保留同事未提交的修改；阅读 `_worker.js` 的绑定、认证与订阅实现。
- 只保留根目录 `wrangler.jsonc`，不要创建并行生产配置。
- `.env`、ADMIN、UUID 和完整节点链接都可能包含凭据。不要打印其内容、写入日志、提交或发送给第三方服务。
- 用 `.env` 的 `CLOUDFLARE_API_TOKEN` 和 `CLOUDFLARE_ACCOUNT_ID` 指定目标。账户级令牌不一定能返回用户邮箱，核对账户 ID 和账户名称，而非仅凭邮箱查询。
- 发布前核验目标账户、域名区域激活状态、Worker 是否已存在、域名绑定及 DNS 冲突。存在冲突时停止，不要利用非交互式默认行为覆盖其他服务。
- 权限不足时报告 Cloudflare 错误和需要追加的权限；不得换用其他账户的现成登录状态。

新版权限参考如下，执行前以 [最新官方文档](https://developers.cloudflare.com/workers/authorization/workers/) 和实际面板为准：

| 操作 | 权限范围与级别 |
| --- | --- |
| 创建新 Worker | 目标账户的 Workers 产品级 Admin |
| 更新已有 Worker | Workers Editor；自定义域名暂不支持单 Worker 权限范围，须核对当前限制 |
| 新增或变更自定义域名 | 目标域名区域的 Workers Routes Write / Edit，同时具有对应 Worker 编辑权限 |
| 核验域名区域 | 目标区域的 Zone Read |
| 新建 KV 命名空间 | 目标账户的 Workers KV Admin；Workers Admin 不包含 KV 管理权限 |

不要为本任务无条件授予 Zone Edit、DNS Edit、SSL Edit 或整个 Developer Platform 的权限。

### 2. 适配配置

在唯一的 `wrangler.jsonc` 中修改：

- `name`：同事自己的 Worker 名称；`main` 继续使用 `_worker.js`。
- `routes`：同事自己的子域名，并设置 `custom_domain: true`；不使用自定义域名则移除旧路由并明确配置 `workers_dev`。
- `placement`：使用同事指定的区域，或移除以恢复默认边缘放置。云区域提示指向邻近的 Cloudflare 数据中心，不是部署到 Azure / AWS / GCP 内部，也不保证出口国家。
- `kv_namespaces[].id`：目标账户新建或明确指定的命名空间 ID；**`binding` 必须为 `KV`**，不能误用命名空间的显示名称。
- 本地开发默认移除 `remote: true` 或改为 `false`，避免测试写入真实 KV；只有明确需要访问生产数据时才启用。
- 保留 `keep_vars` 和可观测性；兼容日期按明确要求更新到当前受支持日期，不填写未来日期，更新后做构建及运行验证。

同事自己的部署不应保留本仓库原始 Worker 名、域名或 KV ID。只有用户明确要求改动时才修改 `_worker.js` 的业务逻辑。

### 3. 创建、发布及设置 Secret

以下 Wrangler 命令同时适用于 PowerShell 和 WSL2/Linux，在仓库根目录执行。应先适配账户及配置，再运行它们：

```text
npx wrangler whoami
npx wrangler kv namespace list
npx wrangler kv namespace create <命名空间名称>
npx wrangler deploy --dry-run
npx wrangler deploy
npx wrangler secret put ADMIN
```

- 仅在需要新建时运行 `kv namespace create`。将返回的 ID 填入配置，绑定名称选择 `KV`；已有命名空间不得重复创建。
- `secret put` 使用交互式输入，不把密钥作为命令参数。若 Worker 不存在，先安全创建；首次设置 ADMIN 前应用不可用，不要声称发布完成就可以正常使用。
- 可在用户明确同意后用 `npx wrangler secret put UUID` 设置固定 UUIDv4。不要未经许可改变已使用的节点凭据。没有固定 UUID 时，ADMIN / KEY 的变化可能改变派生节点 UUID。
- 如果无法在创建前预览域名冲突，可先以同一份配置临时移除自定义域名并创建 Worker，再预览域名变更；确认无冲突后恢复最终路由并发布。不要遗留临时配置。
- `.env` 用于 CLI 认证，不应以 `--secrets-file .env` 上传为 Worker Secret；`.dev.vars` 用于本地 Worker 运行变量。WSL2 与 Windows 的登录状态和代理连接方式可能不同，应在实际操作环境核验。

ADMIN 安全随机值的本机生成方式：

**PowerShell：**

```powershell
$b=New-Object byte[] 32; $r=[Security.Cryptography.RandomNumberGenerator]::Create(); try {$r.GetBytes($b); [BitConverter]::ToString($b).Replace('-','')} finally {$r.Dispose()}
```

**WSL2/Linux（需有 OpenSSL）：**

```bash
openssl rand -hex 32
```

生成结果交由用户保存在密码管理器中，不要代为公开。

### 4. 验证与交付

- 验证线上自定义域名、最终版本流量、兼容日期、放置及 `KV` 绑定，并确认已有 ADMIN / UUID Secret 未丢失；只检查名称和类型，不输出 Secret 值。
- 验证 HTTPS 证书及登录页。404 配置提示、1101、缺少 ADMIN / KV 或权限错误应明确报告，不得算作正常应用响应。
- 若交付节点，使用当前有效 UUID 和实际协议、路径、Host、SNI、端口生成完整分享链接；不得用占位 UUID 或模板冒充可用链接。
- 完整节点链接放入被 Git 忽略的 `V2RAYN-PRIVATE.md`，分享给用户后不要提交。当前三组共享 UUID，不是独立账户，也不能按组撤销访问。
- HTTPS 入口测试不等于代理验证：还需验证 VLESS / WebSocket 隧道及上游 TLS，区分网站拒绝访问与隧道故障。速度和出口国家须经过实际代理分别测试。
- 更新 README 中的部署说明，使其与新账户配置一致；不复制本机私密文档到同事的部署。
- 交付时说明实际发布了什么、验证了什么、哪些要求未满足，以及仍需用户完成的操作。不要宣称 Anycast 入口就是日本 / 美国出口。
