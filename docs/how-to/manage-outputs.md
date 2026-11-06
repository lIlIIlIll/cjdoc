# 管理输出目录与源码缓存

本指南说明如何安全复用生成目录、识别冲突并把源码缓存放到别处。cjdoc 使用输出所有权清单、事务写入和父目录锁，避免静默覆盖手工文件。

## 前提

- 已完成[首次生成教程](../tutorials/first-site.md)，命令在 `docdemo/` 项目根目录运行。
- 已安装并能启动当前版本的 `cjdoc`。本页的文件操作示例使用 Bash。
- 开始时选择新的输出路径；若路径已存在，它必须是 cjdoc 先前生成并管理的目录。

## 复用输出并保留无关文件

为演示所有权行为，第一次生成 HTML 后手工放入一个不与产物冲突的文件，再用同一输出根改为只生成 JSON。

```bash
OUT=target/doc-managed
if test -e "$OUT"; then
  printf '请选择一个新的输出目录：%s\n' "$OUT" >&2
  exit 2
fi
cjdoc generate --project . --format html --output "$OUT"
printf 'keep this file\n' > "$OUT/KEEP.txt"
cjdoc generate --project . --format json --output "$OUT"
test -f "$OUT/docs.json"
test -f "$OUT/KEEP.txt"
test ! -e "$OUT/html/index.html"
```

第二次生成替换 cjdoc 自己登记的文件，并移除已登记但本次不再生成的 HTML 文件；`KEEP.txt` 不属于 cjdoc，因此保留。目录根的 `.cjdoc-output.json` 记录被管理的相对路径和摘要。初次生成不要预建空的输出根；让 cjdoc 创建它。

## 处理手工修改的已登记产物

如果手工修改 cjdoc 管理的文件，下一次生成会拒绝替换它。以下负例故意编辑刚生成的 `docs.json`，确认失败后用 `--force-owned` 明确接受 cjdoc 当前生成内容。

```bash
OUT=target/doc-managed
printf 'manual edit\n' > "$OUT/docs.json"
if cjdoc generate --project . --format json --output "$OUT"; then
  echo '错误：手工修改的已登记文件被静默覆盖' >&2
  exit 1
else
  status=$?
fi
test "$status" -eq 2
cjdoc generate --project . --format json --output "$OUT" --force-owned
test -s "$OUT/docs.json"
test -f "$OUT/KEEP.txt"
```

仅在检查过目录且愿意丢弃已登记文件上的手工修改时使用 `--force-owned`。它也可接管本次产物所需的预先存在普通子目录，但不能覆盖未登记的产物文件或其它未知内容，也不会把任意预建输出根强行认领。不要手工编辑输出目录中的文件，也不要在生成过程中删除锁文件。

## 将缓存与输出分开

默认源码缓存位于 `<项目>/target/cjdoc/cache/source-v11`，可用 `--cache-dir` 改位置，也可用 `--no-cache` 对某次源码扫描禁用缓存。输出根和源码缓存不能重叠或互相包含；以下组合是确定的负例，会在写入前以参数/路径错误退出码 `2` 失败：

```bash
if test -e target/overlap; then
  printf '请选择一个新的输出路径：%s\n' target/overlap >&2
  exit 2
fi
if cjdoc generate --project . --format html \
    --output target/overlap \
    --cache-dir target/overlap/cache; then
  echo '错误：输出目录与源码缓存重叠的组合被接受' >&2
  exit 1
else
  status=$?
fi
test "$status" -eq 2
test ! -e target/overlap
```

合法的独立缓存路径例如：

```bash
cjdoc generate --project . --format html \
  --output target/doc-managed \
  --cache-dir .cache/cjdoc-source
cjdoc generate --project . --format html --no-cache \
  --output target/doc-managed
```

缓存仅用于源码分析；`render` 使用已保存的 Doc IR，不扫描源码也不使用源码缓存。`--jobs` 控制扫描并行度，范围为 `1..64`，默认 `1`；内存或磁盘紧张时保持较低值。缓存键含源码内容、路径和工具链信息，SDK 变化后旧条目可能不会命中。

## 输出仍被锁定时

同时写同一个输出根的 cjdoc 命令由父目录锁串行保护；锁持有者仍运行时，另一条命令会拒绝写入。等待前一命令退出后重试。不要通过删除锁目录或手工改写 `.cjdoc-output.json` 解决冲突；若持续报锁错误，先确认没有仍在运行的 cjdoc 进程，再看诊断中的路径。

输出根、缓存、事务恢复及 `--force-owned` 的完整约束见[产物参考](../reference/artifacts.md)和[CLI 参考](../reference/cli.md)。

## 下一步

- [本地预览](preview.md)：观察服务的初次生成与失败重建。
- [生成并发布文档](generate-and-publish.md)：选择发布格式并检查完整站点。
- [排查常见故障](troubleshoot.md)：判断路径、权限和缓存问题。
