#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/config.yaml"
LEGACY_CONFIG="$SCRIPT_DIR/config.env"
if [[ -n "${REMOTE_GATEWAY_CONFIG:-}" ]]; then
  CONFIG_FILE="$REMOTE_GATEWAY_CONFIG"
elif [[ -f "$DEFAULT_CONFIG" ]]; then
  CONFIG_FILE="$DEFAULT_CONFIG"
elif [[ -f "$LEGACY_CONFIG" ]]; then
  CONFIG_FILE="$LEGACY_CONFIG"
else
  CONFIG_FILE="$DEFAULT_CONFIG"
fi
COMMAND="start"
BACKGROUND=true
ACCOUNT_SLOT=""
ACCOUNT_REF=""
ACCOUNT_NAME_VALUE=""
PRIORITY_VALUE=""
SHOW_ACCOUNT_IDS=false
LOG_LIMIT=20
LOG_QUERY=""
LOG_FOLLOW=false

usage() {
  cat <<'EOF'
Usage: remote-codex-gateway [command] [options]

Commands:
  start                 Run the gateway and optionally configure Codex App provider. Default.
  stop                  Stop the background gateway.
  status                Show gateway status.
  health                Check gateway health.
  dashboard             Print a browser dashboard URL for accounts, quota, and request logs.
  install-rust          Install Rust/Cargo with rustup for local builds.
  login account-name    Add an account with a short command-line name.
  add-account name      Alias for login.
  accounts [--show-id]  Show accounts, priority, status, and quota in a table.
  quota                 Show the same account quota table.
  refresh-quota [acct]  Refresh quota for all accounts, or one account id/tag/label.
  disable-account acct  Disable an account by id, tag, or label.
  enable-account acct   Enable a disabled account by id, tag, or label.
  delete-account acct   Delete an account by id, tag, or label.
  rename-account acct name
                        Set the short display name used by account tables.
  set-priority acct N   Set account priority/sort value.
  key                   Create a platform API key for Codex clients.
  apply-config          Apply configured account priorities.
  logs                  Show recent model request logs from the gateway database.
  service-log           Show the native gateway runtime log file.

Options:
  --config PATH         Load config.yaml by default; legacy config.env is still supported.
  --account NAME        Account slot for login, such as primary or backup.
  --show-id             Include raw account IDs in account/quota output.
  -n, --tail N          Number of request/service log rows to show. Default: 20.
  -q, --query TEXT      Filter request logs by model, account, path, status, or trace.
  -f, --follow          Follow service-log output.
  --foreground          Run the gateway in the foreground.
  --background          Run the gateway in the background. Default.
  -h, --help            Show this help.

Compatibility aliases:
  --login-account [account], --create-api-key, --apply-config, --install-rust, --status, --stop, --health
EOF
}

step() {
  printf '[remote-gateway] %s\n' "$*"
}

warn() {
  printf '[remote-gateway] warning: %s\n' "$*" >&2
}

