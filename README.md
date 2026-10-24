# cjdoc

cjdoc 是仓颉的 API 文档生成器。它读取项目源码里的 `/** ... */` 文档注释，生成可以直接打开的 HTML 站点、Markdown 页面和 JSON 数据。产物都是静态文件，生成后不需要启动服务器。

如果你正在为仓颉库写文档，用 cjdoc 可以很快得到一份带摘要、参数、返回值、异常、示例和行为契约的参考文档。它只读取源码和注释，不会自动生成使用说明，也不会替你补写文档内容。

## 开始之前

你需要准备两样东西：

1. **仓颉 SDK**。cjdoc 依赖仓颉运行时，发布包**不包含** SDK。先安装仓颉 SDK，并按 SDK 自带的环境脚本（`envsetup`）配置好环境，确认下面两个命令可用：

   ```bash
   cjc -v
   cjpm -v
   ```

2. **一个仓颉项目**。项目根目录里要有 `cjpm.toml`，源码放在 `src/` 下：

   ```text
   my-project/
   ├── cjpm.toml
   └── src/
       └── api.cj
   ```

## 安装 cjdoc

从 [Releases](https://github.com/lIlIIlIll/cjdoc/releases) 下载 0.7.3 对应平台的文件。每个平台提供一个裸可执行文件和一个压缩包：

| 平台 | 裸可执行文件 | 压缩包 |
|---|---|---|
| Linux x64 | `cjdoc-0.7.3-linux-x64` | `cjdoc-0.7.3-linux-x64.tar.gz` |
| macOS ARM64 | `cjdoc-0.7.3-macos-arm64` | `cjdoc-0.7.3-macos-arm64.tar.gz` |
| Windows x64 | `cjdoc-0.7.3-windows-x64.exe` | `cjdoc-0.7.3-windows-x64.zip` |

下载页里同名的 `.sha256` 文件是校验文件。裸可执行文件里只有二进制；压缩包里还有 README、LICENSE、第三方声明和发布清单。

### 1. 校验下载的文件

在下载文件所在的目录执行。Linux：

```bash
sha256sum -c cjdoc-0.7.3-linux-x64.tar.gz.sha256
```

macOS：

```bash
shasum -a 256 -c cjdoc-0.7.3-macos-arm64.tar.gz.sha256
```

Windows PowerShell 分两步，把 `.sha256` 文件里的哈希和实际文件的哈希对比：

```powershell
Get-Content .\cjdoc-0.7.3-windows-x64.zip.sha256
(Get-FileHash .\cjdoc-0.7.3-windows-x64.zip -Algorithm SHA256).Hash.ToLower()
```

### 2. 放入 `PATH`

Linux 和 macOS 解压后把可执行文件改名放到一个已有或新建的用户目录，再把该目录加进 `PATH`。Linux 示例：

```bash
tar -xzf cjdoc-0.7.3-linux-x64.tar.gz
chmod +x cjdoc-0.7.3/cjdoc
mkdir -p ~/.local/bin
mv cjdoc-0.7.3/cjdoc ~/.local/bin/cjdoc
export PATH="$HOME/.local/bin:$PATH"
```

把最后一行 `export` 也加到你的 `~/.bashrc` 或 `~/.zshrc`，以后新开的终端也能找到 cjdoc。macOS 把文件名换成 `cjdoc-0.7.3-macos-arm64.tar.gz` 即可。

Windows 解压后把 `cjdoc.exe` 放到例如 `C:\Tools\cjdoc\cjdoc.exe`，然后在“环境变量”的用户变量 `Path` 中加入 `C:\Tools\cjdoc`，重新打开终端。

如果只下载了裸可执行文件：Linux/macOS 先 `chmod +x` 并改名为 `cjdoc`，Windows 改名为 `cjdoc.exe`，然后同样放入 `PATH` 中的目录。

发布页没有适合你平台的文件时，只能从源码构建（面向维护者）：见 [构建说明](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/build.md)。普通使用者优先使用发布资产。

### 3. 确认安装

```bash
cjdoc --version
```

```text
cjdoc 0.7.3
```

`cjdoc --help` 可以查看用法。只有顶层命令支持 `--help`，子命令没有单独的帮助；参数写错时，错误信息会附上用法并以退出码 `2` 结束。

## 三步生成第一份文档

### 1. 写文档注释

在你要公开的声明前面写 `/** ... */` 注释。例如 `src/api.cj`：

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

普通的 `//` 和 `/* ... */` 注释不会出现在文档里。默认只展示 `public` 和 `protected` 声明。

### 2. 生成 HTML

在项目根目录运行：

```bash
cjdoc generate --project . --format html
```

成功后会打印类似 `generated target/doc` 的一行。默认输出目录是项目下的 `target/doc`；不写 `--format` 时，cjdoc 只生成 JSON 数据（`docs.json`）。

### 3. 打开文档

用浏览器打开：

```text
target/doc/html/index.html
```

这是静态页面，双击即可，不需要服务器。改完注释后重新运行同一条命令，再刷新浏览器就能看到新内容。

## 常用任务

| 目的 | 命令 | 主要产物 |
|---|---|---|
| 生成 HTML | `cjdoc generate --project . --format html` | `target/doc/html/index.html` |
| 生成 Markdown | `cjdoc generate --project . --format markdown` | `target/doc/markdown/index.md` |
| 生成 JSON 数据 | `cjdoc generate --project . --format json` | `target/doc/docs.json` |
| 保存 API 快照 | `cjdoc generate --project . --format api-surface --stdout > api-surface.json` | `api-surface.json` |
| 查看文档覆盖率 | `cjdoc generate --project . --format coverage` | `target/doc/coverage/coverage.json` |
| 检查文档问题 | `cjdoc check --project .` | 终端诊断；没有问题时退出码为 `0` |
| 检查并运行示例 | `cjdoc check --project . --check-examples` | 按 `@example` 指令编译、运行示例 |
| 本地预览 | `cjdoc serve --project .` | 打开 `http://127.0.0.1:8080/`，改源码后自动重建 |
| 比较 API 变化 | `cjdoc diff --baseline old.json --current new.json --deny-breaking-api` | 终端或 JSON 报告；命中破坏性变化时退出码为 `1` |
| 从已有 JSON 重新生成 | `cjdoc render --input target/doc/docs.json --format html --output target/doc-rendered` | 重新渲染的 HTML |
| 查询固定文档 | `cjdoc query --snapshot target/doc/docs.json --request request.json` | 单个版本化 JSON 结果；不扫描或编译目标项目 |
| 接入本地 MCP | `cjdoc mcp --snapshot target/doc/html/agent/manifest.json` | 同一只读查询核心的 stdio 适配 |

一次生成多个格式时，重复写 `--format`：

```bash
cjdoc generate --project . \
  --format html \
  --format markdown \
  --format json
```

把 JSON 交给管道或其他工具时，用 `--stdout`：

```bash
cjdoc generate --project . --format json --stdout > docs.json
```

`--stdout` 与 `--output` 互斥，并且只允许恰好一个 JSON 类格式（`json`、`api-surface`、`coverage`、`symbol-index`）。诊断写到 stderr，所以重定向得到的文件仍是单个 JSON。

HTML 输出同时发布每个可见声明的独立 Markdown/JSON、`agent/manifest.json` 与可续取导航。`--agent-full` 另加完整单元的聚合全文和分片索引。身份选择、章节预算、离线部署与客户端配置见[逐声明读取、查询与 MCP](docs/agent-reading.md)；`serve` 仍用于项目预览和重建。

## 常见问题

### 提示 `cjdoc: command not found`（或 Windows 提示不是内部或外部命令）

`PATH` 还没有包含 cjdoc 所在目录。把目录加入 `PATH` 后重新打开终端，再运行 `cjdoc --version`。

### 启动时报缺少仓颉运行时库（Windows 上通常是 DLL）

说明仓颉 SDK 没有安装好，或者 SDK 的环境脚本没有在当前终端生效。安装 SDK，执行 SDK 自带的 `envsetup` 后重新打开终端，确认 `cjc -v` 可用。

### 提示项目必须包含 `cjpm.toml`

`--project` 要指向项目根目录，而不是 `src/` 子目录。这个错误会作为 error 诊断报告，命令退出码为 `1`：

```bash
cjdoc generate --project /path/to/my-project --format html
```

### 页面里没有我的声明

按顺序检查：声明是 `public` 或 `protected`；注释是 `/** ... */` 且紧贴声明；命令指向的项目目录正确。想看内部声明可以改用：

```bash
cjdoc generate --project . --format html --audience all
```

### 修改注释后页面没有变化

重新运行 `cjdoc generate ...`，确认打开的是同一个输出目录下的 `target/doc/html/index.html`，然后刷新页面。

### 生成结果被标记为不完整（partial）

说明部分源码或引用没有完整解析。先看终端诊断里的文件和行列，再确认是否需要通过 `--cfg NAME=VALUE` 补充条件编译输入。cjdoc 会保留能解析的部分，不会把不确定的信息标成已解析。

### 输出目录报所有权或冲突错误

首次生成时不要预先创建 `target/doc`。cjdoc 只接受不存在的目录，或此前由它写入过所有权清单的目录；预创建或含无关文件的目录会报错，请换一个新输出目录。只有此前由 cjdoc 管理过的目录，才可以用 `--force-owned` 接受其中被修改的已登记产物。托管目录再次生成时可以直接复用。

## 当前边界

- 运行 cjdoc 需要已安装的仓颉 SDK，发布包不包含 SDK；`--check-examples` 还要求 `cjc` 在 `PATH` 中。
- cjdoc 不会下载依赖源码。要把依赖纳入文档，需要显式提供依赖路径或缓存（见文档索引中的高级用法）。
- 无法展开的宏和部分不支持的源码会让生成结果被标记为不完整，能解析的部分仍会输出。
- cjdoc 不编译你的项目，也不做类型检查；它按源码和注释生成文档，需要验证示例能否编译运行时请用 `--check-examples`。

## 文档

- [文档索引](docs/README.md)：使用文档与维护者文档的入口。
