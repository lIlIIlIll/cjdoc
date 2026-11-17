# 从空目录生成第一个 API 站点

跟着本页从零写出一个没有外部依赖的静态库 `docdemo`，编译它、检查注释里的示例、生成站点，最后在浏览器里读到 `greet` 的签名、参数、返回值和示例。

**完成后你会得到**：项目根下的 `target/doc/html/index.html`，用浏览器直接打开就能阅读，不需要服务器。之后可以继续[加入指南](add-guides.md)和[发布中英文](publish-languages.md)，两篇教程复用这个库。

## 前提条件

- 已按[安装 cjdoc](../getting-started/install.md)安装 `cjdoc`，并在当前终端加载了仓颉 SDK 环境。
- 一个空的工作目录，不要用 cjdoc 源码目录。

先确认命令可用：

```bash
command -v cjdoc
cjdoc --version
```

第一条命令输出 `cjdoc` 的绝对路径，第二条输出 `cjdoc 0.7.9`。如果第二条报 `error while loading shared libraries`，回到安装页重新加载 SDK 环境。

## 1. 创建静态库

在空目录里执行：

```bash
cjpm init --name docdemo --path docdemo --type=static
cd docdemo
```

预期输出 `cjpm init success`，并生成 `docdemo/cjpm.toml` 和空目录 `docdemo/src/`。

这个库不依赖 stdx，把 `cjpm.toml` 完整替换为：

```toml
[package]
name = "docdemo"
version = "0.1.0"
cjc-version = "1.2.0"
output-type = "static"

[dependencies]
```

## 2. 添加一个带注释的公开函数

新建完整文件 `src/api.cj`：

~~~cangjie
package docdemo

/**
 * 为名字生成问候语。
 *
 * name 原样保留，不修剪空白；空字符串返回 `Hello, !`。
 *
 * @param name 要问候的名字，可以为空。
 * @return 格式为 `Hello, <name>!` 的字符串。
 * @example 问候仓颉 {must-pass run}
 * ```cangjie
 * println(greet("Cangjie"))
 * ```
 * ```output
 * Hello, Cangjie!
 * ```
 */
public func greet(name: String): String {
    return "Hello, ${name}!"
}

// 普通注释不会绑定为文档；此声明也不属于默认公开受众。
private func internalGreeting(): String {
    return "internal"
}
~~~

`/** ... */` 是文档注释，摘要、`@param`、`@return` 和 `@example` 都写在其中；普通 `//` 和 `/* ... */` 不会成为文档正文。

`@example` 的代码围栏和 `output` 围栏成对出现，`{must-pass run}` 表示这个示例必须编译通过并实际运行。默认受众是 `external`，页面显示 `public` 和 `protected` 声明：`greet` 即使没有写文档注释也会出现在页面上，只是没有摘要、参数和返回说明；`internalGreeting` 是 `private` 声明，默认视图里没有它。`--audience package` 或 `--audience all` 可以扩大展示范围，这只改变文档视图，不是删除敏感源码的保护措施；发布前请检查你实际放进输出的文件。

## 3. 编译、核对示例并生成 HTML

仍在 `docdemo/` 根目录执行：

```bash
cjpm build
cjdoc check --project . --check-examples
cjdoc generate --project . --format html
```

三条命令的预期结果：

1. `cjpm build` 编译这个库，最后一行是 `cjpm build success`。因为 `internalGreeting` 没有被调用，它还会打印一条 `warning: unused function:'internalGreeting'`，这是编译器提示，不影响构建。
2. `cjdoc check --project . --check-examples` 编译注释里的 `@example` 代码，运行标了 `run` 的示例，把实际输出与 `output` 围栏比较。这里应匹配 `Hello, Cangjie!`，命令以退出码 `0` 结束。
3. `cjdoc generate --project . --format html` 读取同一份源码，默认用配套 CHIR worker 补充类型信息，生成 `target/doc/html/index.html`，并以退出码 `0` 结束。

