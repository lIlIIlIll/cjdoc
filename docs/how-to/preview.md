# 预览文档并随修改重建

用 `cjdoc serve` 在本地浏览器里阅读站点；保存源码或指南后，服务重新生成页面，刷新浏览器即可看到新内容。

## 前提条件

- 已完成[生成第一个站点](../tutorials/first-site.md)，能从 `docdemo/` 项目根运行命令。
- 当前终端能运行 `cjdoc`，并已加载仓颉 SDK 环境。
- 选用的端口空闲。本页示例使用 `127.0.0.1:8080`。
- 预览只监听回环地址 `127.0.0.1`，不对外提供访问。

## 1. 启动预览

从项目根启动服务，让这个终端保持占用：

```bash
cjdoc serve --project . --port 8080
```

**预期结果**

- 终端先打印 `serve: http://127.0.0.1:8080/`。
- 首次生成完成后打印 `serve: generated html`（有诊断时为 `serve: generated html with diagnostics`）。
- 浏览器打开 `http://127.0.0.1:8080/` 能看到站点，可进入 `docdemo` 包的 `greet` 页面。

加 `--open` 可在启动后请求系统打开浏览器；系统无法启动浏览器时终端打印 `serve: unable to open a browser; visit http://127.0.0.1:8080/`，手动打开该地址即可。

## 2. 修改注释并刷新

保持服务运行，把 `src/api.cj` 中 `greet` 的摘要行改为：

```text
 * 为指定名字生成问候语。
```

保存文件，等终端再次打印生成结果后刷新浏览器。

**预期结果**：`greet` 的摘要变成新的那句。预览监视 `.cj` 源码、`.md`、`cjpm.toml`、`cjpm.lock` 和 `cjdoc.toml`；已[加入指南](../tutorials/add-guides.md)时，编辑指南正文后保存、刷新同样生效。

预览不会自动刷新浏览器页面。看到终端生成完成后仍需手动刷新，也不要手工编辑输出目录里的 HTML。

## 3. 检查最近一次构建状态

需要从另一个终端确认构建结果时，读取状态接口：

```bash
curl -fsS http://127.0.0.1:8080/__cjdoc/status.json
```

**预期结果**：返回一个 JSON 对象，例如

```json
{"schemaVersion":"cjdoc.serve-status/1","status":"ok","port":8080,"builds":1,"successfulBuilds":1,"lastError":""}
```

| 字段 | 含义 |
|---|---|
| `status` | 最近一次构建成功为 `ok`，失败为 `error` |
| `builds` | 初次生成与后续重建的累计尝试次数，失败也计入 |
| `successfulBuilds` | 其中成功构建的累计次数 |
| `lastError` | 最近一次失败的提示（通常是 `documentation build failed`）；下一次成功后清空为 `""` |

端口改过时，状态 URL 使用同一个端口。字段的完整定义见[CLI 的 serve 参考](../reference/cli.md#serve)。

## 4. 停止预览

在运行服务的终端按 `Ctrl+C`。

**预期结果**：终端返回提示符，端口释放。需要独立静态站点时，改用[生成与发布](generate-and-publish.md)中的命令。

## 失败时怎么办

| 现象 | 原因 | 处理 |
|---|---|---|
| 启动即报 `error: Failed to bind 98: Address already in use.` | 端口已被其它进程占用 | 停掉占用该端口的预览，或换一个空闲端口启动，并把浏览器地址改成同一端口 |
| 浏览器打不开 `http://127.0.0.1:<port>/` 且终端已返回提示符 | 服务已退出，常见原因是 `--project` 指向的路径不可用 | 修正 `--project`，重新执行 `cjdoc serve` |
| 终端打印 `serve: rebuild failed; keeping the last successful site` | 重建时抛错（例如输出路径无法解析），服务仍在运行 | 读终端里的 `error:` 行修正输入；修正后保存触发重建，或重启服务 |
| 终端打印 `serve: generated html with diagnostics` 且页面还是旧的 | 本次构建有 error 级诊断，页面仍有上次内容 | 按终端诊断修正源码、指南或配置后再次保存 |
| `status` 为 `error` | 最近一次构建失败 | 查看 `lastError` 与终端诊断，修正后等重建；`ok` 之后再刷新页面 |

换端口的写法：

```bash
cjdoc serve --project . --port 8081
```

浏览器地址同时改为 `http://127.0.0.1:8081/`。若是输出目录或锁冲突，先停止仍运行的生成或预览，按[管理输出](manage-outputs.md)处理；不要删除无法确认归属的锁。

## 下一步

- [生成并发布完整静态站点](generate-and-publish.md)。
- [管理输出和缓存](manage-outputs.md)。
- [按症状排查故障](troubleshoot.md)。
