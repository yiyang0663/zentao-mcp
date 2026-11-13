#!/usr/bin/env bash
set -euo pipefail

VERSION="1.2.1"
INSTALL_DIR="${ZENTAO_MCP_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/zentao-mcp}"
CONFIG_DIR="${ZENTAO_MCP_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zentao-mcp}"
BIN_DIR="${ZENTAO_MCP_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
SOURCE_DIR="${ZENTAO_MCP_SOURCE_DIR:-}"
URL="${ZENTAO_URL:-}"
ACCOUNT="${ZENTAO_ACCOUNT:-}"
PASSWORD="${ZENTAO_PASSWORD:-}"
NON_INTERACTIVE=0
CONFIGURE_CODEX=1

usage() {
  cat <<'USAGE'
禅道 MCP 安装器

用法：
  ./install.sh                         交互式安装
  ./install.sh --non-interactive       使用环境变量安装
  ./install.sh --skip-codex            不自动注册到 Codex

可选环境变量：
  ZENTAO_URL、ZENTAO_ACCOUNT、ZENTAO_PASSWORD
  ZENTAO_MCP_INSTALL_DIR、ZENTAO_MCP_CONFIG_DIR、ZENTAO_MCP_BIN_DIR
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --skip-codex) CONFIGURE_CODEX=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$SOURCE_DIR" ]]; then
  marker_line="$(awk '/^__ZEN_TAO_MCP_PAYLOAD_BELOW__$/{print NR + 1; exit}' "$0")"
  if [[ -n "$marker_line" ]]; then
    PAYLOAD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zentao-mcp.XXXXXX")"
    trap 'rm -rf "$PAYLOAD_DIR"' EXIT
    if base64 --help 2>&1 | grep -q -- '--decode'; then
      tail -n +"$marker_line" "$0" | base64 --decode | tar -xzf - -C "$PAYLOAD_DIR"
    else
      tail -n +"$marker_line" "$0" | base64 -D | tar -xzf - -C "$PAYLOAD_DIR"
    fi
    SOURCE_DIR="$PAYLOAD_DIR/package"
  else
    echo "安装器中没有找到内置程序包。" >&2
    exit 1
  fi
fi

if [[ ! -f "$SOURCE_DIR/server/server.cjs" ]]; then
  echo "程序包不完整：缺少 server/server.cjs。" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "未找到 Node.js。请先安装 Node.js 18 或更高版本后重试。" >&2
  echo "macOS 可执行：brew install node" >&2
  echo "Ubuntu/Debian 可使用 NodeSource 或系统包管理器安装。" >&2
  exit 1
fi

node_major="$(node -p 'process.versions.node.split(".")[0]')"
if [[ "$node_major" -lt 18 ]]; then
  echo "当前 Node.js 版本过低：$(node --version)。需要 18 或更高版本。" >&2
  exit 1
fi

if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
  if [[ ! -t 0 && ! -r /dev/tty ]]; then
    echo "当前没有可交互终端，请设置 ZENTAO_URL、ZENTAO_ACCOUNT、ZENTAO_PASSWORD 后使用 --non-interactive。" >&2
    exit 1
  fi
  read_value() {
    local prompt="$1" name="$2" secret="${3:-0}" value
    if [[ "$secret" -eq 1 ]]; then
      printf '%s' "$prompt" > /dev/tty
      IFS= read -r -s value < /dev/tty
      printf '\n' > /dev/tty
    else
      printf '%s' "$prompt" > /dev/tty
      IFS= read -r value < /dev/tty
    fi
    printf -v "$name" '%s' "$value"
  }
  [[ -n "$URL" ]] || read_value "禅道地址（例如 http://192.168.1.212）: " URL
  [[ -n "$ACCOUNT" ]] || read_value "禅道账号: " ACCOUNT
  [[ -n "$PASSWORD" ]] || read_value "禅道密码: " PASSWORD 1
fi

if [[ -z "$URL" || -z "$ACCOUNT" || -z "$PASSWORD" ]]; then
  echo "禅道地址、账号和密码都不能为空。" >&2
  exit 2
fi

quote_env() {
  printf "%q" "$1"
}
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$BIN_DIR"
cp -R "$SOURCE_DIR/server" "$INSTALL_DIR/"

credentials_file="$CONFIG_DIR/credentials.env"
umask 077
{
  printf 'ZENTAO_URL=%s\n' "$(quote_env "$URL")"
  printf 'ZENTAO_ACCOUNT=%s\n' "$(quote_env "$ACCOUNT")"
  printf 'ZENTAO_PASSWORD=%s\n' "$(quote_env "$PASSWORD")"
} > "$credentials_file"
chmod 600 "$credentials_file"

launcher="$BIN_DIR/zentao-mcp"
cat > "$launcher" <<LAUNCHER
#!/usr/bin/env bash
set -euo pipefail
CREDENTIALS_FILE=$(printf '%q' "$credentials_file")
INSTALL_DIR=$(printf '%q' "$INSTALL_DIR")
if [[ ! -f "\$CREDENTIALS_FILE" ]]; then
  echo "缺少禅道凭据文件：\$CREDENTIALS_FILE" >&2
  exit 1
fi
set -a
source "\$CREDENTIALS_FILE"
set +a
exec "\$(command -v node)" "\$INSTALL_DIR/server/server.cjs" "\$@"
LAUNCHER
chmod 700 "$launcher"

codex_snippet="$CONFIG_DIR/codex-mcp.toml"
cat > "$codex_snippet" <<SNIPPET
# 将下面内容加入 ~/.codex/config.toml 的 [mcp_servers] 配置中
[mcp_servers.zentao]
command = "$launcher"
SNIPPET
chmod 600 "$codex_snippet"

codex_status="未自动配置 Codex。"
if [[ "$CONFIGURE_CODEX" -eq 1 ]] && command -v codex >/dev/null 2>&1; then
  if codex mcp get zentao >/dev/null 2>&1; then
    codex_status="Codex 已存在 zentao 配置；如需切换到本次安装，可执行：codex mcp remove zentao && codex mcp add zentao -- '$launcher'"
  elif codex mcp add zentao -- "$launcher" >/dev/null 2>&1; then
    codex_status="已自动注册到 Codex（codex mcp add zentao）。"
  else
    codex_status="Codex 自动注册失败，请手动执行：codex mcp add zentao -- '$launcher'"
  fi
elif [[ "$CONFIGURE_CODEX" -eq 0 ]]; then
  codex_status="已跳过 Codex 自动配置。"
fi

node --check "$INSTALL_DIR/server/server.cjs"
printf '\n安装完成（版本 %s）。\n' "$VERSION"
printf '启动命令：%s\n' "$launcher"
printf 'Codex 配置片段：%s\n' "$codex_snippet"
printf '%s\n' "$codex_status"
printf '如果 ~/.local/bin 不在 PATH 中，请把它加入 PATH，或在 MCP 配置中使用上面的绝对路径。\n'

exit 0

__ZEN_TAO_MCP_PAYLOAD_BELOW__