默认 CHIR 分析成功时，`String` 的类型信息来自编译器。如果选择 `--semantic source`，或 worker 无法补充语义，可能看到 `CJDOC3041` 类型链接 warning；它不表示注释中的示例运行失败。加 `--deny-warnings` 才会让这类 warning 导致退出码 `1`。

`generate` 的项目编译用于语义补充，不会编译或运行注释中的示例；示例是否成立仍以第二条命令的结果为准。示例检查需要能建立进程资源限制的环境，限制和诊断码见[检查示例](../how-to/check-examples.md)。未配置输出格式且省略 `--format` 时默认生成 JSON（`target/doc/docs.json`），不会产生 HTML。

## 4. 在浏览器里阅读 `greet`

在项目根执行：

```bash
xdg-open target/doc/html/index.html
```

macOS 使用 `open target/doc/html/index.html`，Windows PowerShell 使用 `Start-Process .\target\doc\html\index.html`。页面是纯静态文件，也可以直接用浏览器的“打开文件”选择同一个 `index.html`，或把 `file:///` 开头的绝对路径粘贴到地址栏，不需要启动服务器。

预期看到的结果：

- 首页标题是 `docdemo API 文档`，页面主体列出包 `docdemo` 和 1 个声明，并提供 `继续阅读`（进入概念文档或 API 参考）和 `API 参考` 入口。
- 进入包 `docdemo` 再进入 `greet`，页面依次给出签名 `public func greet(name: String): String`、正文“name 原样保留，不修剪空白”、参数 `name` 的说明、返回值说明“格式为 `Hello, <name>!` 的字符串”、示例代码及其 `Hello, Cangjie!` 输出。
- 默认公开视图里没有 `internalGreeting`；`greet` 之所以出现，是因为它是公开声明，与是否写了注释无关。

页面只展示示例的内容和预期输出，不会标记它是否真的执行过；示例有没有实际运行，以第 3 步 `cjdoc check --check-examples` 的结果为准。

生成的目录结构是固定的：`target/doc/html/index.html` 是入口，`packages/` 存放包页，`symbols/` 存放声明页，`search-index.*`、`style.css` 供页面内导航和搜索使用。整个 `html/` 目录可以原样复制或上传。

修改注释后重新执行 `cjdoc generate --project . --format html`，再刷新页面就能看到新内容。想边写边看，用 `cjdoc serve` 自动重建，见[预览文档](../how-to/preview.md)；搜索、深链和 HTTP 发布见[生成与发布](../how-to/generate-and-publish.md)。

## 失败时怎么办

- **`cjpm build` 报找不到 `cjpm`**：当前终端没有加载 SDK 环境，执行 `. "$CANGJIE_SDK_ROOT/envsetup.sh"` 后重试。
- **`cjdoc` 报 `error while loading shared libraries`**：同上，是 SDK 运行库没有加载，不是安装损坏。
- **生成报项目根错误**：用 `pwd` 确认当前目录含 `cjpm.toml`，不要停在 `src/`；也可以从任意目录传入 `--project /你的项目根`。项目根不对时报 `error[CJDOC1010]: project must contain cjpm.toml` 并以 `1` 退出。
- **打不开页面或看不到更新**：确认打开的是当前项目下的 `target/doc/html/index.html`，不要停在 cjdoc 源码目录的 `target/`；浏览器缓存旧页面时强制刷新。
- **示例检查报 `error[CJDOC3072]`**：`output` 围栏与程序实际输出不一致，错误信息里同时给出期望值和实际值，按实际输出改围栏或改实现。
- **示例检查报 `CJDOC3074`**：当前平台无法建立示例运行所需的地址空间限制，带 `run` 的示例被拒绝执行。这不影响 `generate` 生成 HTML，但示例没有实际运行；平台差异见[状态与限制](../reference/states-and-limits.md)。

## 下一步

- [加入首页、包概述和指南](add-guides.md)。
- [检查文档质量](../how-to/check-quality.md)。
- [注释语法参考](../reference/doc-comments.md)。