die() {
  printf '[remote-gateway] error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    start|stop|status|health|dashboard|ui|key|apply-config|install-rust|accounts|quota|logs|service-log)
      COMMAND="$1"
      [[ "$COMMAND" == "ui" ]] && COMMAND="dashboard"
      shift
      ;;
    login|add-account)
      COMMAND="login"
      shift
      if [[ $# -gt 0 && "${1:-}" != --* ]]; then
        ACCOUNT_SLOT="$1"
        shift
      fi
      ;;
    refresh-quota)
      COMMAND="refresh-quota"
      shift
      if [[ $# -gt 0 && "${1:-}" != --* ]]; then
        ACCOUNT_REF="$1"
        shift
      fi
      ;;
    disable-account|enable-account|delete-account)
      COMMAND="$1"
      shift
      if [[ $# -gt 0 && "${1:-}" != --* ]]; then
        ACCOUNT_REF="$1"
        shift
      else
        die "$COMMAND requires an account id, tag, or label"
      fi
      ;;
    rename-account|set-name)
      COMMAND="rename-account"
      shift
      if [[ $# -ge 2 && "${1:-}" != --* && "${2:-}" != --* ]]; then
        ACCOUNT_REF="$1"
        ACCOUNT_NAME_VALUE="$2"
        shift 2
      else
        die "rename-account requires: account id/tag/label and new short name"
      fi
      ;;
    set-priority|priority)
      COMMAND="set-priority"
      shift
      if [[ $# -ge 2 && "${1:-}" != --* && "${2:-}" != --* ]]; then
        ACCOUNT_REF="$1"
        PRIORITY_VALUE="$2"
        shift 2
      else
        die "set-priority requires: account id/tag/label and integer priority"
      fi
      ;;
    --config)
      [[ $# -ge 2 ]] || die "--config requires a path"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --account)
      [[ $# -ge 2 ]] || die "--account requires a name"
      ACCOUNT_SLOT="$2"
      shift 2
      ;;
    --login-account|--device-login)
      COMMAND="login"
      shift
      if [[ $# -gt 0 && "${1:-}" != --* ]]; then
        ACCOUNT_SLOT="$1"
        shift
      fi
      ;;
    --create-api-key)
      COMMAND="key"
      shift
      ;;
    --apply-config)
      COMMAND="apply-config"
      shift
      ;;
    --install-rust)
      COMMAND="install-rust"
      shift
      ;;
    --foreground)
      BACKGROUND=false
      shift
      ;;
    --background)
      BACKGROUND=true
      shift
      ;;
    --stop)
      COMMAND="stop"
      shift
      ;;
    --status)
      COMMAND="status"
      shift
      ;;
    --health)
      COMMAND="health"
      shift
      ;;
    --accounts|--list-accounts)
      COMMAND="accounts"
      shift
      ;;
    --quota)
      COMMAND="quota"
      shift
      ;;
    --show-id|--show-ids|--ids)
      SHOW_ACCOUNT_IDS=true
      shift
      ;;
    -n|--tail|--limit)
      [[ $# -ge 2 ]] || die "$1 requires a number"
      LOG_LIMIT="$2"
      shift 2
      ;;
    -q|--query)
      [[ $# -ge 2 ]] || die "--query requires text"
      LOG_QUERY="$2"
      shift 2
      ;;
    -f|--follow)
      LOG_FOLLOW=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

ensure_config_file() {
  if [[ -f "$CONFIG_FILE" ]]; then
    return
  fi
  if [[ "$CONFIG_FILE" == "$DEFAULT_CONFIG" && -f "$SCRIPT_DIR/config.yaml.example" ]]; then
    cp "$SCRIPT_DIR/config.yaml.example" "$CONFIG_FILE"
    step "created $CONFIG_FILE from config.yaml.example"
    step "edit account slots, proxy, priorities, and quota thresholds before production use"
    return
  fi
  if [[ "$CONFIG_FILE" == "$LEGACY_CONFIG" && -f "$SCRIPT_DIR/config.env.example" ]]; then
    cp "$SCRIPT_DIR/config.env.example" "$CONFIG_FILE"
    step "created $CONFIG_FILE from config.env.example"
    step "edit account slots, proxy, priorities, and quota thresholds before production use"
    return
  fi
  die "config file not found: $CONFIG_FILE"
}

yaml_config_exports() {
  local file="$1"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to load YAML config: $file"
  YAML_CONFIG_FILE="$file" python3 - <<'PY'
import ast
import os
import re
import shlex
import sys

path = os.environ["YAML_CONFIG_FILE"]

def strip_comment(line):
    quote = None
    escaped = False
    for i, ch in enumerate(line):
        if escaped:
            escaped = False
            continue
        if ch == "\\" and quote == '"':
            escaped = True
            continue
        if ch in ("'", '"'):
            if quote == ch:
                quote = None
            elif quote is None:
                quote = ch
            continue
        if ch == "#" and quote is None:
            if i == 0 or line[i - 1].isspace():
                return line[:i]
    return line

def parse_scalar(raw):
    value = raw.strip()
    if value in ("", '""', "''", "null", "Null", "NULL", "~"):
        return ""
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return ""
        try:
            parsed = ast.literal_eval(value)
            if isinstance(parsed, list):
                return ",".join(str(item) for item in parsed)
        except Exception:
            pass
        return ",".join(item.strip().strip("'\"") for item in inner.split(",") if item.strip())
    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith("'") and value.endswith("'")
    ):
        try:
            return str(ast.literal_eval(value))
        except Exception:
            return value[1:-1]
    lowered = value.lower()
    if lowered in ("true", "yes", "on"):
        return "1"
    if lowered in ("false", "no", "off"):
        return "0"
    return value

def norm_key(value):
    return re.sub(r"[^a-z0-9]", "", value.lower())

def suffix(slot):
    return re.sub(r"[^A-Z0-9_]", "_", slot.upper().replace("-", "_"))

mapping = {
    ("gateway", "webport"): "REMOTE_GATEWAY_WEB_PORT",
    ("gateway", "publicbaseurl"): "REMOTE_GATEWAY_PUBLIC_BASE_URL",
    ("gateway", "bindaddr"): "REMOTE_GATEWAY_BIND_ADDR",
    ("gateway", "datadir"): "REMOTE_GATEWAY_DATA_DIR",
    ("gateway", "servicebin"): "REMOTE_GATEWAY_SERVICE_BIN",
    ("gateway", "buildproxyurl"): "REMOTE_GATEWAY_BUILD_PROXY_URL",
    ("gateway", "forcebuild"): "REMOTE_GATEWAY_FORCE_BUILD",
    ("gateway", "upstreamproxyurl"): "CODEXMANAGER_UPSTREAM_PROXY_URL",
    ("gateway", "proxylist"): "CODEXMANAGER_PROXY_LIST",
    ("accounts", "loginaccount"): "REMOTE_GATEWAY_LOGIN_ACCOUNT",
    ("accounts", "applyconfigafterlogin"): "REMOTE_GATEWAY_APPLY_CONFIG_AFTER_LOGIN",
    ("routing", "strategy"): "CODEXMANAGER_ROUTE_STRATEGY",
    ("quotaguard", "enabled"): "CODEXMANAGER_QUOTA_GUARD_ENABLED",
    ("quotaguard", "primaryminremainingpercent"): "CODEXMANAGER_QUOTA_GUARD_5H_MIN_REMAINING_PERCENT",
    ("quotaguard", "weeklyminremainingpercent"): "CODEXMANAGER_QUOTA_GUARD_WEEKLY_MIN_REMAINING_PERCENT",
    ("quotaguard", "secondaryminremainingpercent"): "CODEXMANAGER_QUOTA_GUARD_WEEKLY_MIN_REMAINING_PERCENT",
    ("quotaguard", "allowalllowfallback"): "CODEXMANAGER_QUOTA_GUARD_ALLOW_ALL_LOW_FALLBACK",
    ("background", "usagepollingenabled"): "CODEXMANAGER_USAGE_POLLING_ENABLED",
    ("background", "usagepollintervalsecs"): "CODEXMANAGER_USAGE_POLL_INTERVAL_SECS",
    ("background", "tokenrefreshpollingenabled"): "CODEXMANAGER_TOKEN_REFRESH_POLLING_ENABLED",
    ("background", "tokenrefreshpollintervalsecs"): "CODEXMANAGER_TOKEN_REFRESH_POLL_INTERVAL_SECS",
    ("background", "gatewaykeepaliveenabled"): "CODEXMANAGER_GATEWAY_KEEPALIVE_ENABLED",
    ("background", "gatewaykeepaliveintervalsecs"): "CODEXMANAGER_GATEWAY_KEEPALIVE_INTERVAL_SECS",
    ("timeouts", "upstreamtotaltimeoutms"): "CODEXMANAGER_UPSTREAM_TOTAL_TIMEOUT_MS",
    ("timeouts", "upstreamstreamtimeoutms"): "CODEXMANAGER_UPSTREAM_STREAM_TIMEOUT_MS",
    ("timeouts", "ssekeepaliveintervalms"): "CODEXMANAGER_SSE_KEEPALIVE_INTERVAL_MS",
    ("logging", "gatewaytracestdout"): "CODEXMANAGER_GATEWAY_TRACE_STDOUT",
    ("logging", "gatewayerrorstdout"): "CODEXMANAGER_GATEWAY_ERROR_STDOUT",
    ("logging", "gatewaytracestdoutslowms"): "CODEXMANAGER_GATEWAY_TRACE_STDOUT_SLOW_MS",
    ("login", "timeoutsecs"): "REMOTE_GATEWAY_LOGIN_TIMEOUT_SECS",
    ("login", "pollsecs"): "REMOTE_GATEWAY_LOGIN_POLL_SECS",
    ("apikey", "name"): "REMOTE_GATEWAY_API_KEY_NAME",
    ("apikey", "model"): "REMOTE_CODEX_MODEL",
    ("codexapp", "enabled"): "REMOTE_GATEWAY_CODEX_APP_CONFIGURE_ON_START",
    ("codexapp", "configure"): "REMOTE_GATEWAY_CODEX_APP_CONFIGURE_ON_START",
    ("codexapp", "configureprovider"): "REMOTE_GATEWAY_CODEX_APP_CONFIGURE_ON_START",
    ("codexapp", "configureprovideronstart"): "REMOTE_GATEWAY_CODEX_APP_CONFIGURE_ON_START",
    ("codexapp", "configpath"): "REMOTE_GATEWAY_CODEX_APP_CONFIG_PATH",
    ("codexapp", "keypath"): "REMOTE_GATEWAY_CODEX_APP_KEY_PATH",
    ("codexapp", "providerid"): "REMOTE_GATEWAY_CODEX_APP_PROVIDER_ID",
    ("codexapp", "providername"): "REMOTE_GATEWAY_CODEX_APP_PROVIDER_NAME",
    ("codexapp", "baseurl"): "REMOTE_GATEWAY_CODEX_APP_BASE_URL",
    ("codexapp", "wireapi"): "REMOTE_GATEWAY_CODEX_APP_WIRE_API",
    ("codexapp", "warmmodels"): "REMOTE_GATEWAY_CODEX_APP_WARM_MODELS",
    ("codexapp", "warmmodelsonstart"): "REMOTE_GATEWAY_CODEX_APP_WARM_MODELS",
    ("codexapp", "restartappserver"): "REMOTE_GATEWAY_CODEX_APP_RESTART_SERVER",
    ("codexapp", "restartserver"): "REMOTE_GATEWAY_CODEX_APP_RESTART_SERVER",
    ("rustup", "distserver"): "RUSTUP_DIST_SERVER",
    ("rustup", "updateroot"): "RUSTUP_UPDATE_ROOT",
    ("rustup", "initurl"): "RUSTUP_INIT_URL",
    ("cargo", "registrymirror"): "REMOTE_GATEWAY_CARGO_REGISTRY_MIRROR",
    ("cargo", "registryindex"): "REMOTE_GATEWAY_CARGO_REGISTRY_INDEX",
    ("cargo", "gitfetchwithcli"): "REMOTE_GATEWAY_CARGO_GIT_FETCH_WITH_CLI",
    ("cargo", "httpmultiplexing"): "REMOTE_GATEWAY_CARGO_HTTP_MULTIPLEXING",
}

slot_field_mapping = {
    "id": "ID",
    "tags": "TAGS",
    "tag": "TAG",
    "note": "NOTE",
    "priority": "PRIORITY",
    "sort": "SORT",
    "group": "GROUP",
    "groupname": "GROUP",
    "workspaceid": "WORKSPACE_ID",
    "label": "LABEL",
}

exports = {}
slot_order = []
explicit_account_order = None
stack = []

try:
    lines = open(path, "r", encoding="utf-8").read().splitlines()
except OSError as exc:
    print(f"read yaml config failed: {exc}", file=sys.stderr)
    raise SystemExit(1)

for line_number, original in enumerate(lines, 1):
    if "\t" in original[: len(original) - len(original.lstrip("\t "))]:
        print(f"{path}:{line_number}: tabs are not supported in indentation", file=sys.stderr)
        raise SystemExit(1)
    stripped = strip_comment(original).rstrip()
    if not stripped.strip():
        continue
    indent = len(stripped) - len(stripped.lstrip(" "))
    text = stripped.strip()
    if text.startswith("- "):
        print(f"{path}:{line_number}: list items are not supported; use bracket lists", file=sys.stderr)
        raise SystemExit(1)
    if ":" not in text:
        print(f"{path}:{line_number}: expected key: value", file=sys.stderr)
        raise SystemExit(1)
    key, raw_value = text.split(":", 1)
    key = key.strip()
    if not key:
        print(f"{path}:{line_number}: empty key", file=sys.stderr)
        raise SystemExit(1)
    while stack and indent <= stack[-1][0]:
        stack.pop()
    key_path = [item[1] for item in stack] + [key]
    value = raw_value.strip()
    if not value:
        stack.append((indent, key))
        if len(key_path) == 3 and norm_key(key_path[0]) == "accounts" and norm_key(key_path[1]) == "slots":
            if key not in slot_order:
                slot_order.append(key)
        continue

    normalized_path = tuple(norm_key(item) for item in key_path)
    parsed = parse_scalar(value)
    if normalized_path == ("accounts", "order"):
        explicit_account_order = parsed
        continue
    env_name = mapping.get(normalized_path)
    if env_name:
        exports[env_name] = parsed
        continue
    if (
        len(key_path) == 4
        and norm_key(key_path[0]) == "accounts"
        and norm_key(key_path[1]) == "slots"
    ):
        slot = key_path[2]
        field = slot_field_mapping.get(norm_key(key_path[3]))
        if field:
            if slot not in slot_order:
                slot_order.append(slot)
            exports[f"REMOTE_GATEWAY_ACCOUNT_{suffix(slot)}_{field}"] = parsed

if explicit_account_order is not None:
    exports["REMOTE_GATEWAY_ACCOUNTS"] = explicit_account_order
elif slot_order:
    exports["REMOTE_GATEWAY_ACCOUNTS"] = ",".join(slot_order)

for key in sorted(exports):
    print(f"export {key}={shlex.quote(str(exports[key]))}")
PY
}

load_config() {
  ensure_config_file
  local preserved_names=()
  local preserved_values=()
  local name
  while IFS= read -r name; do
    case "$name" in
      CODEXMANAGER_*|REMOTE_GATEWAY_*|REMOTE_CODEX_*|MANAGER_*|RUSTUP_*|CARGO_*|TZ|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy|NO_PROXY|no_proxy)
        preserved_names+=("$name")
        preserved_values+=("${!name}")
        ;;
    esac
  done < <(compgen -e)

  case "$CONFIG_FILE" in
    *.yaml|*.yml|*.yaml.example|*.yml.example)
      eval "$(yaml_config_exports "$CONFIG_FILE")"
      ;;
    *)
      set -a
      # shellcheck source=/dev/null
      . "$CONFIG_FILE"
      set +a
      ;;
  esac

  local i
  for i in "${!preserved_names[@]}"; do
    export "${preserved_names[$i]}=${preserved_values[$i]}"
  done
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_build_env() {
  local proxy="${REMOTE_GATEWAY_BUILD_PROXY_URL:-}"
  if [[ -n "$proxy" ]]; then
    export HTTP_PROXY="${HTTP_PROXY:-$proxy}"
    export HTTPS_PROXY="${HTTPS_PROXY:-$proxy}"
    export http_proxy="${http_proxy:-$proxy}"
    export https_proxy="${https_proxy:-$proxy}"
    export CARGO_HTTP_PROXY="${CARGO_HTTP_PROXY:-$proxy}"
  fi

  configure_cargo_registry_mirror
}

configure_cargo_registry_mirror() {
  local mirror="${REMOTE_GATEWAY_CARGO_REGISTRY_MIRROR:-}"
  local index="${REMOTE_GATEWAY_CARGO_REGISTRY_INDEX:-}"
  local source_name source_registry

  case "$(printf '%s' "$mirror" | tr '[:upper:]' '[:lower:]')" in
    ""|none|off|false|0)
      if [[ -z "$index" ]]; then
        return 0
      fi
      source_name="remote_gateway"
      source_registry="$index"
      ;;
    rsproxy)
      source_name="rsproxy"
      source_registry="sparse+https://rsproxy.cn/index/"
      ;;
    ustc)
      source_name="ustc"
      source_registry="sparse+https://mirrors.ustc.edu.cn/crates.io-index/"
      ;;
    *)
      die "unsupported cargo registry mirror: $mirror (use rsproxy, ustc, or cargo.registryIndex)"
      ;;
  esac

  export CARGO_REGISTRIES_CRATES_IO_PROTOCOL="${CARGO_REGISTRIES_CRATES_IO_PROTOCOL:-sparse}"
  export CARGO_SOURCE_CRATES_IO_REPLACE_WITH="${CARGO_SOURCE_CRATES_IO_REPLACE_WITH:-$source_name}"
  case "$source_name" in
    rsproxy) export CARGO_SOURCE_RSPROXY_REGISTRY="${CARGO_SOURCE_RSPROXY_REGISTRY:-$source_registry}" ;;
    ustc) export CARGO_SOURCE_USTC_REGISTRY="${CARGO_SOURCE_USTC_REGISTRY:-$source_registry}" ;;
    remote_gateway) export CARGO_SOURCE_REMOTE_GATEWAY_REGISTRY="${CARGO_SOURCE_REMOTE_GATEWAY_REGISTRY:-$source_registry}" ;;
  esac
  export CARGO_NET_GIT_FETCH_WITH_CLI="$(cargo_bool_value "${REMOTE_GATEWAY_CARGO_GIT_FETCH_WITH_CLI:-${CARGO_NET_GIT_FETCH_WITH_CLI:-true}}" true)"
  if [[ -n "${REMOTE_GATEWAY_CARGO_HTTP_MULTIPLEXING:-${CARGO_HTTP_MULTIPLEXING:-}}" ]]; then
    export CARGO_HTTP_MULTIPLEXING="$(cargo_bool_value "${REMOTE_GATEWAY_CARGO_HTTP_MULTIPLEXING:-$CARGO_HTTP_MULTIPLEXING}" true)"
  fi
}

