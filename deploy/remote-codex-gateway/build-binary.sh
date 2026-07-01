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
OUT_DIR="${REMOTE_GATEWAY_PACKAGE_BIN_DIR:-$SCRIPT_DIR/bin}"
OUT_BIN="$OUT_DIR/codexmanager-service"
PACKAGE_PLATFORM="${REMOTE_GATEWAY_PACKAGE_PLATFORM:-}"

step() {
  printf '[remote-gateway] %s\n' "$*"
}

die() {
  printf '[remote-gateway] error: %s\n' "$*" >&2
  exit 1
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

load_config_if_present() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    return
  fi
  case "$CONFIG_FILE" in
    *.yaml|*.yml|*.yaml.example|*.yml.example)
      command -v python3 >/dev/null 2>&1 || return
      eval "$(YAML_CONFIG_FILE="$CONFIG_FILE" python3 - <<'PY'
import ast
import os
import re
import shlex

path = os.environ["YAML_CONFIG_FILE"]

def strip_comment(line):
    quote = None
    for i, ch in enumerate(line):
        if ch in ("'", '"'):
            quote = None if quote == ch else ch if quote is None else quote
        if ch == "#" and quote is None and (i == 0 or line[i - 1].isspace()):
            return line[:i]
    return line

def parse_scalar(raw):
    value = raw.strip()
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        try:
            return str(ast.literal_eval(value))
        except Exception:
            return value[1:-1]
    lowered = value.lower()
    if lowered in ("true", "yes", "on"):
        return "1"
    if lowered in ("false", "no", "off"):
        return "0"
    return "" if lowered in ("null", "~") else value

def norm(value):
    return re.sub(r"[^a-z0-9]", "", value.lower())

mapping = {
    ("gateway", "buildproxyurl"): "REMOTE_GATEWAY_BUILD_PROXY_URL",
    ("gateway", "packageplatform"): "REMOTE_GATEWAY_PACKAGE_PLATFORM",
    ("cargo", "registrymirror"): "REMOTE_GATEWAY_CARGO_REGISTRY_MIRROR",
    ("cargo", "registryindex"): "REMOTE_GATEWAY_CARGO_REGISTRY_INDEX",
    ("cargo", "gitfetchwithcli"): "REMOTE_GATEWAY_CARGO_GIT_FETCH_WITH_CLI",
    ("cargo", "httpmultiplexing"): "REMOTE_GATEWAY_CARGO_HTTP_MULTIPLEXING",
}
stack = []
exports = {}
for line in open(path, "r", encoding="utf-8"):
    stripped = strip_comment(line).rstrip()
    if not stripped.strip() or ":" not in stripped:
        continue
    indent = len(stripped) - len(stripped.lstrip(" "))
    text = stripped.strip()
    key, raw = text.split(":", 1)
    while stack and indent <= stack[-1][0]:
        stack.pop()
    key_path = [item[1] for item in stack] + [key.strip()]
    if not raw.strip():
        stack.append((indent, key.strip()))
        continue
    env = mapping.get(tuple(norm(item) for item in key_path))
    if env:
        exports[env] = parse_scalar(raw)
for key in sorted(exports):
    print(f"export {key}={shlex.quote(str(exports[key]))}")
PY
)"
      ;;
    *)
    set -a
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    set +a
      ;;
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

checksum() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file"
  fi
}

load_config_if_present
normalize_build_env
ensure_cargo_path
PACKAGE_PLATFORM="${PACKAGE_PLATFORM:-${REMOTE_GATEWAY_PACKAGE_PLATFORM:-$(platform_id)}}"

command -v cargo >/dev/null 2>&1 || die "cargo not found; run ./deploy/remote-codex-gateway/start.sh install-rust first, or run this script on a machine with Rust/Cargo"

target="${REMOTE_GATEWAY_CARGO_TARGET:-}"
cargo_args=(build --locked --release -p codexmanager-service)
if [[ -n "$target" ]]; then
  cargo_args+=(--target "$target")
fi

step "building codexmanager-service${target:+ for $target}"
(cd "$ROOT" && cargo "${cargo_args[@]}")

if [[ -n "$target" ]]; then
  BUILD_BIN="$ROOT/target/$target/release/codexmanager-service"
else
  BUILD_BIN="$ROOT/target/release/codexmanager-service"
fi
[[ -x "$BUILD_BIN" ]] || die "build output not found: $BUILD_BIN"

mkdir -p "$OUT_DIR" "$SCRIPT_DIR/bin/$PACKAGE_PLATFORM"
cp "$BUILD_BIN" "$OUT_BIN"
cp "$BUILD_BIN" "$SCRIPT_DIR/bin/$PACKAGE_PLATFORM/codexmanager-service"
chmod +x "$OUT_BIN" "$SCRIPT_DIR/bin/$PACKAGE_PLATFORM/codexmanager-service"

step "wrote package binary: $OUT_BIN"
step "wrote platform binary: $SCRIPT_DIR/bin/$PACKAGE_PLATFORM/codexmanager-service"
checksum "$OUT_BIN" || true
step "commit or copy deploy/remote-codex-gateway/bin/ before installing on servers without Cargo"
