# cjdoc 用户手册

用 cjdoc 将仓颉源码注释生成为 API 站点，加入指南和中英文说明，检查文档与示例，再发布完整的静态网站。需要接入编辑器或 Agent 时，也可以查询保存的文档快照。

## 第一次使用

按顺序为一个无依赖的 `docdemo` 静态库生成文档：

1. [安装 cjdoc](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/getting-started/install.md)：准备仓颉环境，将命令加入 PATH。
2. [生成第一个站点](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/tutorials/first-site.md)：创建库、写函数注释，编译并打开 API 页面。
3. [加入首页和指南](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/tutorials/add-guides.md)：介绍项目，并让读者在指南和 API 之间跳转。
4. [发布中英文](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/tutorials/publish-languages.md)：提供译文，让读者切换语言和对应章节。

## 按任务操作

### 日常编写与发布

| 你要完成的事 | 操作指南 |
|---|---|
| 生成 HTML、搜索 API 并发布整个站点 | [生成与发布](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/generate-and-publish.md) |
| 检查文档质量，在本地或 CI 设置覆盖率门槛 | [检查质量](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/check-quality.md) |
| 编译或运行注释示例，核对输出及预期失败 | [检查示例](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/check-examples.md) |
| 保存修改后预览新页面 | [实时预览](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/preview.md) |
| 按错误现象恢复生成、检查或预览 | [排错](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/troubleshoot.md) |

### 组织项目与站点

| 你要完成的事 | 操作指南 |
|---|---|
| 选择 workspace、依赖、条件编译和声明可见范围 | [选择输入](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/select-inputs.md) |
| 复用输出目录、处理文件冲突并设置缓存位置 | [管理输出](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/manage-outputs.md) |
| 比较两个版本的 API，发布可切换版本的站点 | [比较 API 与发布版本](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/compare-and-version.md) |
| 从保存的快照重新生成 HTML 或 Markdown | [重渲染快照](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/render-snapshots.md) |
| 跳转到依赖库、标准库文档和源码 | [链接外部文档](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/link-documentation.md) |

### 接入工具与可选能力

| 你要完成的事 | 操作指南 |
|---|---|
| 搜索固定快照，为客户端配置本地 MCP 服务 | [query 与 MCP](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/query-and-mcp.md) |
| 为声明补充类型与签名信息 | [使用 CHIR](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/chir.md) |
| 关闭代码高亮或为其它语言启用外部高亮 | [配置高亮](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/highlighting.md) |

### 核对 API 说明

| 你要完成的事 | 操作指南 |
|---|---|
| 对照实现核对输入、返回、异常和状态承诺 | [核对 API 说明与实际行为](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/how-to/review-contracts.md) |

## 查规则

| 参考 | 查什么 |
|---|---|
| [CLI](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/cli.md) | 命令、选项适用范围、默认值、优先级与退出码 |
| [配置](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/configuration.md) | `cjdoc.toml` 的表、键与约束 |
| [注释](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/doc-comments.md) | 声明绑定、标签、语言属性、分组和提示 |
| [产物](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/artifacts.md) | 六格式目录与机器读取文件 |
| [查询协议](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/query-protocol.md) | 请求、结果、分页与快照选择 |
| [状态与限制](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/reference/states-and-limits.md) | 部分结果、歧义、缺译、平台、资源与安全边界 |

## 维护项目

修改 cjdoc、运行构建门禁或准备发行版，请看[维护者入口](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/README.md)。版本变化见[发布历史](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/release-notes.md)。