cargo_bool_value() {
  local raw="${1:-}"
  local fallback="${2:-true}"
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) printf 'true' ;;
    0|false|no|off) printf 'false' ;;
    *) printf '%s' "$fallback" ;;
  esac
}

cargo_home_dir() {
  if [[ -n "${CARGO_HOME:-}" ]]; then
    printf '%s' "$CARGO_HOME"
    return
  fi
  [[ -n "${HOME:-}" ]] || return 1
  printf '%s/.cargo' "$HOME"
}

ensure_cargo_path() {
  local cargo_home cargo_bin
  cargo_home="$(cargo_home_dir)" || return 0
  cargo_bin="$cargo_home/bin"
  if [[ -x "$cargo_bin/cargo" || -x "$cargo_bin/rustup" ]]; then
    case ":$PATH:" in
      *":$cargo_bin:"*) ;;
      *) export PATH="$cargo_bin:$PATH" ;;
    esac
  fi
}

rustup_init_triple() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os:$arch" in
    Linux:x86_64|Linux:amd64) printf 'x86_64-unknown-linux-gnu' ;;
    Linux:aarch64|Linux:arm64) printf 'aarch64-unknown-linux-gnu' ;;
    Darwin:x86_64|Darwin:amd64) printf 'x86_64-apple-darwin' ;;
    Darwin:aarch64|Darwin:arm64) printf 'aarch64-apple-darwin' ;;
    *) die "unsupported platform for rustup-init: $os $arch" ;;
  esac
}

download_with_progress() {
  local url="$1"
  local output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -fL --progress-bar -o "$output" "$url"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    local wget_help
    wget_help="$(wget --help 2>&1 || true)"
    if [[ "$wget_help" == *"--progress"* ]]; then
      wget --progress=bar:force:noscroll -O "$output" "$url"
    else
      wget -O "$output" "$url"
    fi
    return
  fi
  die "curl or wget is required to download Rust/Cargo"
}

install_rustup_init() {
  local triple dist_server url tmp_dir init
  triple="$(rustup_init_triple)"
  dist_server="${RUSTUP_DIST_SERVER:-https://static.rust-lang.org}"
  url="${RUSTUP_INIT_URL:-${dist_server%/}/rustup/dist/$triple/rustup-init}"
  tmp_dir="${TMPDIR:-/tmp}/remote-codex-rustup-$$"
  init="$tmp_dir/rustup-init"

  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"
  trap 'rm -rf "$tmp_dir"; trap - RETURN' RETURN

  step "downloading rustup-init for $triple"
  step "url: $url"
  download_with_progress "$url" "$init"
  chmod +x "$init"

  step "running rustup-init"
  "$init" -y --profile minimal --default-toolchain stable
}

normalize_runtime_env() {
  local data_dir="${REMOTE_GATEWAY_DATA_DIR:-$SCRIPT_DIR/data}"
  local port="${REMOTE_GATEWAY_WEB_PORT:-${REMOTE_GATEWAY_PORT:-48761}}"
  mkdir -p "$data_dir" "$SCRIPT_DIR/logs"

  export REMOTE_GATEWAY_WEB_PORT="$port"
  export CODEXMANAGER_SERVICE_ADDR="${REMOTE_GATEWAY_BIND_ADDR:-0.0.0.0:$port}"
  export CODEXMANAGER_DB_PATH="${CODEXMANAGER_DB_PATH:-$data_dir/codexmanager.db}"
  export CODEXMANAGER_RPC_TOKEN_FILE="${CODEXMANAGER_RPC_TOKEN_FILE:-$data_dir/codexmanager.rpc-token}"
  export CODEXMANAGER_ROUTE_STRATEGY="${CODEXMANAGER_ROUTE_STRATEGY:-ordered}"

  export CODEXMANAGER_QUOTA_GUARD_ENABLED="${CODEXMANAGER_QUOTA_GUARD_ENABLED:-1}"
  if [[ -n "${CODEXMANAGER_QUOTA_MIN_REMAINING_PERCENT:-}" ]]; then
    export CODEXMANAGER_QUOTA_GUARD_5H_MIN_REMAINING_PERCENT="${CODEXMANAGER_QUOTA_GUARD_5H_MIN_REMAINING_PERCENT:-$CODEXMANAGER_QUOTA_MIN_REMAINING_PERCENT}"
    export CODEXMANAGER_QUOTA_GUARD_WEEKLY_MIN_REMAINING_PERCENT="${CODEXMANAGER_QUOTA_GUARD_WEEKLY_MIN_REMAINING_PERCENT:-$CODEXMANAGER_QUOTA_MIN_REMAINING_PERCENT}"
  fi
  export CODEXMANAGER_QUOTA_GUARD_5H_MIN_REMAINING_PERCENT="${CODEXMANAGER_QUOTA_GUARD_5H_MIN_REMAINING_PERCENT:-5}"
  export CODEXMANAGER_QUOTA_GUARD_WEEKLY_MIN_REMAINING_PERCENT="${CODEXMANAGER_QUOTA_GUARD_WEEKLY_MIN_REMAINING_PERCENT:-10}"
  export CODEXMANAGER_QUOTA_GUARD_ALLOW_ALL_LOW_FALLBACK="${CODEXMANAGER_QUOTA_GUARD_ALLOW_ALL_LOW_FALLBACK:-1}"

  export CODEXMANAGER_USAGE_POLLING_ENABLED="${CODEXMANAGER_USAGE_POLLING_ENABLED:-1}"
  export CODEXMANAGER_USAGE_POLL_INTERVAL_SECS="${CODEXMANAGER_USAGE_POLL_INTERVAL_SECS:-300}"
  export CODEXMANAGER_TOKEN_REFRESH_POLLING_ENABLED="${CODEXMANAGER_TOKEN_REFRESH_POLLING_ENABLED:-1}"
  export CODEXMANAGER_TOKEN_REFRESH_POLL_INTERVAL_SECS="${CODEXMANAGER_TOKEN_REFRESH_POLL_INTERVAL_SECS:-300}"
  export CODEXMANAGER_GATEWAY_KEEPALIVE_ENABLED="${CODEXMANAGER_GATEWAY_KEEPALIVE_ENABLED:-1}"
  export CODEXMANAGER_GATEWAY_KEEPALIVE_INTERVAL_SECS="${CODEXMANAGER_GATEWAY_KEEPALIVE_INTERVAL_SECS:-180}"

  export CODEXMANAGER_UPSTREAM_TOTAL_TIMEOUT_MS="${CODEXMANAGER_UPSTREAM_TOTAL_TIMEOUT_MS:-0}"
  export CODEXMANAGER_UPSTREAM_STREAM_TIMEOUT_MS="${CODEXMANAGER_UPSTREAM_STREAM_TIMEOUT_MS:-600000}"
  export CODEXMANAGER_SSE_KEEPALIVE_INTERVAL_MS="${CODEXMANAGER_SSE_KEEPALIVE_INTERVAL_MS:-15000}"
  export CODEXMANAGER_GATEWAY_TRACE_STDOUT="${CODEXMANAGER_GATEWAY_TRACE_STDOUT:-1}"
  export CODEXMANAGER_GATEWAY_ERROR_STDOUT="${CODEXMANAGER_GATEWAY_ERROR_STDOUT:-1}"

  if [[ -n "${MANAGER_UPSTREAM_PROXY_URL:-}" && -z "${CODEXMANAGER_UPSTREAM_PROXY_URL:-}" ]]; then
    export CODEXMANAGER_UPSTREAM_PROXY_URL="$MANAGER_UPSTREAM_PROXY_URL"
  fi
  if [[ -n "${MANAGER_PROXY_LIST:-}" && -z "${CODEXMANAGER_PROXY_LIST:-}" ]]; then
    export CODEXMANAGER_PROXY_LIST="$MANAGER_PROXY_LIST"
  fi
}

split_words() {
  printf '%s\n' "${1:-}" | tr ',;' '  ' | tr '\n' ' '
}

tag_list_contains() {
  local haystack="$1"
  local needle="$2"
  local item
  for item in $(split_words "$haystack"); do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

append_tag_once() {
  local tags="$1"
  local tag="$2"
  if [[ -z "$tag" ]] || tag_list_contains "$tags" "$tag"; then
    printf '%s' "$tags"
    return
  fi
  if [[ -z "$tags" ]]; then
    printf '%s' "$tag"
  else
    printf '%s,%s' "$tags" "$tag"
  fi
}

account_env_suffix() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_' | sed 's/[^A-Z0-9_]/_/g'
}

account_config_value() {
  local slot="$1"
  local field="$2"
  local suffix var
  suffix="$(account_env_suffix "$slot")"
  var="REMOTE_GATEWAY_ACCOUNT_${suffix}_${field}"
  printf '%s' "${!var:-}"
}

configured_account_slots() {
  split_words "${REMOTE_GATEWAY_ACCOUNTS:-}"
}

resolve_account_slot() {
  if [[ -n "$ACCOUNT_SLOT" ]]; then
    printf '%s' "$ACCOUNT_SLOT"
    return
  fi
  if [[ -n "${REMOTE_GATEWAY_LOGIN_ACCOUNT:-}" ]]; then
    printf '%s' "$REMOTE_GATEWAY_LOGIN_ACCOUNT"
    return
  fi

  local slots=()
  local slot
  for slot in $(configured_account_slots); do
    [[ -n "$slot" ]] && slots+=("$slot")
  done
  if [[ "${#slots[@]}" -eq 1 ]]; then
    printf '%s' "${slots[0]}"
    return
  fi
  if [[ "${#slots[@]}" -gt 1 ]]; then
    die "multiple account slots configured; pass login <account> or set REMOTE_GATEWAY_LOGIN_ACCOUNT"
  fi
  printf 'default'
}

native_pid_file() {
  local data_dir="${REMOTE_GATEWAY_DATA_DIR:-$SCRIPT_DIR/data}"
  printf '%s/codexmanager-service.pid' "$data_dir"
}

native_log_file() {
  printf '%s/native-gateway.log' "$SCRIPT_DIR/logs"
}

service_curl() {
  local url="$1"
  shift
  case "$url" in
    http://127.0.0.1:*|http://localhost:*|http://[::1]:*|https://127.0.0.1:*|https://localhost:*|https://[::1]:*)
      curl --noproxy '*' "$@" "$url"
      ;;
    *)
      curl "$@" "$url"
      ;;
  esac
}

platform_id() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    amd64) arch="x86_64" ;;
    arm64) arch="aarch64" ;;
  esac
  printf '%s-%s' "$os" "$arch"
}

