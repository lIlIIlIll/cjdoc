# 预览文档并随修改重建

改源码注释或 Markdown 后，用本地预览看新页面，不必每次手动运行 `generate`。先[安装 cjdoc](../getting-started/install.md)，打开已加载仓颉 SDK 的终端，进入含 `cjpm.toml` 的项目根。

## 1. 启动预览

选一个空闲端口，在项目根运行：

```bash
cjdoc serve --project . --port 8080
```

终端打印 `serve: http://127.0.0.1:8080/`。等到出现 `serve: generated html` 后，在浏览器打开这个地址。本地服务只监听 `127.0.0.1`，不能当作公开托管。

加 `--open` 可以请求系统打开浏览器。如果终端提示无法打开，手动访问打印的地址即可。端口已占用时，改用 `--port 8081` 等空闲端口，浏览器地址也一起改。

## 2. 修改注释并刷新

保持终端里的服务运行。改一个公开声明的摘要并保存；如果在做[第一个站点](../tutorials/first-site.md)，可以修改 `src/api.cj` 中 `greet` 的第一段注释。等终端打印新一轮生成结果，再刷新浏览器，确认摘要已变。

服务会监视 `.cj`、`.md`、`cjpm.toml`、`cjpm.lock` 和 `cjdoc.toml` 的变化。浏览器不会自动刷新。改了输出或缓存位置则要重启预览服务。

## 3. 检查最近一次构建状态

在另一个终端请求同一端口：

```bash
curl -fsS http://127.0.0.1:8080/__cjdoc/status.json
```

一次成功生成后的响应示例：

```json
{"schemaVersion":"cjdoc.serve-status/1","status":"ok","port":8080,"builds":1,"successfulBuilds":1,"lastError":""}
```

`builds` 计入失败尝试，`successfulBuilds` 只计成功。`status: "error"` 表示最近一轮失败；根据 `lastError` 和预览终端的诊断修正输入，再保存。下一次成功后 `lastError` 会清空。字段及其他选项见 [`serve` 参考](../reference/cli.md#serve)。

## 4. 停止预览

在服务终端按 `Ctrl+C`，终端恢复提示符，端口释放。要让其他人访问，请[生成并发布静态站点](generate-and-publish.md)。

## 失败时怎么办

| 看到什么 | 怎么处理 |
|---|---|
| `Address already in use` | 换空闲端口，或停止占用该端口的预览 |
| 浏览器无法连接，且命令已退出 | 查看终端错误，核对项目根与配置后重启 |
| `keeping the last successful site` | 上次成功的页面仍可读；修复本轮配置或输入错误。若提示输出或缓存位置变更，重启服务 |
| `generated html with diagnostics` | 看终端诊断和状态接口。修正错误后重新保存，不要仅根据页面是否可打开判断构建状态 |
| 输出目录或锁冲突 | 先停止正在运行的生成或预览，再按[管理输出](manage-outputs.md)处理 |
