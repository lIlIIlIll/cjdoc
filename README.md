# cjdoc

cjdoc 是一个命令行工具：它读取 Cangjie 项目的源码和文档注释，生成可直接打开的 HTML、Markdown 和 JSON API 文档。

如果你第一次使用 cjdoc，先完成下面的快速开始。进阶任务见 [`docs/usage.md`](docs/usage.md) 和 [`docs/advanced-usage.md`](docs/advanced-usage.md)。

## 快速开始

### 准备项目

你需要一个 Cangjie 项目根目录。目录中至少有一个 `cjpm.toml` 和一个 `src/` 源码目录：

```text
my-project/
├── cjpm.toml
└── src/
    └── api.cj
```

### 安装并确认 cjdoc

从 [Releases](https://github.com/lIlIIlIll/cjdoc/releases) 下载与你的平台匹配的文件。发布页实际提供的文件才是可用安装包；当前构建支持以下平台名称：

| 平台 | 可执行文件名称 |
|---|---|
| Linux x64 | `cjdoc-<version>-linux-x64` |
| macOS ARM64 | `cjdoc-<version>-macos-arm64` |
| Windows x64 | `cjdoc-<version>-windows-x64.exe` |

解压后，把可执行文件放到一个目录，并把这个目录加入 `PATH`。如果独立可执行文件的文件名带有版本号，请将它改名为 `cjdoc`；Windows 改名为 `cjdoc.exe`。Linux 和 macOS 需要确保文件具有执行权限。打开一个新终端，确认命令可用：

Linux/macOS 可以这样安装到当前用户目录：

```bash
chmod +x cjdoc-<version>-<platform>
mkdir -p ~/.local/bin
mv cjdoc-<version>-<platform> ~/.local/bin/cjdoc
export PATH="$HOME/.local/bin:$PATH"
```

把 `~/.local/bin` 加入你的 shell 配置文件，之后的新终端也会自动找到 `cjdoc`。Windows 用户将 `cjdoc.exe` 放到例如 `C:\Tools\cjdoc`，再在“环境变量”的用户 `Path` 中加入这个目录；重新打开终端即可。

```bash
cjdoc --version
```

当前版本应看到类似下面的输出：

```text
cjdoc 0.7.1
```

如果发布页没有对应平台的文件，请不要猜文件名或下载地址。源码构建说明位于 [`docs/advanced-usage.md`](docs/advanced-usage.md#从源码构建维护者用)。

### 1. 给公开 API 写文档注释

在你自己的 `.cj` 文件中，把 `/** ... */` 放在要生成文档的 `public` 声明前面。下面的例子会在页面中生成函数摘要、参数说明和返回值说明。

`src/api.cj`：

```cangjie
/**
 * 计算两个整数的和。
 *
 * @param left 左侧数值。
 * @param right 右侧数值。
 * @return 两数之和。
 */
public func add(left: Int64, right: Int64): Int64 {
    return left + right
}
```

普通的 `//` 和 `/* ... */` 注释不会绑定到 API 声明。默认输出面向项目外部使用者，只展示 `public` 和 `protected` 声明。

### 2. 生成 HTML

进入项目根目录，运行生成命令。默认输出目录是项目下的 `target/doc`。

```bash
cd <你的项目目录>
cjdoc generate --project . --format html
```

成功时终端会打印类似下面的结果：

```text
generated <你的项目目录>/target/doc
```

### 3. 打开文档

直接打开下面的文件：

```text
<你的项目目录>/target/doc/html/index.html
```

这是静态站点，不需要启动服务器。修改注释后再次运行同一条 `generate` 命令，再刷新页面即可看到新内容。

## 常用命令

| 目的 | 命令 | 主要产物 |
|---|---|---|
| 生成 HTML | `cjdoc generate --project . --format html` | `target/doc/html/index.html` |
| 生成 Markdown | `cjdoc generate --project . --format markdown` | `target/doc/markdown/index.md` |
| 生成 JSON | `cjdoc generate --project . --format json` | `target/doc/docs.json` |
| 检查文档问题 | `cjdoc check --project .` | 终端诊断，成功退出码为 `0` |

一次生成多个格式：

```bash
cjdoc generate --project . \
  --format json \
  --format markdown \
  --format html
```

`--format` 可以重复指定。完整任务说明见 [`docs/usage.md`](docs/usage.md)；workspace、依赖、条件编译、缓存和 CI 见 [`docs/advanced-usage.md`](docs/advanced-usage.md)。

## 常见问题

### `cjdoc: command not found`

可执行文件所在目录没有加入当前终端的 `PATH`。加入后打开新终端，再运行 `cjdoc --version`。

### 提示项目必须包含 `cjpm.toml`

`--project` 必须指向项目根目录，而不是 `src/` 目录：

```bash
cjdoc generate --project /path/to/my-project --format html
```

### 页面里没有我的声明

先确认三件事：声明是 `public` 或 `protected`，注释使用 `/** ... */`，并且命令指向正确的项目目录。如果你要查看内部声明，使用：

```bash
cjdoc generate --project . --format html --audience all
```

### 修改注释后页面没有变化

重新运行 `cjdoc generate ...`，确认打开的是同一个项目下的 `target/doc/html/index.html`，然后刷新浏览器页面。

## 当前边界

- 当前输出版本是 `cjdoc.doc-ir/8`。普通用户不需要直接编辑这个 JSON。
- 无法展开的宏、没有提供的条件编译输入和部分不支持的源码会产生诊断，并可能使结果标为 `partial`。
- cjdoc 不会替你下载依赖源码。需要把依赖纳入文档时，按 [`docs/advanced-usage.md`](docs/advanced-usage.md) 的说明提供路径或 cache。

## 其他文档

- [`docs/usage.md`](docs/usage.md)：常用任务和文档注释写法。
- [`docs/advanced-usage.md`](docs/advanced-usage.md)：多格式、workspace、依赖、缓存、CI 和维护者用法。
- [`docs/release-process.md`](docs/release-process.md)：发布与验收流程，面向维护者。
- [`docs/research/`](docs/research/)：源码解析能力和架构决策记录，面向维护者。
