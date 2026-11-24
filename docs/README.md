# cjdoc 用户手册

已有仓颉项目？[安装 cjdoc](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/getting-started/install.md)后，在含 `cjpm.toml` 的项目根执行 `cjdoc generate --project . --format html`。生成后用浏览器打开默认入口 `target/doc/html/index.html`。

本手册与源码一起更新。使用预编译包时，请阅读 [v0.7.9 手册](https://github.com/lIlIIlIll/cjdoc/tree/v0.7.9/docs)或所用版本的对应手册。

## 第一次使用

没有项目也可以从头练习。以下教程沿用同一个 `docdemo` 库：

| 步骤 | 读完能做什么 |
|---|---|
| [安装 cjdoc](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/getting-started/install.md) | 在任意项目里运行 `cjdoc` |
| [从空目录生成第一个站点](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/tutorials/first-site.md) | 给一个函数写注释，在浏览器里找到它的 API 页面 |
| [加入首页、包概述和指南](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/tutorials/add-guides.md) | 写独立的 Markdown 页面，并让它们和 API 互相链接 |
| [发布中英文](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/tutorials/publish-languages.md) | 让读者切换同一个 API 或指南小节的语言 |

## 按任务操作

### 编写与发布

| 你要完成的事 | 指南 |
|---|---|
| 照着真实 API 写字段、提示、示例和译文 | [PocketKit 文档注释示例](https://github.com/lIlIIlIll/cjdoc/blob/main/examples/pocketkit/demo-v2/docs/doc-comments.md) |
| 让 Agent 读实现、补注释并核对 API 详情页 | [让 Agent 编写 API 注释](../README.md#让-agent-编写-api-注释) |
| 生成站点并上传到静态托管 | [生成与发布](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/generate-and-publish.md) |
| 保存注释或指南后查看新页面 | [实时预览](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/preview.md) |
| 找到漏写的字段，设置覆盖率门槛 | [检查质量](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/check-quality.md) |
| 编译注释里的片段，检查成功、预期失败或运行输出 | [检查示例](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/check-examples.md) |
| 检查参数、返回值和异常说明是否符合实现 | [复核 API 说明](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/review-contracts.md) |

### 项目输入与输出

| 你要完成的事 | 指南 |
|---|---|
| 决定哪些包、依赖、条件编译分支及声明进入文档 | [选择输入](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/select-inputs.md) |
| 换输出目录、处理写入冲突或重建缓存 | [管理输出](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/manage-outputs.md) |
| 从保存的 Doc IR 生成新页面，不重新扫描项目 | [重渲染快照](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/render-snapshots.md) |
| 链接到依赖库、标准库文档或仓库源码 | [链接外部文档](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/link-documentation.md) |
| 找出 API 的版本变化，发布可切换版本的站点 | [比较 API 与发布版本](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/compare-and-version.md) |

### 工具接入与可选能力

| 你要完成的事 | 指南 |
|---|---|
| 查询指定版本的文档，或给编辑器配置本地 MCP | [命令行查询与 MCP](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/query-and-mcp.md) |
| 用编译器补充类型信息，处理语义分析告警 | [使用 CHIR](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/chir.md) |
| 关闭高亮，或让其他语言的代码也有高亮 | [配置高亮](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/highlighting.md) |

命令失败、页面看不到改动或链接跳转异常？按[症状排错](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/troubleshoot.md)查处理方法。

## 查规则

| 参考 | 查什么 |
|---|---|
| [命令行](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/cli.md) | 命令、选项、默认值和退出码 |
| [`cjdoc.toml`](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/configuration.md) | 项目配置的表、键、默认值和约束 |
| [文档注释和指南](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/doc-comments.md) | 注释如何绑定声明、标签、围栏、提示和指南链接 |
| [输出文件](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/artifacts.md) | 各格式写到哪里、文件交给谁使用 |
| [查询协议](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/query-protocol.md) | 请求和结果字段、分页、快照选择 |
| [状态与限制](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/states-and-limits.md) | 结果的可信范围、资源上限和平台差异 |

## 版本与开发

- [发布记录](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/release-notes.md)：版本变化及升级注意事项。
- [维护者文档](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/README.md)：修改和发布 cjdoc 本身。
