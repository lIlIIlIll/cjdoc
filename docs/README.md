# cjdoc 用户手册

从仓颉源码注释生成可直接打开的 API 文档。本手册对应**当前源码**：先安装与手册同提交的工具；发行包请按 `release-manifest.json.sourceCommit` 阅读其自己的手册，不以相同版本字符串代替源码身份。

## 第一次使用

按顺序完成一个无依赖的 `docdemo` 静态库。每篇提供所需文件、起始目录、命令和成功判据。

1. [安装当前源码工具](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/getting-started/install.md)：STS 1.2.0、静态 stdx、源码提交、安装前缀与发行包替代入口。
2. [生成第一个站点](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/tutorials/first-site.md)：空目录初始化，写 `greet`，编译、运行示例并阅读 HTML。
3. [加入首页和指南](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/tutorials/add-guides.md)：包概述、稳定章节与 API 双向关联。
4. [发布中英文](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/tutorials/publish-languages.md)：作者译文、页面配对和等价章节切换，不自动翻译。

## 按任务操作

| 你要完成的事 | 操作指南 |
|---|---|
| 生成六种格式、阅读、搜索和静态发布 | [生成与发布](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/generate-and-publish.md) |
| 在本地或 CI 检查文档与覆盖率 | [检查质量](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/check-quality.md) |
| 编译/运行注释示例，固定输出或预期失败 | [检查示例](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/check-examples.md) |
| 修改输入后自动重建并查看状态 | [实时预览](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/preview.md) |
| 选择 workspace、依赖、条件编译和受众 | [选择输入](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/select-inputs.md) |
| 管理所有权、事务、缓存、并发和预算 | [管理输出](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/manage-outputs.md) |
| 比较两份真实源码、组合多版本站点 | [比较 API 与发布版本](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/compare-and-version.md) |
| 移走源码后从当前 Doc IR 重放 | [离线重放](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/render-snapshots.md) |
| 关联源码、依赖库库存和标准库文档 | [链接外部文档](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/link-documentation.md) |
| 查询固定快照，向客户端提供 stdio MCP | [query 与 MCP](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/query-and-mcp.md) |
| 通过真实 worker 补充结构化语义 | [使用 CHIR](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/chir.md) |
| 选择内置/关闭/外部代码高亮 | [配置高亮](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/highlighting.md) |
| 从实现与真实消费者核对作者说明 | [作者契约复核](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/review-contracts.md) |
| 按错误症状找到修复入口 | [排错](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/troubleshoot.md) |

## 查规则

| 参考 | 单一真值 |
|---|---|
| [CLI](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/cli.md) | 命令、选项适用范围、默认值、优先级与退出码 |
| [配置](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/configuration.md) | `cjdoc.toml` 的完整表、键与约束 |
| [注释](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/doc-comments.md) | 声明绑定、标签、语言属性、分组和提示 |
| [产物](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/artifacts.md) | 六格式目录、机器读取文件与各自 wire 版本 |
| [查询协议](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/query-protocol.md) | request/result、工具、cursor 与快照身份 |
| [状态与限制](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/states-and-limits.md) | 部分/歧义/缺译、平台、资源与安全边界 |

## 维护项目

[维护者入口](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/README.md)负责构建门禁、schema、发布、性能和研究证据；不属于首次使用的前置课程。[发布历史](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/release-notes.md)记录历史版本，不代表当前提交已经通过本轮验证。
