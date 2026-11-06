# 启动并检查本地预览

`cjdoc serve` 先生成 HTML，再在本机提供页面服务，并监视项目文件变化。构建失败时，预览保留最近一次成功站点，状态接口显示错误。

## 前提

- 已完成[首次生成教程](../tutorials/first-site.md)，`docdemo/` 是有效的静态包，且 `src/api.cj` 可被当前 cjdoc 解析。
- `cjdoc` 能在当前终端启动；Python 3、`curl` 可用。两个终端均从 `docdemo/` 根目录工作。
- 本例使用 `127.0.0.1:8080`，该端口须空闲。`serve` 只监听回环地址，不作为公网服务器。

## 启动预览并读取状态

在第一个终端启动服务。它会先生成 HTML，之后保持前台运行并监视源码、Markdown、`cjpm.toml` 和 `cjdoc.toml` 的变化。

```bash
cjdoc serve --project . --port 8080
```

终端会显示本地 URL；构建成功时还会显示 `serve: generated html`。在第二个终端检查首页和 JSON 状态：

```bash
curl -fsS -o /dev/null http://127.0.0.1:8080/
curl -fsS http://127.0.0.1:8080/__cjdoc/status.json | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["status"] == "ok" and s["successfulBuilds"] >= 1; print(s)'
```

状态对象的 `schemaVersion` 是 `cjdoc.serve-status/1`，字段包含 `status`、`port`、`builds`、`successfulBuilds` 和 `lastError`。`builds` 计入初始构建和后续重建；成功时清除 `lastError`。访问 `http://127.0.0.1:8080/` 后可以在 API 页面阅读 `greet`。

## 观察失败重建保留旧站

服务继续在第一个终端运行时，在第二个终端执行以下负例。它临时增加 `symbols = 100` 门槛，再将完整 API 源文件改为未写注释的公开声明。源码可解析，但质量门槛失败；预览不能提交这次失败构建的文件。脚本在结束时恢复原文件和配置。

```bash
set -eu
mkdir -p target
BACKUP="$(mktemp -d target/cjdoc-preview-backup.XXXXXX)"
cp src/api.cj "$BACKUP/api.cj"
if test -f cjdoc.toml; then
  cp cjdoc.toml "$BACKUP/cjdoc.toml"
  HAD_CONFIG=1
else
  HAD_CONFIG=0
fi
restore() {
  cp "$BACKUP/api.cj" src/api.cj
  if test "$HAD_CONFIG" -eq 1; then
    cp "$BACKUP/cjdoc.toml" cjdoc.toml
  else
    rm -f cjdoc.toml
  fi
  rm -rf "$BACKUP"
}
trap restore EXIT HUP INT TERM

BEFORE_BUILD="$(curl -fsS http://127.0.0.1:8080/__cjdoc/status.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["builds"])')"
BEFORE_SUCCESSFUL="$(curl -fsS http://127.0.0.1:8080/__cjdoc/status.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["successfulBuilds"])')"
cat > cjdoc.toml <<'TOML'
[coverage]
symbols = 100
TOML
cat > src/api.cj <<'CJ'
package docdemo

public func greet(name: String): String {
    return "Hello, ${name}!"
}
CJ
for attempt in {1..60}; do
  STATUS="$(curl -fsS http://127.0.0.1:8080/__cjdoc/status.json)"
  if printf '%s' "$STATUS" | python3 -c 'import json,sys; s=json.load(sys.stdin); raise SystemExit(0 if s["status"] == "error" and s["successfulBuilds"] == int(sys.argv[1]) and s["builds"] > int(sys.argv[2]) else 1)' "$BEFORE_SUCCESSFUL" "$BEFORE_BUILD"; then
    break
  fi
  sleep 0.5
done
printf '%s' "$STATUS" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["status"] == "error" and s["successfulBuilds"] == int(sys.argv[1]) and s["builds"] > int(sys.argv[2]); print(s)' "$BEFORE_SUCCESSFUL" "$BEFORE_BUILD"
curl -fsS -o /dev/null http://127.0.0.1:8080/

restore
trap - EXIT HUP INT TERM
for attempt in {1..60}; do
  STATUS="$(curl -fsS http://127.0.0.1:8080/__cjdoc/status.json)"
  if printf '%s' "$STATUS" | python3 -c 'import json,sys; s=json.load(sys.stdin); raise SystemExit(0 if s["status"] == "ok" and s["successfulBuilds"] > int(sys.argv[1]) else 1)' "$BEFORE_SUCCESSFUL"; then
    break
  fi
  sleep 0.5
done
printf '%s' "$STATUS" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["status"] == "ok" and s["successfulBuilds"] > int(sys.argv[1]); print(s)' "$BEFORE_SUCCESSFUL"
```

失败状态应增加 `builds`、保持 `successfulBuilds` 不变并显示 `status: error`；即使如此首页仍可读取，证明上次成功的输出保留。还原后观察状态回到 `ok`。文件观察依据文件清单、大小和修改时间；不要把本地输出目录当输入，也不要在服务运行时手动修改生成文件。

## 处理端口占用并停止服务

如果启动时端口已被占用，停止另一个监听进程，或在重新启动时同时替换端口，例如：

```bash
cjdoc serve --project . --port 8081
```

在运行服务的终端按 `Ctrl+C` 停止。若 `--open` 无法启动浏览器，命令会打印本地 URL；可手动打开它。状态 URL、文件观察范围和其它 CLI 选项见[CLI 参考](../reference/cli.md)。

## 下一步

- [生成并发布文档](generate-and-publish.md)：把静态文件发布到托管平台。
- [管理输出与缓存](manage-outputs.md)：处理重建、输出冲突和缓存位置。
- [排查常见故障](troubleshoot.md)：按错误现象定位问题。
