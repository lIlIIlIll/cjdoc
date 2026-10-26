# cjdoc 0.7.6 发布记录

`0.7.6` 用于重新准备发行。发布状态及可下载资产以 [Releases](https://github.com/lIlIIlIll/cjdoc/releases) 为准。

本版本包含以下改动：

- 收集 `public macro` 的源码签名、参数、返回类型和文档注释。
  恢复 `@Derive` 等宏包装内的源码声明、成员、可见性和位置；未展开调用继续保留不确定状态，不虚构生成成员。
- 由完整验收链负责产品构建，删除发行工作流前置的重复构建，并在验收成功后核验待打包的同一二进制。
- Windows 发行使用已在 CI 验收的 `windows-2022` runner。工具链、产品优化参数和测试断言保持原值。

Doc IR 仍为 v16。生成器版本改为 `0.7.6`，需要重新生成 current golden 和性能文档身份；此变化不代表新的性能测量结论。

## 保留的 0.7.5 记录

[`v0.7.5`](https://github.com/lIlIIlIll/cjdoc/tree/v0.7.5) 保留在提交
[`a1852d6`](https://github.com/lIlIIlIll/cjdoc/commit/a1852d68ae3ac06dc50f6273eeade8099dee223b)。
其[发行运行](https://github.com/lIlIIlIll/cjdoc/actions/runs/40362242523)在 macOS 和 Windows 的第二次产品构建中失败，未发布 GitHub Release。
`0.7.6` 使用新的发行身份，不移动旧 tag。本次修复调整构建执行图和 runner，编译器崩溃的根因仍未确定。
