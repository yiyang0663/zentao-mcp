# 禅道 MCP 一键安装包

这个目录用于分发当前自建的禅道 MCP。安装器会把 MCP 服务和依赖安装到用户自己的目录，并在本机保存禅道连接信息。

## 给使用者的最新安装方式

发布 `release/zentao-mcp-installer.sh` 后，使用者复制下面命令，把其中的下载地址替换成实际的文件服务器或 GitLab Release 地址：

```bash
set -e
INSTALLER_URL='https://github.com/yiyang0663/zentao-mcp/releases/download/v1.1.0/zentao-mcp-installer.sh'
INSTALLER_FILE="$(mktemp "${TMPDIR:-/tmp}/zentao-mcp-installer.XXXXXX.sh")"
trap 'rm -f "$INSTALLER_FILE"' EXIT
curl --fail --location "$INSTALLER_URL" -o "$INSTALLER_FILE"
bash "$INSTALLER_FILE"
```

不要使用 `curl URL | bash`。这个安装器需要读取自身后面的内置程序包，先下载成临时文件再执行才能正确完成自解压。

如果使用者希望完全自动化安装，可以提前提供环境变量：

```bash
ZENTAO_URL='http://192.168.1.212' \\
ZENTAO_ACCOUNT='开发账号' \\
ZENTAO_PASSWORD='禅道密码' \\
bash "$INSTALLER_FILE" --non-interactive
```

安装器会优先使用当前 Codex CLI 的标准命令自动注册 MCP：

```bash
codex mcp add zentao -- "$HOME/.local/bin/zentao-mcp"
```

可以用下面的命令确认注册结果：

```bash
codex mcp list
codex mcp get zentao
```

如果电脑没有安装 Codex CLI，安装器仍会生成 `codex-mcp.toml` 配置片段；也可以把启动命令直接配置到其他支持 stdio MCP 的客户端。

安装过程中会询问：

- 禅道地址，例如 `http://192.168.1.212`
- 禅道账号
- 禅道密码

密码只会写入本机的 `~/.config/zentao-mcp/credentials.env`，文件权限为 `600`。安装器不会携带发布者的账号密码。

## 安装后的 Codex 配置

安装器会生成一个配置片段文件：

```text
~/.config/zentao-mcp/codex-mcp.toml
```

通常不需要手工修改 `~/.codex/config.toml`，安装器会调用 `codex mcp add` 自动写入。只有自动注册失败或电脑没有 Codex CLI 时，才使用配置片段。示例：

```toml
[mcp_servers.zentao]
command = "/Users/你的用户名/.local/bin/zentao-mcp"
```

其他支持 stdio MCP 的客户端也使用安装器输出的启动命令作为 MCP server command；只需要把对应客户端的 `command` 配置指向同一个 `zentao-mcp` 文件即可。

## Bug 处理工具

安装后可以直接使用以下工具完成个人 Bug 处理流程：

- `zentao_my_assigned_bugs`：查询当前账号名下的 Bug。
- `zentao_create_bug`：创建 Bug，需要产品 ID、标题和重现步骤。
- `zentao_resolve_bug`：将 Bug 标记为已解决，可填写解决方案、解决版本和备注。
- `zentao_assign_bug`：按禅道账号将 Bug 指派给测试人员或其他同事。
- `zentao_reopen_bug`：重新激活已解决或已关闭的 Bug。
- `zentao_verify_bug_update`：重新读取 Bug 详情，核对状态、处理人、解决方案和解决版本。

建议的使用顺序：

```text
查询我当前的 Bug
-> 选择需要处理的 Bug
-> 核对代码和测试结果
-> 标记为已解决
-> 指派给测试人员
-> 重新读取 Bug 详情确认结果
```

`assignedTo` 需要传禅道登录账号，例如 `tester01`，不能传页面显示姓名。写操作仍然受当前禅道账号权限控制。

示例：

```text
调用 zentao_my_assigned_bugs，列出我当前的 Bug
调用 zentao_resolve_bug，bugID=39764，resolution=fixed，resolvedBuild=trunk
调用 zentao_assign_bug，bugID=39764，assignedTo=tester01
调用 zentao_verify_bug_update，bugID=39764，expectedStatus=resolved，expectedAssignedTo=tester01
```

## 前置条件

- macOS 或 Linux
- Node.js 18 或更高版本
- 目标电脑能够访问禅道服务器（内网需要连接公司网络或 VPN）
- 使用者拥有自己的禅道账号

## 生成发布文件

在本目录执行：

```bash
bash scripts/build-installer.sh
```

生成结果位于 `release/`：

- `zentao-mcp-installer.sh`：单文件安装器，适合放到 GitLab Release、公司文件服务器或静态文件服务器
- `zentao-mcp.tar.gz`：源码和依赖归档，适合留档或离线分发

发布时只需要提供 `zentao-mcp-installer.sh` 的下载链接即可。

安装器版本当前为 `1.1.0`。如果已经安装过旧版本，重新执行同一个下载链接即可覆盖服务文件；如果 Codex 中已经存在名为 `zentao` 的旧配置，安装器会保留它并打印切换命令，避免覆盖其他 MCP 配置。

## 安全要求

不要把包含真实账号密码的 `credentials.env`、本机 Codex 配置文件或安装日志提交到代码仓库。建议为每名使用者创建独立的禅道账号，以保留正确的权限和操作记录。