normalize_binary_path() {
  local path="$1"
  case "$path" in
    /*) printf '%s' "$path" ;;
    *)
      if [[ -e "$SCRIPT_DIR/$path" ]]; then
        printf '%s/%s' "$SCRIPT_DIR" "$path"
      else
        printf '%s/%s' "$ROOT" "$path"
      fi
      ;;
  esac
}

use_if_executable() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  if [[ ! -x "$path" ]]; then
    chmod +x "$path" 2>/dev/null || true
  fi
  [[ -x "$path" ]] || return 1
  printf '%s' "$path"
}

prebuilt_binary_hint() {
  cat >&2 <<EOF
[remote-gateway] error: no runnable codexmanager-service binary was found, and cargo is not installed.

Expected one of:
  ${SCRIPT_DIR}/bin/$(platform_id)/codexmanager-service
  ${SCRIPT_DIR}/bin/codexmanager-service
  ${ROOT}/target/release/codexmanager-service

Fix:
  1. To build on this server, run:
       remote-codex-gateway install-rust
       remote-codex-gateway start
  2. Or on a compatible Linux build machine, run:
       ./deploy/remote-codex-gateway/build-binary.sh
  3. Commit or copy deploy/remote-codex-gateway/bin/codexmanager-service to this server.

You can also set REMOTE_GATEWAY_SERVICE_BIN=/absolute/path/to/codexmanager-service.
EOF
  exit 1
}

resolve_gateway_binary() {
  local override="${REMOTE_GATEWAY_SERVICE_BIN:-}"
  if [[ -n "$override" ]]; then
    override="$(normalize_binary_path "$override")"
    use_if_executable "$override" || die "REMOTE_GATEWAY_SERVICE_BIN is not executable: $override"
    return
  fi

  if [[ "${REMOTE_GATEWAY_FORCE_BUILD:-0}" == "1" ]]; then
    return 1
  fi

  local candidate
  for candidate in \
    "$SCRIPT_DIR/bin/$(platform_id)/codexmanager-service" \
    "$SCRIPT_DIR/bin/codexmanager-service" \
    "$ROOT/target/release/codexmanager-service" \
    "$ROOT/target/debug/codexmanager-service"
  do
    if use_if_executable "$candidate"; then
      return
    fi
  done

  return 1
}

install_rust_toolchain() {
  local cargo_home rustup_home
  cargo_home="$(cargo_home_dir)" || die "HOME or CARGO_HOME is required to install Rust/Cargo"
  rustup_home="${RUSTUP_HOME:-}"
  if [[ -z "$rustup_home" ]]; then
    [[ -n "${HOME:-}" ]] || die "HOME or RUSTUP_HOME is required to install Rust/Cargo"
    rustup_home="$HOME/.rustup"
  fi
  export CARGO_HOME="$cargo_home"
  export RUSTUP_HOME="$rustup_home"
  export PATH="$cargo_home/bin:$PATH"

  ensure_cargo_path
  if command -v cargo >/dev/null 2>&1 && cargo --version >/dev/null 2>&1; then
    step "cargo already installed: $(command -v cargo)"
    cargo --version
    return
  fi

  if command -v rustup >/dev/null 2>&1; then
    step "installing stable Rust toolchain with existing rustup"
    rustup toolchain install stable --profile minimal
    rustup default stable
  else
    step "installing Rust/Cargo with rustup"
    install_rustup_init
  fi

  ensure_cargo_path
  command -v cargo >/dev/null 2>&1 || die "Rust/Cargo install finished, but cargo is still not on PATH"
  step "installed Rust/Cargo: $(cargo --version)"
  step "cargo bin: $cargo_home/bin"
  step "next: remote-codex-gateway start"
}

native_pid_running() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(tr -d '[:space:]' <"$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

wait_native_health() {
  command -v curl >/dev/null 2>&1 || return 0
  local url="http://127.0.0.1:${REMOTE_GATEWAY_WEB_PORT:-48761}/health"
  local waited=0
  while (( waited < 30 )); do
    if service_curl "$url" -fsS >/dev/null 2>&1; then
      step "gateway health ok"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  warn "gateway did not pass health check yet; check log: $(native_log_file)"
  return 1
}

start_gateway() {
  normalize_runtime_env

  local pid_file
  pid_file="$(native_pid_file)"
  if [[ "$BACKGROUND" == "true" ]] && native_pid_running "$pid_file"; then
    step "gateway already running (pid $(tr -d '[:space:]' <"$pid_file"))"
    if wait_native_health; then
      configure_codex_app_provider_after_start
    fi
    return
  fi

  local release_bin="$ROOT/target/release/codexmanager-service"
  local bin=""
  if bin="$(resolve_gateway_binary)"; then
    :
  fi

  if [[ -z "$bin" ]]; then
    ensure_cargo_path
    command -v cargo >/dev/null 2>&1 || prebuilt_binary_hint
    normalize_build_env
    step "building native gateway service"
    cargo build --locked --release -p codexmanager-service
    [[ -x "$release_bin" ]] || die "gateway binary not found after build: $release_bin"
    bin="$release_bin"
  fi

  step "starting gateway on ${CODEXMANAGER_SERVICE_ADDR}"
  if [[ "$BACKGROUND" != "true" ]]; then
    if truthy "${REMOTE_GATEWAY_CODEX_APP_CONFIGURE_ON_START:-0}"; then
      warn "Codex App provider config is applied after background start; run without --foreground once to apply it"
    fi
    exec "$bin"
  fi

  local log_file
  log_file="$(native_log_file)"
  mkdir -p "$(dirname "$pid_file")" "$(dirname "$log_file")"
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "$bin" >>"$log_file" 2>&1 </dev/null &
  else
    nohup "$bin" >>"$log_file" 2>&1 </dev/null &
  fi
  local pid="$!"
  printf '%s\n' "$pid" >"$pid_file"
  step "gateway started in background (pid $pid)"
  step "log: $log_file"
  if wait_native_health; then
    configure_codex_app_provider_after_start
  fi
}

stop_gateway() {
  normalize_runtime_env
  local pid_file
  pid_file="$(native_pid_file)"
  if ! native_pid_running "$pid_file"; then
    rm -f "$pid_file"
    step "gateway is not running"
    return
  fi
  local pid
  pid="$(tr -d '[:space:]' <"$pid_file")"
  step "stopping gateway (pid $pid)"
  kill "$pid"
  local waited=0
  while kill -0 "$pid" >/dev/null 2>&1 && (( waited < 20 )); do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" >/dev/null 2>&1; then
    die "gateway did not stop after ${waited}s"
  fi
  rm -f "$pid_file"
  step "gateway stopped"
}

gateway_status() {
  normalize_runtime_env
  local pid_file
  pid_file="$(native_pid_file)"
  if native_pid_running "$pid_file"; then
    step "gateway is running (pid $(tr -d '[:space:]' <"$pid_file"))"
    step "log: $(native_log_file)"
  else
    step "gateway is not running"
  fi
}

health_check() {
  normalize_runtime_env
  local url="http://127.0.0.1:${REMOTE_GATEWAY_WEB_PORT}/health"
  step "checking $url"
  service_curl "$url" -fsS >/dev/null
  step "health ok"
}

dashboard_base_url() {
  local raw="${REMOTE_GATEWAY_PUBLIC_BASE_URL:-}"
  if [[ -z "$raw" ]]; then
    raw="http://127.0.0.1:${REMOTE_GATEWAY_WEB_PORT:-48761}"
  fi
  raw="${raw%/}"
  case "$raw" in
    */v1) raw="${raw%/v1}" ;;
    */rpc) raw="${raw%/rpc}" ;;
  esac
  printf '%s' "$raw"
}

dashboard_cli() {
  normalize_runtime_env
  local token base_url
  token="$(read_rpc_token)"
  base_url="$(dashboard_base_url)"
  step "dashboard: ${base_url}/dashboard#rpcToken=${token}"
  step "the token is stored in the URL hash; the page clears it after loading"
}

rpc_url() {
  if [[ -n "${REMOTE_GATEWAY_SERVICE_RPC_URL:-}" ]]; then
    local raw="${REMOTE_GATEWAY_SERVICE_RPC_URL%/}"
    case "$raw" in
      */rpc) printf '%s' "$raw" ;;
      *) printf '%s/rpc' "$raw" ;;
    esac
    return
  fi
  printf 'http://127.0.0.1:%s/rpc' "${REMOTE_GATEWAY_WEB_PORT:-48761}"
}

