# cjdoc 用户手册

cjdoc 把仓颉源码里的文档注释生成为 API 站点。这份手册对应 cjdoc 0.7.8，分四部分：

| 部分 | 什么时候读 |
|---|---|
| [第一次使用](#第一次使用) | 还没用过 cjdoc，想从安装一路做到可发布的站点 |
| [按任务操作](#按任务操作) | 已经会基本用法，要完成一件具体的事 |
| [查规则](#查规则) | 需要某个选项、配置键、标签或状态的准确定义 |
| [排错](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/troubleshoot.md) | 命令报错，或结果与预期不符 |

## 第一次使用

四篇文章前后衔接，使用同一个没有外部依赖的 `docdemo` 静态库。按顺序完成：

| 顺序 | 文章 | 完成后你会得到 |
|---|---|---|
| 1 | [安装 cjdoc](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/getting-started/install.md) | 任意目录下可运行的 `cjdoc` 命令 |
| 2 | [生成第一个站点](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/tutorials/first-site.md) | 一个带注释的函数，以及能在浏览器里打开的 API 页面 |
| 3 | [加入首页和指南](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/tutorials/add-guides.md) | 项目首页、包概述和一篇与 API 互相链接的指南 |
| 4 | [发布中英文](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/tutorials/publish-languages.md) | 读者可以切换语言的中英文站点 |

## 按任务操作

每篇指南解决一件事：需要什么前提、执行哪些命令、会看到什么结果、失败时怎么处理。

### 编写与发布

| 你要完成的事 | 指南 |
|---|---|
| 生成 HTML 站点并发布到静态托管 | [生成与发布](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/generate-and-publish.md) |
| 边改注释边看页面 | [实时预览](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/preview.md) |
| 找出缺失或失效的注释，设置覆盖率门槛 | [检查质量](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/check-quality.md) |
| 编译并运行注释里的示例，核对输出 | [检查示例](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/check-examples.md) |
| 对照实现核对参数、返回值、异常等说明 | [核对 API 说明与实际行为](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/review-contracts.md) |

### 项目输入与输出

| 你要完成的事 | 指南 |
|---|---|
| 决定哪些模块、依赖、条件编译分支和可见范围进入文档 | [选择输入](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/select-inputs.md) |
| 更换输出目录、处理目录被占用或锁定、设置缓存 | [管理输出](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/manage-outputs.md) |
| 不重新读取源码，从保存的快照生成 HTML 或 Markdown | [重渲染快照](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/render-snapshots.md) |
| 让类型跳转到依赖库、标准库的文档，或跳转到源码 | [链接外部文档](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/link-documentation.md) |
| 比较两个版本的 API，发布可切换版本的站点 | [比较 API 与发布版本](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/compare-and-version.md) |

### 工具接入与可选能力

| 你要完成的事 | 指南 |
|---|---|
| 从命令行查询文档快照，或为编辑器和 Agent 配置本地 MCP 服务 | [query 与 MCP](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/query-and-mcp.md) |
| 用编译器信息补充类型与签名 | [使用 CHIR](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/chir.md) |
| 关闭代码高亮，或为仓颉以外的语言启用高亮 | [配置高亮](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/highlighting.md) |

### 出了问题

| 你要完成的事 | 指南 |
|---|---|
| 按看到的报错或现象找到原因和处理办法 | [按症状排错](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/troubleshoot.md) |

## 查规则

| 参考 | 查什么 |
|---|---|
| [CLI](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/cli.md) | 命令、选项、取值范围、默认值和退出码 |
| [配置](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/configuration.md) | `cjdoc.toml` 的表、键与约束 |
| [文档注释](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/doc-comments.md) | 注释与声明的对应、标签、语言属性、分组和提示 |
| [产物](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/artifacts.md) | 各输出格式的目录结构和文件用途 |
| [查询协议](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/query-protocol.md) | `query` 与 MCP 的请求、结果、分页和快照选择 |
| [状态与限制](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/states-and-limits.md) | 结果状态的含义、平台差异、资源上限和安全边界 |

## 版本与开发

- [发布记录](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/release-notes.md)：每个版本的变化和升级步骤。
- [维护者文档](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/README.md)：修改 cjdoc 本身、运行本地检查或准备发行版。
