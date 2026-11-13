#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/release"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zentao-mcp-build.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$RELEASE_DIR" "$WORK_DIR/package"
cp -R "$ROOT_DIR/server" "$WORK_DIR/package/"

tar -czf "$RELEASE_DIR/zentao-mcp.tar.gz" -C "$WORK_DIR" package

awk '/^__ZEN_TAO_MCP_PAYLOAD_BELOW__$/{exit} {print}' "$ROOT_DIR/install.sh" > "$RELEASE_DIR/zentao-mcp-installer.sh"
printf '%s\n' '__ZEN_TAO_MCP_PAYLOAD_BELOW__' >> "$RELEASE_DIR/zentao-mcp-installer.sh"
base64 < "$RELEASE_DIR/zentao-mcp.tar.gz" >> "$RELEASE_DIR/zentao-mcp-installer.sh"
chmod 755 "$RELEASE_DIR/zentao-mcp-installer.sh"

printf '已生成：%s\n' "$RELEASE_DIR/zentao-mcp-installer.sh"
printf '已生成：%s\n' "$RELEASE_DIR/zentao-mcp.tar.gz"
printf '安装器大小：%s\n' "$(du -h "$RELEASE_DIR/zentao-mcp-installer.sh" | awk '{print $1}')"