rpc_token_file_for_host() {
  local raw="${REMOTE_GATEWAY_RPC_TOKEN_FILE:-${CODEXMANAGER_RPC_TOKEN_FILE:-}}"
  if [[ -z "$raw" ]]; then
    raw="$SCRIPT_DIR/data/codexmanager.rpc-token"
  fi
  case "$raw" in
    /*) printf '%s' "$raw" ;;
    *) printf '%s/%s' "$SCRIPT_DIR" "$raw" ;;
  esac
}

read_rpc_token() {
  if [[ -n "${CODEXMANAGER_RPC_TOKEN:-}" ]]; then
    printf '%s' "$CODEXMANAGER_RPC_TOKEN"
    return
  fi

  local token_file
  token_file="$(rpc_token_file_for_host)"
  [[ -f "$token_file" ]] || die "RPC token file not found: $token_file. Start the gateway first."

  local token
  token="$(tr -d '\r\n' <"$token_file")"
  [[ -n "$token" ]] || die "RPC token file is empty: $token_file"
  printf '%s' "$token"
}

require_json_reader() {
  if command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    return
  fi
  die "jq or python3 is required"
}

json_get() {
  local json="$1"
  local path="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r ".$path // empty"
    return
  fi
  JSON_DOC="$json" JSON_PATH="$path" python3 - <<'PY'
import json
import os

try:
    value = json.loads(os.environ.get("JSON_DOC", ""))
except Exception:
    raise SystemExit(0)

for part in os.environ.get("JSON_PATH", "").split("."):
    if not part:
        continue
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
    if value is None:
        break

if value is None:
    raise SystemExit(0)
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

json_get_first() {
  local json="$1"
  shift
  local path value
  for path in "$@"; do
    value="$(json_get "$json" "$path")"
    if [[ -n "$value" && "$value" != "null" ]]; then
      printf '%s' "$value"
      return
    fi
  done
}

json_quote() {
  local value="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -Rn --arg v "$value" '$v'
    return
  fi
  JSON_VALUE="$value" python3 - <<'PY'
import json
import os

print(json.dumps(os.environ.get("JSON_VALUE", "")))
PY
}

rpc_call() {
  local method="$1"
  local params="$2"
  local url token
  url="$(rpc_url)"
  if ! token="$(read_rpc_token)"; then
    return 1
  fi
  service_curl "$url" -fsS \
    -H 'content-type: application/json' \
    -H "x-codexmanager-rpc-token: $token" \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}"
}

rpc_error_message() {
  json_get_first "$1" "error.message" "result.error" "result.message"
}

require_rpc_cli() {
  normalize_runtime_env
  command -v curl >/dev/null 2>&1 || die "curl not found"
  require_json_reader
}

require_python3() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
}

validate_account_name() {
  local value="$1"
  [[ -n "$value" ]] || die "account name is required"
  [[ "${#value}" -le 64 ]] || die "account name is too long; use 64 characters or fewer"
  [[ "$value" != -* ]] || die "account name cannot start with '-'"
  if [[ "$value" =~ [[:space:],\;] ]]; then
    die "account name cannot contain spaces, commas, or semicolons"
  fi
}

resolve_account_ref() {
  local ref="$1"
  [[ -n "$ref" ]] || die "missing account id, tag, or label"
  require_python3

  local list_resp error account_id
  list_resp="$(rpc_call "account/list" '{}')" || die "account list request failed"
  error="$(rpc_error_message "$list_resp")"
  [[ -z "$error" ]] || die "account list failed: $error"

  account_id="$(ACCOUNT_LIST_JSON="$list_resp" ACCOUNT_REF="$ref" python3 - <<'PY'
import json
import os
import re
import sys

ref = os.environ.get("ACCOUNT_REF", "").strip()
payload = json.loads(os.environ.get("ACCOUNT_LIST_JSON", "{}"))
items = payload.get("result", {}).get("items", [])

def words(value):
    return [item for item in re.split(r"[\s,;]+", str(value or "").strip()) if item]

def short_id(value):
    text = str(value or "-")
    if len(text) <= 18:
        return text
    return f"{text[:8]}...{text[-6:]}"

def describe(item):
    label = item.get("label") or "-"
    tags = item.get("tags") or "-"
    name = label
    if "@" in name or "::" in name or name.startswith("auth0|"):
        tag_words = words(tags)
        name = tag_words[0] if tag_words else short_id(item.get("id"))
    return f"name={name}\tid={short_id(item.get('id'))}\tlabel={label}\ttags={tags}"

exact_id = [item for item in items if item.get("id") == ref]
if len(exact_id) == 1:
    print(exact_id[0]["id"])
    raise SystemExit(0)

matches = []
for item in items:
    tags = set(words(item.get("tags")))
    if ref in tags or item.get("label") == ref or item.get("note") == ref:
        matches.append(item)

if not matches:
    prefix = [item for item in items if str(item.get("id") or "").startswith(ref)]
    if len(prefix) == 1:
        print(prefix[0]["id"])
        raise SystemExit(0)
    matches = prefix

if len(matches) == 1:
    print(matches[0]["id"])
    raise SystemExit(0)

if not matches:
    print(f"account not found: {ref}", file=sys.stderr)
else:
    print(f"ambiguous account reference: {ref}", file=sys.stderr)
    for item in matches:
        print(f"  {describe(item)}", file=sys.stderr)
raise SystemExit(1)
PY
)" || die "could not resolve account: $ref"
  [[ -n "$account_id" ]] || die "could not resolve account: $ref"
  printf '%s' "$account_id"
}

print_accounts_table() {
  local accounts_resp="$1"
  local usage_resp="$2"
  ACCOUNT_LIST_JSON="$accounts_resp" USAGE_LIST_JSON="$usage_resp" SHOW_ACCOUNT_IDS="$SHOW_ACCOUNT_IDS" python3 - <<'PY'
import json
import os
import re
import sys
import time

accounts_payload = json.loads(os.environ.get("ACCOUNT_LIST_JSON", "{}"))
usage_payload = json.loads(os.environ.get("USAGE_LIST_JSON", "{}"))
show_ids = os.environ.get("SHOW_ACCOUNT_IDS", "").lower() in ("1", "true", "yes", "on")
accounts = accounts_payload.get("result", {}).get("items", [])
usage_items = usage_payload.get("result", {}).get("items", [])
usage_by_account = {item.get("accountId"): item for item in usage_items if item.get("accountId")}
ANSI_RE = re.compile(r"\033\[[0-9;]*m")

def visible_len(value):
    return len(ANSI_RE.sub("", str(value)))

def visible_ljust(value, width):
    text = str(value)
    return text + (" " * max(0, width - visible_len(text)))

def fmt_bool(value):
    return "yes" if value else "-"

def words(value):
    return [item for item in re.split(r"[\s,;]+", str(value or "").strip()) if item]

def pct(value):
    if value is None:
        return None
    try:
        return max(0.0, min(100.0, 100.0 - float(value)))
    except Exception:
        return None

def clipped(value, limit):
    text = str(value or "-")
    if len(text) <= limit:
        return text
    return text[: max(1, limit - 1)] + "~"

def short_id(account_id):
    text = str(account_id or "-")
    if len(text) <= 18:
        return text
    return f"{text[:8]}...{text[-6:]}"

def looks_generated(value):
    text = str(value or "").strip()
    if not text or "@" in text or "::" in text or text.startswith("auth0|"):
        return True
    if len(text) > 40 and re.search(r"[0-9a-fA-F]{8}-[0-9a-fA-F-]{20,}", text):
        return True
    return False

def account_name(item):
    label = item.get("label") or ""
    if not looks_generated(label):
        return label
    tag_words = words(item.get("tags"))
    if tag_words:
        return tag_words[0]
    note = item.get("note") or ""
    if note and len(note) <= 32 and not looks_generated(note):
        return note
    return short_id(item.get("id"))

def color_enabled():
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("FORCE_COLOR") in ("1", "true", "yes", "on"):
        return True
    return sys.stdout.isatty() and os.environ.get("TERM", "") != "dumb"

USE_COLOR = color_enabled()

def paint(value, code):
    if not USE_COLOR:
        return value
    return f"\033[{code}m{value}\033[0m"

def quota_state(remaining):
    if remaining is None:
        return ("unknown", "37")
    if remaining >= 50:
        return ("ok", "32")
    if remaining >= 20:
        return ("low", "33")
    return ("critical", "31")

def progress_bar(remaining, width=30):
    if remaining is None:
        return ("-" * width)
    filled = int(round((remaining / 100.0) * width))
    filled = max(0, min(width, filled))
    empty = width - filled
    _, color = quota_state(remaining)
    if USE_COLOR:
        filled_part = f"\033[{color};7m{' ' * filled}\033[0m" if filled else ""
        empty_part = f"\033[2m{' ' * empty}\033[0m" if empty else ""
    else:
        filled_part = "=" * filled
        empty_part = " " * empty
    return f"{filled_part}{empty_part}"

def quota_line(label, used_percent):
    remaining = pct(used_percent)
    state, color = quota_state(remaining)
    if remaining is None:
        percent = paint("unknown", color)
    else:
        percent = paint(f"{remaining:5.1f}% left", color)
    return [label, progress_bar(remaining), percent, paint(state, color)]

def age(ts):
    if not ts:
        return "-"
    delta = max(0, int(time.time()) - int(ts))
    if delta < 90:
        return f"{delta}s ago"
    minutes = delta // 60
    if minutes < 90:
        return f"{minutes}m ago"
    hours = minutes // 60
    if hours < 48:
        return f"{hours}h ago"
    return f"{hours // 24}d ago"

def plan_name(item):
    return item.get("planType") or item.get("subscriptionPlan") or "-"

def sort_key(item):
    try:
        sort = int(item.get("sort", 0))
    except Exception:
        sort = 0
    return (sort, str(item.get("label") or ""), str(item.get("id") or ""))

if not accounts:
    print("No accounts found.")
    raise SystemExit(0)

def status_badge(status):
    value = str(status or "-")
    lowered = value.lower()
    if lowered == "active":
        return paint(value, "32")
    if lowered in ("disabled", "banned", "inactive"):
        return paint(value, "31")
    return paint(value, "33")

def token_text(value):
    return paint("token yes", "32") if value else paint("token no", "31")

def meta_line(item, usage, tags):
    parts = [
        status_badge(item.get("status") or "-"),
        f"plan {plan_name(item)}",
        f"pri {item.get('sort', '-')}",
        token_text(item.get("hasToken")),
        f"updated {age(usage.get('capturedAt'))}",
    ]
    if tags:
        parts.append(f"tags {clipped(tags, 32)}")
    return "  ".join(parts)

def quota_display(values):
    label, bar_value, percent, state = values
    return (
        "  "
        + visible_ljust(label, 6)
        + "|"
        + visible_ljust(bar_value, 30)
        + "|  "
        + visible_ljust(percent, 12)
        + "  "
        + visible_ljust(state, 8)
    )

items = []
for item in sorted(accounts, key=sort_key):
    account_id = item.get("id") or "-"
    usage = usage_by_account.get(account_id, {})
    tags = ",".join(words(item.get("tags")))
    name = clipped(account_name(item), 32)
    if item.get("preferred"):
        name = f"{name} *"
    items.append({
        "name": name,
        "meta": meta_line(item, usage, tags),
        "id": account_id,
        "quota": [
            quota_line("5h", usage.get("usedPercent")),
            quota_line("week", usage.get("secondaryUsedPercent")),
        ],
    })

for index, item in enumerate(items):
    if index:
        print()
    print(paint(item["name"], "1"))
    print("  " + item["meta"])
    if show_ids:
        print("  id " + item["id"])
    for quota in item["quota"]:
        print(quota_display(quota))

active = sum(1 for item in accounts if (item.get("status") or "").lower() == "active")
disabled = sum(1 for item in accounts if (item.get("status") or "").lower() == "disabled")
print()
print(f"Accounts: {len(accounts)} total, {active} active, {disabled} disabled")
print("Use account name with refresh-quota/disable-account/delete-account/set-priority.")
if not show_ids:
    print("Add --show-id to print raw account IDs.")
PY
}

list_accounts_cli() {
  require_rpc_cli
  require_python3
  local accounts_resp usage_resp error
  accounts_resp="$(rpc_call "account/list" '{}')" || die "account list request failed"
  error="$(rpc_error_message "$accounts_resp")"
  [[ -z "$error" ]] || die "account list failed: $error"

  usage_resp="$(rpc_call "account/usage/list" '{"limit":1000}')" || die "usage list request failed"
  error="$(rpc_error_message "$usage_resp")"
  [[ -z "$error" ]] || die "usage list failed: $error"

  print_accounts_table "$accounts_resp" "$usage_resp"
}

service_log_cli() {
  normalize_runtime_env
  [[ "$LOG_LIMIT" =~ ^[0-9]+$ ]] || die "log limit must be a positive integer: $LOG_LIMIT"
  local log_file
  log_file="$(native_log_file)"
  [[ -f "$log_file" ]] || die "service log not found: $log_file"
  if [[ "$LOG_FOLLOW" == "true" ]]; then
    tail -n "$LOG_LIMIT" -f "$log_file"
  else
    tail -n "$LOG_LIMIT" "$log_file"
  fi
}

request_logs_cli() {
  require_rpc_cli
  require_python3
  [[ "$LOG_LIMIT" =~ ^[0-9]+$ && "$LOG_LIMIT" -gt 0 ]] || die "log limit must be a positive integer: $LOG_LIMIT"

  local params query_json logs_resp accounts_resp error
  params="{\"page\":1,\"pageSize\":$LOG_LIMIT"
  if [[ -n "$LOG_QUERY" ]]; then
    query_json="$(json_quote "$LOG_QUERY")"
    params="${params},\"query\":$query_json"
  fi
  params="${params}}"

  logs_resp="$(rpc_call "requestlog/list" "$params")" || die "request log request failed"
  error="$(rpc_error_message "$logs_resp")"
  [[ -z "$error" ]] || die "request log query failed: $error"

  accounts_resp="$(rpc_call "account/list" '{}')" || accounts_resp='{"result":{"items":[]}}'

  REQUEST_LOG_JSON="$logs_resp" ACCOUNT_LIST_JSON="$accounts_resp" SHOW_ACCOUNT_IDS="$SHOW_ACCOUNT_IDS" python3 - <<'PY'
import json
import os
import re
import sys
import time

payload = json.loads(os.environ.get("REQUEST_LOG_JSON", "{}"))
accounts_payload = json.loads(os.environ.get("ACCOUNT_LIST_JSON", "{}"))
items = payload.get("result", {}).get("items", [])
total = payload.get("result", {}).get("total", len(items))
show_ids = os.environ.get("SHOW_ACCOUNT_IDS", "").lower() in ("1", "true", "yes", "on")

def color_enabled():
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("FORCE_COLOR") in ("1", "true", "yes", "on"):
        return True
    return sys.stdout.isatty() and os.environ.get("TERM", "") != "dumb"

USE_COLOR = color_enabled()

def paint(value, code):
    text = str(value)
    if not USE_COLOR:
        return text
    return f"\033[{code}m{text}\033[0m"

def words(value):
    return [item for item in re.split(r"[\s,;]+", str(value or "").strip()) if item]

def short_id(value):
    text = str(value or "-")
    if len(text) <= 18:
        return text
    return f"{text[:8]}...{text[-6:]}"

def looks_generated(value):
    text = str(value or "").strip()
    return not text or "@" in text or "::" in text or text.startswith(("auth0|", "apple|"))

def account_name(item):
    label = item.get("label") or ""
    if not looks_generated(label):
        return label
    tag_words = words(item.get("tags"))
    if tag_words:
        return tag_words[0]
    note = item.get("note") or ""
    if note and len(note) <= 32 and not looks_generated(note):
        return note
    return short_id(item.get("id"))

accounts = accounts_payload.get("result", {}).get("items", [])
account_names = {item.get("id"): account_name(item) for item in accounts if item.get("id")}

def fmt_time(ts):
    try:
        value = int(ts)
    except Exception:
        return "-"
    return time.strftime("%m-%d %H:%M:%S", time.localtime(value))

def fmt_ms(value):
    if value is None:
        return "-"
    try:
        value = int(value)
    except Exception:
        return "-"
    if value >= 1000:
        return f"{value / 1000:.1f}s"
    return f"{value}ms"

def status_text(code):
    if code is None:
        return paint("pending", "33")
    try:
        code = int(code)
    except Exception:
        return paint(str(code), "33")
    if 200 <= code < 300:
        return paint(str(code), "32")
    if 400 <= code < 600:
        return paint(str(code), "31")
    return paint(str(code), "33")

def fmt_tokens(item):
    total = item.get("totalTokens")
    input_tokens = item.get("inputTokens")
    output_tokens = item.get("outputTokens")
    if total is None and input_tokens is None and output_tokens is None:
        return "tokens -"
    return f"tokens in={input_tokens or 0} out={output_tokens or 0} total={total or 0}"

def fmt_cost(value):
    if value is None:
        return "cost -"
    try:
        return f"cost ${float(value):.6f}"
    except Exception:
        return "cost -"

def source_name(item):
    actual_kind = str(item.get("actualSourceKind") or "")
    account_id = item.get("accountId")
    if not account_id and actual_kind == "openai_account":
        account_id = item.get("actualSourceId")
    if not account_id:
        account_id = item.get("initialAccountId")
    if not account_id:
        return "-"
    if show_ids:
        return short_id(account_id)
    return account_names.get(account_id, short_id(account_id))

def account_display(account_id):
    if not account_id:
        return "-"
    if show_ids:
        return short_id(account_id)
    return account_names.get(account_id, short_id(account_id))

def account_detail(item):
    details = []
    actual_kind = str(item.get("actualSourceKind") or "")
    actual_id = item.get("actualSourceId")
    final_id = item.get("accountId")
    if not final_id and actual_kind == "openai_account":
        final_id = actual_id
    initial_id = item.get("initialAccountId")
    attempts = item.get("attemptedAccountIds") or []

    if final_id:
        details.append(f"acct={account_display(final_id)}")
    elif actual_kind and actual_kind != "openai_account":
        source_id = str(actual_id or "-")
        details.append(f"source={actual_kind}:{short_id(source_id)}")
    elif initial_id or attempts or item.get("routeStrategy"):
        details.append("acct=-")

    if initial_id and initial_id != final_id:
        details.append(f"initial={account_display(initial_id)}")
    if attempts:
        labels = [account_display(value) for value in attempts]
        compact = "->".join(labels[:4])
        if len(labels) > 4:
            compact += f" (+{len(labels) - 4})"
        details.append(f"attempts={compact}")
    route_strategy = item.get("routeStrategy")
    if route_strategy:
        details.append(f"route={route_strategy}")
    return "  ".join(details)

if not items:
    print("No request logs found.")
    raise SystemExit(0)

for item in items:
    when = fmt_time(item.get("createdAt"))
    status = status_text(item.get("statusCode"))
    duration = fmt_ms(item.get("durationMs"))
    first = fmt_ms(item.get("firstResponseMs"))
    model = item.get("model") or item.get("clientModel") or item.get("upstreamModel") or "-"
    path = item.get("adaptedPath") or item.get("requestPath") or item.get("originalPath") or "-"
    account = source_name(item)
    line = f"{when}  {status}  {duration:>6}  first {first:>6}  {model}  acct {account}  {path}"
    print(line)
    detail_parts = [account_detail(item), fmt_tokens(item), fmt_cost(item.get('estimatedCostUsd'))]
    detail = "  " + "  ".join(part for part in detail_parts if part)
    trace = item.get("traceId")
    if trace:
        detail += f"  trace {short_id(trace)}"
    print(detail)
    if item.get("error"):
        print("  " + paint("error ", "31") + str(item.get("error"))[:240])

print()
print(f"Shown: {len(items)} of {total} request log(s)")
PY
}

refresh_quota_cli() {
  require_rpc_cli
  local params='{}'
  if [[ -n "$ACCOUNT_REF" ]]; then
    local account_id account_id_json
    account_id="$(resolve_account_ref "$ACCOUNT_REF")"
    account_id_json="$(json_quote "$account_id")"
    params="{\"accountId\":$account_id_json}"
    step "refreshing quota for $ACCOUNT_REF"
  else
    step "refreshing quota for all accounts"
  fi

  local resp error
  resp="$(rpc_call "account/usage/refresh" "$params")" || die "usage refresh request failed"
  error="$(rpc_error_message "$resp")"
  [[ -z "$error" ]] || die "usage refresh failed: $error"
  step "quota refresh requested"
  list_accounts_cli
}

update_account_status_cli() {
  require_rpc_cli
  local status="$1"
  local account_id account_id_json status_json resp error
  account_id="$(resolve_account_ref "$ACCOUNT_REF")"
  account_id_json="$(json_quote "$account_id")"
  status_json="$(json_quote "$status")"
  resp="$(rpc_call "account/update" "{\"accountId\":$account_id_json,\"status\":$status_json}")" \
    || die "account update request failed"
  error="$(rpc_error_message "$resp")"
  [[ -z "$error" ]] || die "account update failed: $error"
  step "account ${ACCOUNT_REF:-$account_id} status set to $status"
  list_accounts_cli
}

delete_account_cli() {
  require_rpc_cli
  local account_id account_id_json resp error
  account_id="$(resolve_account_ref "$ACCOUNT_REF")"
  account_id_json="$(json_quote "$account_id")"
  resp="$(rpc_call "account/delete" "{\"accountId\":$account_id_json}")" \
    || die "account delete request failed"
  error="$(rpc_error_message "$resp")"
  [[ -z "$error" ]] || die "account delete failed: $error"
  step "account deleted: ${ACCOUNT_REF:-$account_id}"
  list_accounts_cli
}

rename_account_cli() {
  require_rpc_cli
  validate_account_name "$ACCOUNT_NAME_VALUE"
  local account_id account_id_json name_json resp error
  account_id="$(resolve_account_ref "$ACCOUNT_REF")"
  account_id_json="$(json_quote "$account_id")"
  name_json="$(json_quote "$ACCOUNT_NAME_VALUE")"
  resp="$(rpc_call "account/update" "{\"accountId\":$account_id_json,\"label\":$name_json}")" \
    || die "account rename request failed"
  error="$(rpc_error_message "$resp")"
  [[ -z "$error" ]] || die "account rename failed: $error"
  step "account ${ACCOUNT_REF:-$account_id} renamed to $ACCOUNT_NAME_VALUE"
  list_accounts_cli
}

set_priority_cli() {
  require_rpc_cli
  [[ "$PRIORITY_VALUE" =~ ^-?[0-9]+$ ]] || die "priority must be an integer: $PRIORITY_VALUE"
  local account_id account_id_json resp error
  account_id="$(resolve_account_ref "$ACCOUNT_REF")"
  account_id_json="$(json_quote "$account_id")"
  resp="$(rpc_call "account/update" "{\"accountId\":$account_id_json,\"sort\":$PRIORITY_VALUE}")" \
    || die "account priority update request failed"
  error="$(rpc_error_message "$resp")"
  [[ -z "$error" ]] || die "account priority update failed: $error"
  step "account ${ACCOUNT_REF:-$account_id} priority set to $PRIORITY_VALUE"
  list_accounts_cli
}

login_params_for_slot() {
  local slot="$1"
  local note tags group workspace params value
  note="$(account_config_value "$slot" NOTE)"
  tags="$(account_config_value "$slot" TAGS)"
  if [[ -z "$tags" ]]; then
    tags="$(account_config_value "$slot" TAG)"
  fi
  if [[ -z "$tags" && "$slot" != "default" ]]; then
    tags="$slot"
  fi
  tags="$(append_tag_once "$tags" "$slot")"
  group="$(account_config_value "$slot" GROUP)"
  workspace="$(account_config_value "$slot" WORKSPACE_ID)"

  params='{"type":"device","openBrowser":false'
  if [[ -n "$note" ]]; then
    value="$(json_quote "$note")"
    params="${params},\"note\":${value}"
  fi
  if [[ -n "$tags" ]]; then
    value="$(json_quote "$tags")"
    params="${params},\"tags\":${value}"
  fi
  if [[ -n "$group" ]]; then
    value="$(json_quote "$group")"
    params="${params},\"groupName\":${value}"
  fi
  if [[ -n "$workspace" ]]; then
    value="$(json_quote "$workspace")"
    params="${params},\"workspaceId\":${value}"
  fi
  params="${params}}"
  printf '%s' "$params"
}

finalize_login_account_name() {
  local account_name="$1"
  local account_id account_id_json name_json resp error

  account_id="$(ACCOUNT_REF="$account_name" resolve_account_ref "$account_name")" || {
    warn "login completed, but account name could not be applied automatically"
    return 1
  }
  account_id_json="$(json_quote "$account_id")"
  name_json="$(json_quote "$account_name")"
  resp="$(rpc_call "account/update" "{\"accountId\":$account_id_json,\"label\":$name_json}")" || {
    warn "login completed, but account label update failed"
    return 1
  }
  error="$(rpc_error_message "$resp")"
  if [[ -n "$error" ]]; then
    warn "login completed, but account label update failed: $error"
    return 1
  fi
  step "account name set to $account_name"
}

login_account() {
  normalize_runtime_env
  command -v curl >/dev/null 2>&1 || die "curl not found"
  require_json_reader

  local slot params start_resp start_error login_id verification_url user_code
  slot="$(resolve_account_slot)"
  validate_account_name "$slot"
  params="$(login_params_for_slot "$slot")"

  step "starting device auth login for account slot: $slot"
  start_resp="$(rpc_call "account/login/start" "$params")" \
    || die "could not reach service RPC at $(rpc_url). Start the gateway first and check the RPC token."

  start_error="$(json_get_first "$start_resp" "error.message" "result.error" "result.message")"
  [[ -z "$start_error" ]] || die "login start failed: $start_error"

  login_id="$(json_get_first "$start_resp" "result.loginId" "result.login_id")"
  verification_url="$(json_get_first "$start_resp" "result.verificationUrl" "result.verification_url")"
  user_code="$(json_get_first "$start_resp" "result.userCode" "result.user_code")"
  if [[ -z "$login_id" || -z "$verification_url" || -z "$user_code" ]]; then
    die "unexpected login response: $start_resp"
  fi

  printf '\n'
  step "open this URL in any browser:"
  printf '  %s\n' "$verification_url"
  step "enter this device code:"
  printf '  %s\n\n' "$user_code"
  step "waiting for authorization to finish"

  local timeout poll elapsed last_notice login_id_json status_resp status status_error
  timeout="${REMOTE_GATEWAY_LOGIN_TIMEOUT_SECS:-900}"
  poll="${REMOTE_GATEWAY_LOGIN_POLL_SECS:-3}"
  login_id_json="$(json_quote "$login_id")"
  elapsed=0
  last_notice=0
  while (( elapsed < timeout )); do
    sleep "$poll"
    elapsed=$((elapsed + poll))
    status_resp="$(rpc_call "account/login/status" "{\"loginId\":$login_id_json}")" \
      || die "login status request failed"
    status="$(json_get_first "$status_resp" "result.status" "status")"
    status_error="$(json_get_first "$status_resp" "result.error" "error.message" "result.message")"

    case "$status" in
      success)
        step "device auth completed; account is saved"
        finalize_login_account_name "$slot" || true
        if truthy "${REMOTE_GATEWAY_APPLY_CONFIG_AFTER_LOGIN:-1}"; then
          if ! apply_account_config; then
            warn "account priority config was not fully applied"
          fi
        fi
        return
        ;;
      failed)
        die "device auth failed: ${status_error:-unknown error}"
        ;;
      unknown)
        die "login session is unknown; start a new login flow"
        ;;
      pending|"")
        if (( elapsed - last_notice >= 30 )); then
          step "still waiting for browser authorization (${elapsed}s elapsed)"
          last_notice="$elapsed"
        fi
        ;;
      *)
        die "unexpected login status: $status"
        ;;
    esac
  done

  die "device auth timed out after ${timeout}s"
}

apply_account_config() {
  normalize_runtime_env
  command -v curl >/dev/null 2>&1 || die "curl not found"
  command -v python3 >/dev/null 2>&1 || die "python3 is required for apply-config"

  if [[ -z "${REMOTE_GATEWAY_ACCOUNTS:-}" ]]; then
    step "no REMOTE_GATEWAY_ACCOUNTS configured; nothing to apply"
    return
  fi

  local list_resp error updates_resp updates_json update_error
  step "reading accounts"
  list_resp="$(rpc_call "account/list" '{}')" || die "account list request failed"
  error="$(json_get_first "$list_resp" "error.message" "result.error" "result.message")"
  [[ -z "$error" ]] || die "account list failed: $error"

  updates_json="$(ACCOUNT_LIST_JSON="$list_resp" python3 - <<'PY'
import json
import os
import re
import sys

def split_words(value):
    return [item for item in re.split(r"[\s,;]+", value.strip()) if item]

def suffix(slot):
    return re.sub(r"[^A-Z0-9_]", "_", slot.upper().replace("-", "_"))

def env(slot, field):
    return os.environ.get(f"REMOTE_GATEWAY_ACCOUNT_{suffix(slot)}_{field}", "").strip()

def account_tags(item):
    return set(split_words(str(item.get("tags") or "")))

try:
    payload = json.loads(os.environ["ACCOUNT_LIST_JSON"])
except Exception as exc:
    print(f"parse account list failed: {exc}", file=sys.stderr)
    raise SystemExit(1)

items = payload.get("result", {}).get("items", [])
slots = split_words(os.environ.get("REMOTE_GATEWAY_ACCOUNTS", ""))
updates = []
seen = set()

for slot in slots:
    priority = env(slot, "PRIORITY") or env(slot, "SORT")
    if not priority:
        continue
    try:
        sort = int(priority)
    except ValueError:
        print(f"skip {slot}: priority must be an integer", file=sys.stderr)
        continue

    configured_id = env(slot, "ID")
    configured_tags = split_words(env(slot, "TAGS") or env(slot, "TAG") or slot)
    configured_note = env(slot, "NOTE")
    configured_label = env(slot, "LABEL")

    match = None
    for item in items:
        if configured_id and item.get("id") == configured_id:
            match = item
            break
    if match is None and configured_tags:
        wanted = set(configured_tags)
        for item in items:
            if account_tags(item) & wanted:
                match = item
                break
    if match is None and configured_note:
        for item in items:
            if (item.get("note") or "") == configured_note:
                match = item
                break
    if match is None and configured_label:
        for item in items:
            if (item.get("label") or "") == configured_label:
                match = item
                break
    if match is None and slot == "default" and len(items) == 1:
        match = items[0]

    if match is None:
        print(f"account slot not found: {slot}", file=sys.stderr)
        continue

    account_id = match.get("id")
    if not account_id or account_id in seen:
        continue
    seen.add(account_id)
    updates.append({"accountId": account_id, "sort": sort})

print(json.dumps({"updates": updates}, separators=(",", ":")))
PY
)"

  if [[ "$updates_json" == '{"updates":[]}' ]]; then
    step "no account priorities matched current accounts"
    return
  fi

  step "applying account priorities"
  updates_resp="$(rpc_call "account/updateSorts" "$updates_json")" || die "account priority update request failed"
  update_error="$(json_get_first "$updates_resp" "error.message" "result.error" "result.message")"
  [[ -z "$update_error" ]] || die "account priority update failed: $update_error"
  step "account priorities applied"
}

PLATFORM_API_KEY_CREATE_ID=""
PLATFORM_API_KEY_CREATE_KEY=""
PLATFORM_API_KEY_CREATE_ERROR=""

create_platform_api_key_rpc() {
  PLATFORM_API_KEY_CREATE_ID=""
  PLATFORM_API_KEY_CREATE_KEY=""
  PLATFORM_API_KEY_CREATE_ERROR=""

  command -v curl >/dev/null 2>&1 || {
    PLATFORM_API_KEY_CREATE_ERROR="curl not found"
    return 1
  }
  if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    PLATFORM_API_KEY_CREATE_ERROR="jq or python3 is required"
    return 1
  fi

  local name="$1"
  local model="$2"
  local name_json model_json resp error key key_id
  name_json="$(json_quote "$name")"
  model_json="$(json_quote "$model")"

  resp="$(rpc_call "apikey/create" "{\"name\":$name_json,\"modelSlug\":$model_json,\"rotationStrategy\":\"account_rotation\",\"protocolType\":\"openai_compat\"}")" \
    || {
      PLATFORM_API_KEY_CREATE_ERROR="could not reach service RPC at $(rpc_url). Start the gateway first and check the RPC token."
      return 1
    }
  error="$(json_get_first "$resp" "error.message" "result.error" "result.message")"
  if [[ -n "$error" ]]; then
    PLATFORM_API_KEY_CREATE_ERROR="create api key failed: $error"
    return 1
  fi

  key="$(json_get_first "$resp" "result.key" "key")"
  key_id="$(json_get_first "$resp" "result.id" "id")"
  if [[ -z "$key" ]]; then
    PLATFORM_API_KEY_CREATE_ERROR="unexpected api key response: $resp"
    return 1
  fi

  PLATFORM_API_KEY_CREATE_ID="$key_id"
  PLATFORM_API_KEY_CREATE_KEY="$key"
}

create_api_key() {
  normalize_runtime_env

  local name="${REMOTE_GATEWAY_API_KEY_NAME:-remote-codex}"
  local model="${REMOTE_CODEX_MODEL:-gpt-5.4}"

  step "creating platform API key"
  create_platform_api_key_rpc "$name" "$model" || die "$PLATFORM_API_KEY_CREATE_ERROR"

  printf '\n'
  step "created platform API key${PLATFORM_API_KEY_CREATE_ID:+ ($PLATFORM_API_KEY_CREATE_ID)}"
  printf '  %s\n\n' "$PLATFORM_API_KEY_CREATE_KEY"
  step "use this value as OPENAI_API_KEY for Codex clients"
}

expand_user_path() {
  local path="$1"
  case "$path" in
    "~")
      [[ -n "${HOME:-}" ]] || return 1
      printf '%s' "$HOME"
      ;;
    "~/"*)
      [[ -n "${HOME:-}" ]] || return 1
      printf '%s/%s' "$HOME" "${path#\~/}"
      ;;
    *)
      printf '%s' "$path"
      ;;
  esac
}

codex_app_default_config_path() {
  [[ -n "${HOME:-}" ]] || return 1
  printf '%s/.codex/config.toml' "$HOME"
}

codex_app_default_key_path() {
  [[ -n "${HOME:-}" ]] || return 1
  printf '%s/.codex/remote-gateway-api-key' "$HOME"
}

codex_app_base_url() {
  local raw="${REMOTE_GATEWAY_CODEX_APP_BASE_URL:-}"
  if [[ -z "$raw" ]]; then
    raw="http://127.0.0.1:${REMOTE_GATEWAY_WEB_PORT:-48761}"
  fi
  raw="${raw%/}"
  case "$raw" in
    */v1) printf '%s' "$raw" ;;
    *) printf '%s/v1' "$raw" ;;
  esac
}

