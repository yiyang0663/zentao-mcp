#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/release"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zentao-mcp-build.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

if ! command -v zip >/dev/null 2>&1; then
  echo '未找到 zip 命令，无法生成 Windows 安装包。' >&2
  exit 1
fi

mkdir -p "$RELEASE_DIR" "$WORK_DIR/package"
cp -R "$ROOT_DIR/server" "$WORK_DIR/package/"
cp -R "$ROOT_DIR/windows" "$WORK_DIR/package/"

WINDOWS_ZIP="$RELEASE_DIR/zentao-mcp-windows.zip"
rm -f "$WINDOWS_ZIP"
(cd "$WORK_DIR" && zip -qr "$WINDOWS_ZIP" package)
cp "$ROOT_DIR/install.ps1" "$RELEASE_DIR/install.ps1"

tar -czf "$RELEASE_DIR/zentao-mcp.tar.gz" -C "$WORK_DIR" package

awk '/^__ZEN_TAO_MCP_PAYLOAD_BELOW__$/{exit} {print}' "$ROOT_DIR/install.sh" > "$RELEASE_DIR/zentao-mcp-installer.sh"
printf '%s\n' '__ZEN_TAO_MCP_PAYLOAD_BELOW__' >> "$RELEASE_DIR/zentao-mcp-installer.sh"
base64 < "$RELEASE_DIR/zentao-mcp.tar.gz" >> "$RELEASE_DIR/zentao-mcp-installer.sh"
chmod 755 "$RELEASE_DIR/zentao-mcp-installer.sh"

printf '已生成：%s\n' "$RELEASE_DIR/zentao-mcp-installer.sh"
printf '已生成：%s\n' "$RELEASE_DIR/zentao-mcp.tar.gz"
printf '已生成：%s\n' "$RELEASE_DIR/install.ps1"
printf '已生成：%s\n' "$WINDOWS_ZIP"
printf '安装器大小：%s\n' "$(du -h "$RELEASE_DIR/zentao-mcp-installer.sh" | awk '{print $1}')"

if command -v shasum >/dev/null 2>&1; then
  (cd "$RELEASE_DIR" && shasum -a 256 install.ps1 zentao-mcp-installer.sh zentao-mcp.tar.gz zentao-mcp-windows.zip > SHA256SUMS)
elif command -v sha256sum >/dev/null 2>&1; then
  (cd "$RELEASE_DIR" && sha256sum install.ps1 zentao-mcp-installer.sh zentao-mcp.tar.gz zentao-mcp-windows.zip > SHA256SUMS)
else
  echo '未找到 shasum 或 sha256sum，无法生成 SHA256SUMS。' >&2
  exit 1
fi
