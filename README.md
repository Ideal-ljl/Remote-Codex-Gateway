# Remote Codex Gateway

这个仓库用于在远程机器上运行一个 Codex 网关：Codex 客户端只连一个 `/v1` 地址，网关在服务器本地按账号优先级、额度阈值和失败情况自动选择可用账号。

## 功能介绍

- 多账号轮换：支持两个以上 Codex 账号，按 priority 从小到大使用，账号额度不足或上游失败时自动切换。
- 额度保护：同时看 5 小时窗口和 week 窗口，低于阈值的账号会优先跳过。
- 账号管理：命令行和网页都支持添加账号、刷新额度、启用/禁用、删除、重命名、调整优先级。
- 请求日志：记录模型、状态码、耗时、token、成本、路由策略和实际使用的账号。
- YAML 配置：主要配置在 `deploy/remote-codex-gateway/config.yaml`，旧 `config.env` 仍兼容。
- Codex App SSH：`start` 可自动把服务器端 `~/.codex/config.toml` 的 provider 指到本机网关。
- 网页控制台：内置 `/dashboard`，用于观察账号额度和请求日志，也能做常用账号操作。

## 安装

```bash
git clone <你的仓库地址> Codex-Manager
cd Codex-Manager
cp deploy/remote-codex-gateway/config.yaml.example deploy/remote-codex-gateway/config.yaml
vi deploy/remote-codex-gateway/config.yaml
./deploy/remote-codex-gateway/install.sh
remote-codex-gateway start
```

如果 `~/.local/bin` 不在 `PATH`，可以直接运行脚本：

```bash
./deploy/remote-codex-gateway/start.sh start
```

如果目标机没有可用二进制，先安装 Rust/Cargo 后启动，脚本会在本机 release 构建服务：

```bash
remote-codex-gateway install-rust
remote-codex-gateway start
```

Rust 下载慢时可以在 `config.yaml` 设置镜像：

```yaml
rustup:
  distServer: https://rsproxy.cn
  updateRoot: https://rsproxy.cn/rustup

cargo:
  registryMirror: rsproxy
```

USTC 示例：

```yaml
rustup:
  distServer: https://mirrors.ustc.edu.cn/rust-static
  updateRoot: https://mirrors.ustc.edu.cn/rust-static/rustup

cargo:
  registryMirror: ustc
```

## 关键配置

网关端口和外部访问地址：

```yaml
gateway:
  webPort: 48761
  publicBaseUrl: http://<server-ip-or-domain>:48761
```

Codex 客户端使用：

```text
http://<server-ip-or-domain>:48761/v1
```

上游代理：

```yaml
gateway:
  upstreamProxyUrl: http://127.0.0.1:7890
```

`upstreamProxyUrl` 是网关服务在服务器本地发起最终上游请求时使用的出口代理。也就是说，请求流向是：

```text
Codex 客户端 -> remote-codex-gateway -> 服务器本地 127.0.0.1:7890 -> OpenAI/Codex 上游
```

因此 `127.0.0.1:7890` 必须是运行 gateway 的那台服务器上的代理端口，不是你笔记本浏览器所在机器的端口。它也不是 Cargo/rustup 下载依赖用的代理；构建代理使用 `gateway.buildProxyUrl`，Cargo 镜像使用 `cargo.registryMirror`。

账号槽位和优先级：

```yaml
accounts:
  loginAccount: primary
  applyConfigAfterLogin: true
  slots:
    primary:
      tags: primary
      note: Primary Codex Pro account
      priority: 0
    backup:
      tags: backup
      note: Backup Codex Pro account
      priority: 10

routing:
  strategy: ordered
```

`primary` / `backup` 是命令行和网页里使用的短名。priority 越小越优先，`apply-config` 会按 tag 找到账号并写入排序。

额度阈值：

```yaml
quotaGuard:
  enabled: true
  primaryMinRemainingPercent: 5
  weeklyMinRemainingPercent: 10
  allowAllLowFallback: true
```

Codex App SSH provider：

```yaml
codexApp:
  configureProviderOnStart: true
  configPath: ~/.codex/config.toml
  keyPath: ~/.codex/remote-gateway-api-key
  providerId: remote_gateway
  wireApi: responses
  warmModels: true
  restartAppServer: false
```

`start` 健康检查通过后会创建平台 Key 文件并写入 `~/.codex/config.toml`，第一次写入前会备份到 `~/.codex/config.toml.remote-gateway.bak`。`warmModels` 会预热模型目录和账号路由，减少第一次请求遇到冷缓存的概率。默认不重启 app-server；重新打开 Codex 远端 SSH 会话后生效。

## 常用命令

服务：

```bash
remote-codex-gateway start
remote-codex-gateway status
remote-codex-gateway health
remote-codex-gateway stop
```

网页控制台：

```bash
remote-codex-gateway dashboard
```

该命令会打印 `/dashboard#rpcToken=...` 链接。token 放在 URL hash 中，页面加载后会保存 token 并清掉地址栏 hash。控制台支持查看账号额度、请求日志、添加账号、刷新额度、启用/禁用、删除、重命名和调整优先级。

添加账号：

```bash
remote-codex-gateway login primary
remote-codex-gateway add-account backup
```

查看账号和额度：

```bash
remote-codex-gateway accounts
remote-codex-gateway accounts --show-id
remote-codex-gateway quota
remote-codex-gateway refresh-quota
remote-codex-gateway refresh-quota primary
```

管理账号：

```bash
remote-codex-gateway disable-account primary
remote-codex-gateway enable-account primary
remote-codex-gateway rename-account primary main
remote-codex-gateway set-priority backup 5
remote-codex-gateway delete-account backup
remote-codex-gateway apply-config
```

日志：

```bash
remote-codex-gateway logs
remote-codex-gateway logs -n 50
remote-codex-gateway logs -q gpt-5
remote-codex-gateway logs --show-id
remote-codex-gateway service-log -n 100
remote-codex-gateway service-log -f
```

创建客户端平台 Key：

```bash
remote-codex-gateway key
```

Codex / ccswitch 只使用这里生成的平台 Key，不要把 OpenAI 官方 Platform Key、账号 `access_token` 或 `refresh_token` 填给客户端。

## 数据和安全

不要提交以下文件：

- `deploy/remote-codex-gateway/config.yaml`
- `deploy/remote-codex-gateway/config.env`
- `deploy/remote-codex-gateway/data/`
- `deploy/remote-codex-gateway/logs/`
- `~/.codex/remote-gateway-api-key`

这些文件包含账号 token、平台 Key、数据库、RPC token 或本机配置。