ensure_codex_app_api_key_file() {
  local key_path="$1"
  if [[ -s "$key_path" ]]; then
    chmod 600 "$key_path" 2>/dev/null || true
    return 0
  fi

  if [[ -z "${CODEXMANAGER_RPC_TOKEN:-}" ]]; then
    local token_file
    token_file="$(rpc_token_file_for_host)"
    if [[ ! -s "$token_file" ]]; then
      warn "RPC token file is not ready; cannot create Codex App API key: $token_file"
      return 1
    fi
  fi

  local key_dir name model tmp
  key_dir="$(dirname "$key_path")"
  mkdir -p "$key_dir" || {
    warn "could not create Codex App key directory: $key_dir"
    return 1
  }
  chmod 700 "$key_dir" 2>/dev/null || true

  name="${REMOTE_GATEWAY_CODEX_APP_API_KEY_NAME:-${REMOTE_GATEWAY_API_KEY_NAME:-remote-codex-app}}"
  model="${REMOTE_CODEX_MODEL:-gpt-5.4}"
  if ! create_platform_api_key_rpc "$name" "$model"; then
    warn "$PLATFORM_API_KEY_CREATE_ERROR"
    return 1
  fi

  tmp="${key_path}.tmp.$$"
  if ! (umask 077 && printf '%s\n' "$PLATFORM_API_KEY_CREATE_KEY" >"$tmp"); then
    rm -f "$tmp"
    warn "could not write Codex App API key file: $key_path"
    return 1
  fi
  mv "$tmp" "$key_path" || {
    rm -f "$tmp"
    warn "could not install Codex App API key file: $key_path"
    return 1
  }
  chmod 600 "$key_path" 2>/dev/null || true
  step "Codex App API key written: $key_path"
}

