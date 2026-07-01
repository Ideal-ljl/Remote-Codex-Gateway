# Remote Codex Gateway Package

这是远程 Codex 网关的部署包。它负责启动 native/headless 服务，管理账号池，按额度和优先级路由请求，并提供内置网页控制台。

## 包内容

- `install.sh`：安装 `remote-codex-gateway` 命令到 `~/.local/bin`。
- `start.sh`：启动、停止、登录账号、管理账号、查看日志和打开 dashboard。
- `build-binary.sh`：可选的本地 release 构建脚本。
- `bin/`：可选预构建 `codexmanager-service` 二进制。
- `config.yaml.example`：YAML 配置模板。
- `config.yaml`：本机配置，已被 Git 忽略。
- `config.env.example` / `config.env`：旧格式配置，仍兼容。
- `data/`：SQLite、RPC token，已被 Git 忽略。
- `logs/`：运行日志，已被 Git 忽略。

## 安装

```bash
git clone https://github.com/Ideal-ljl/Remote-Codex-Gateway.git Remote-Codex-Gateway
cd Remote-Codex-Gateway
cp deploy/remote-codex-gateway/config.yaml.example deploy/remote-codex-gateway/config.yaml
vi deploy/remote-codex-gateway/config.yaml
./deploy/remote-codex-gateway/install.sh
remote-codex-gateway start
```

如果命令不在 `PATH`：

```bash
./deploy/remote-codex-gateway/start.sh start
```

如果没有可用二进制，先安装 Rust/Cargo：

```bash
remote-codex-gateway install-rust
remote-codex-gateway start
```

镜像配置示例：

```yaml
rustup:
  distServer: https://rsproxy.cn
  updateRoot: https://rsproxy.cn/rustup

cargo:
  registryMirror: rsproxy
```

## 配置

服务端口和 dashboard 外部地址：

```yaml
gateway:
  webPort: 48761
  publicBaseUrl: http://<server-ip-or-domain>:48761
```

上游代理：

```yaml
gateway:
  upstreamProxyUrl: http://127.0.0.1:7890
```

`upstreamProxyUrl` 是网关服务在服务器本地发出最终上游请求时使用的代理端口。`127.0.0.1:7890` 指运行 gateway 的服务器本机，不是客户端机器。它不影响客户端连入，也不负责 Cargo/rustup 下载。

账号池：

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

priority 越小越优先。`apply-config` 会按 tag 找到账号并更新排序。

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

`start` 写入 provider 配置后会按当前 `model_provider` 修复 Codex App 本地历史可见性，修复前会备份受影响的历史文件。

## 命令

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

页面可查看账号额度和请求日志，也可添加账号、刷新额度、启用/禁用、删除、重命名、调整优先级。

添加账号：

```bash
remote-codex-gateway login primary
remote-codex-gateway add-account backup
```

查看额度：

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
remote-codex-gateway service-log -n 100
remote-codex-gateway service-log -f
```

创建客户端平台 Key：

```bash
remote-codex-gateway key
```

Codex / ccswitch 使用：

```text
base_url = http://<server-ip-or-domain>:48761/v1
OPENAI_API_KEY = 上一步生成的平台 Key
```

账号 token、平台 Key、数据库、日志和本机 `config.yaml` / `config.env` 不要提交到 Git。
