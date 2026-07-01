#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${REMOTE_GATEWAY_BIN_DIR:-$HOME/.local/bin}"
COMMAND_NAME="${REMOTE_GATEWAY_COMMAND_NAME:-remote-codex-gateway}"
COMMAND_PATH="$BIN_DIR/$COMMAND_NAME"

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

mkdir -p "$BIN_DIR"

CONFIG_PATH="$SCRIPT_DIR/config.yaml"
if [[ ! -f "$CONFIG_PATH" && ! -f "$SCRIPT_DIR/config.env" ]]; then
  cp "$SCRIPT_DIR/config.yaml.example" "$CONFIG_PATH"
  printf '[remote-gateway] created %s\n' "$CONFIG_PATH"
fi

chmod +x "$SCRIPT_DIR/start.sh"
if [[ -f "$SCRIPT_DIR/build-binary.sh" ]]; then
  chmod +x "$SCRIPT_DIR/build-binary.sh"
fi
if [[ -f "$SCRIPT_DIR/bin/codexmanager-service" ]]; then
  chmod +x "$SCRIPT_DIR/bin/codexmanager-service"
fi
if [[ -f "$SCRIPT_DIR/bin/$(platform_id)/codexmanager-service" ]]; then
  chmod +x "$SCRIPT_DIR/bin/$(platform_id)/codexmanager-service"
fi

cat >"$COMMAND_PATH" <<EOF
#!/usr/bin/env bash
exec "$SCRIPT_DIR/start.sh" "\$@"
EOF
chmod +x "$COMMAND_PATH"

printf '[remote-gateway] installed command: %s\n' "$COMMAND_PATH"
if [[ -f "$CONFIG_PATH" ]]; then
  printf '[remote-gateway] edit config: %s\n' "$CONFIG_PATH"
else
  printf '[remote-gateway] edit config: %s\n' "$SCRIPT_DIR/config.env"
fi
printf '[remote-gateway] start with: %s start\n' "$COMMAND_NAME"

ensure_cargo_path
if [[ ! -x "$SCRIPT_DIR/bin/$(platform_id)/codexmanager-service" \
  && ! -x "$SCRIPT_DIR/bin/codexmanager-service" \
  && ! -x "$SCRIPT_DIR/../../target/release/codexmanager-service" \
  && ! -x "$SCRIPT_DIR/../../target/debug/codexmanager-service" ]]; then
  if ! command -v cargo >/dev/null 2>&1; then
    printf '[remote-gateway] warning: no prebuilt service binary found and cargo is not installed\n' >&2
    printf '[remote-gateway] warning: run %s install-rust, or build on another machine and commit/copy deploy/remote-codex-gateway/bin/\n' "$COMMAND_NAME" >&2
  fi
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    printf '[remote-gateway] add this to PATH if needed: export PATH="%s:$PATH"\n' "$BIN_DIR"
    ;;
esac