write_codex_app_provider_config() {
  local config_path="$1"
  local provider_id="$2"
  local provider_name="$3"
  local base_url="$4"
  local wire_api="$5"
  local key_path="$6"

  [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || {
    warn "invalid Codex App provider id: $provider_id"
    return 1
  }
  command -v python3 >/dev/null 2>&1 || {
    warn "python3 is required to write Codex App config"
    return 1
  }

  CODEX_APP_CONFIG_PATH="$config_path" \
  CODEX_APP_PROVIDER_ID="$provider_id" \
  CODEX_APP_PROVIDER_NAME="$provider_name" \
  CODEX_APP_BASE_URL="$base_url" \
  CODEX_APP_WIRE_API="$wire_api" \
  CODEX_APP_KEY_PATH="$key_path" \
  python3 - <<'PY'
import json
import os
import re
import shutil
import sys

path = os.environ["CODEX_APP_CONFIG_PATH"]
provider_id = os.environ["CODEX_APP_PROVIDER_ID"]
provider_name = os.environ["CODEX_APP_PROVIDER_NAME"]
base_url = os.environ["CODEX_APP_BASE_URL"]
wire_api = os.environ["CODEX_APP_WIRE_API"]
key_path = os.environ["CODEX_APP_KEY_PATH"]

if not re.fullmatch(r"[A-Za-z0-9_-]+", provider_id):
    print(f"invalid provider id: {provider_id}", file=sys.stderr)
    raise SystemExit(1)

provider_table = f"model_providers.{provider_id}"
auth_table = f"{provider_table}.auth"
managed_comment = "# Managed by remote-codex-gateway. This provider block may be overwritten."

def toml_string(value):
    return json.dumps(str(value), ensure_ascii=False)

def section_name(line):
    stripped = line.strip()
    if not stripped.startswith("[") or stripped.startswith("[[") or not stripped.endswith("]"):
        return None
    inner = stripped[1:-1].strip()
    if inner.startswith("[") or inner.endswith("]"):
        return None
    return inner

try:
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.readlines()
except FileNotFoundError:
    lines = []
except OSError as exc:
    print(f"read Codex config failed: {exc}", file=sys.stderr)
    raise SystemExit(1)

cleaned = []
current_section = ""
skip_provider = False
for line in lines:
    if line.strip() == managed_comment:
        continue
    name = section_name(line)
    if name is not None:
        current_section = name
        skip_provider = name == provider_table or name.startswith(provider_table + ".")
        if skip_provider:
            continue
    if skip_provider:
        continue
    if not current_section and re.match(r"\s*model_provider\s*=", line):
        continue
    cleaned.append(line)

insert_at = 0
while insert_at < len(cleaned):
    stripped = cleaned[insert_at].strip()
    if stripped == "" or stripped.startswith("#"):
        insert_at += 1
        continue
    break
cleaned.insert(insert_at, f"model_provider = {toml_string(provider_id)}\n")

if cleaned and cleaned[-1].strip():
    cleaned.append("\n")
cleaned.extend(
    [
        managed_comment + "\n",
        f"[{provider_table}]\n",
        f"name = {toml_string(provider_name)}\n",
        f"base_url = {toml_string(base_url)}\n",
        f"wire_api = {toml_string(wire_api)}\n",
        "\n",
        f"[{auth_table}]\n",
        'command = "cat"\n',
        f"args = [{toml_string(key_path)}]\n",
        "timeout_ms = 5000\n",
        "refresh_interval_ms = 0\n",
    ]
)

directory = os.path.dirname(path)
if directory:
    os.makedirs(directory, exist_ok=True)

backup_path = path + ".remote-gateway.bak"
if os.path.exists(path) and not os.path.exists(backup_path):
    try:
        shutil.copy2(path, backup_path)
    except OSError as exc:
        print(f"backup Codex config failed: {exc}", file=sys.stderr)
        raise SystemExit(1)

mode = 0o600
if os.path.exists(path):
    try:
        mode = os.stat(path).st_mode & 0o777
    except OSError:
        mode = 0o600

tmp_path = f"{path}.tmp.{os.getpid()}"
try:
    with open(tmp_path, "w", encoding="utf-8") as handle:
        handle.writelines(cleaned)
    os.chmod(tmp_path, mode)
    os.replace(tmp_path, path)
except OSError as exc:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    print(f"write Codex config failed: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

warm_codex_app_models() {
  local key_path="$1"
  local base_url="$2"
  if ! truthy "${REMOTE_GATEWAY_CODEX_APP_WARM_MODELS:-1}"; then
    return 0
  fi
  local routing_resp routing_error
  if routing_resp="$(rpc_call "apikey/modelRouting" '{}')" 2>/dev/null; then
    routing_error="$(rpc_error_message "$routing_resp")"
    if [[ -z "$routing_error" ]]; then
      step "Codex App model routing warmed"
    else
      warn "Codex App model routing warmup failed: $routing_error"
    fi
  else
    warn "Codex App model routing warmup request failed"
  fi

  command -v curl >/dev/null 2>&1 || {
    warn "curl not found; skip Codex App model warmup"
    return 0
  }
  [[ -s "$key_path" ]] || {
    warn "Codex App API key file is empty; skip model warmup: $key_path"
    return 0
  }

  local key models_url
  key="$(tr -d '\r\n' <"$key_path")"
  if [[ -z "$key" ]]; then
    warn "Codex App API key file is empty; skip model warmup: $key_path"
    return 0
  fi
  models_url="${base_url%/}/models"
  if service_curl "$models_url" -fsS -H "authorization: Bearer $key" >/dev/null 2>&1; then
    step "Codex App model catalog warmed: $models_url"
  else
    warn "Codex App model catalog warmup failed: $models_url"
  fi
}

repair_codex_app_history() {
  local config_path="$1"
  local codex_home codex_home_json repair_resp repair_error repair_message

  codex_home="$(dirname "$config_path")"
  codex_home_json="$(json_quote "$codex_home")"
  repair_resp="$(rpc_call "codexProfile/repairHistory" "{\"codexHome\":$codex_home_json}")" || {
    warn "Codex App history repair request failed"
    return 0
  }
  repair_error="$(rpc_error_message "$repair_resp")"
  if [[ -n "$repair_error" ]]; then
    warn "Codex App history repair failed: $repair_error"
    return 0
  fi

  repair_message="$(json_get_first "$repair_resp" "result.message")"
  step "${repair_message:-Codex App history visibility checked}"
}

restart_codex_app_server() {
  command -v pgrep >/dev/null 2>&1 || {
    warn "pgrep not found; reopen the Codex remote SSH session for the new provider config"
    return 0
  }

  local current_uid pids=() pid
  current_uid="$(id -u)"
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
    pids+=("$pid")
  done < <(pgrep -u "$current_uid" -f 'codex app-server' 2>/dev/null || true)

  if [[ "${#pids[@]}" -eq 0 ]]; then
    step "no Codex App app-server process found"
    return 0
  fi

  step "stopping Codex App app-server process(es): ${pids[*]}"
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  step "reopen the Codex remote SSH session so app-server restarts with the gateway provider"
}

configure_codex_app_provider() {
  local default_config default_key config_path key_path provider_id provider_name base_url wire_api
  default_config="$(codex_app_default_config_path)" || {
    warn "HOME is required to locate Codex App config"
    return 1
  }
  default_key="$(codex_app_default_key_path)" || {
    warn "HOME is required to locate Codex App API key file"
    return 1
  }

  config_path="$(expand_user_path "${REMOTE_GATEWAY_CODEX_APP_CONFIG_PATH:-$default_config}")" || {
    warn "could not expand Codex App config path"
    return 1
  }
  key_path="$(expand_user_path "${REMOTE_GATEWAY_CODEX_APP_KEY_PATH:-$default_key}")" || {
    warn "could not expand Codex App key path"
    return 1
  }
  provider_id="${REMOTE_GATEWAY_CODEX_APP_PROVIDER_ID:-remote_gateway}"
  provider_name="${REMOTE_GATEWAY_CODEX_APP_PROVIDER_NAME:-Remote Codex Gateway}"
  base_url="$(codex_app_base_url)"
  wire_api="${REMOTE_GATEWAY_CODEX_APP_WIRE_API:-responses}"

  ensure_codex_app_api_key_file "$key_path" || return 1
  write_codex_app_provider_config "$config_path" "$provider_id" "$provider_name" "$base_url" "$wire_api" "$key_path" || return 1
  warm_codex_app_models "$key_path" "$base_url"
  repair_codex_app_history "$config_path"

  step "Codex App provider configured: $provider_id -> $base_url"
  step "Codex App config: $config_path"
  if truthy "${REMOTE_GATEWAY_CODEX_APP_RESTART_SERVER:-0}"; then
    restart_codex_app_server
  else
    step "reopen the Codex remote SSH session for app-server to reload this config"
  fi
}

configure_codex_app_provider_after_start() {
  if ! truthy "${REMOTE_GATEWAY_CODEX_APP_CONFIGURE_ON_START:-0}"; then
    return 0
  fi
  if ! configure_codex_app_provider; then
    warn "Codex App provider config was not applied"
  fi
  return 0
}

load_config

case "$COMMAND" in
  start) start_gateway ;;
  stop) stop_gateway ;;
  status) gateway_status ;;
  health) health_check ;;
  dashboard) dashboard_cli ;;
  install-rust) install_rust_toolchain ;;
  login) login_account ;;
  accounts) list_accounts_cli ;;
  quota) list_accounts_cli ;;
  refresh-quota) refresh_quota_cli ;;
  logs) request_logs_cli ;;
  service-log) service_log_cli ;;
  disable-account) update_account_status_cli disabled ;;
  enable-account) update_account_status_cli active ;;
  delete-account) delete_account_cli ;;
  rename-account) rename_account_cli ;;
  set-priority) set_priority_cli ;;
  key) create_api_key ;;
  apply-config) apply_account_config ;;
  *) die "unknown command: $COMMAND" ;;
esac
