#!/usr/bin/env python3
"""Exercise the documented OOM remedy and check its historical observation."""

from __future__ import annotations

import argparse
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import tempfile

from real_repository_smoke import resolve_binary

REPO = Path(__file__).resolve().parent.parent
GUIDE = REPO / "docs/how-to/troubleshoot.md"


def read_table(section: str, columns: tuple[str, ...]) -> list[tuple[str, ...]]:
    for block in re.findall(r"(?:^\|[^\n]*\|[ \t]*\n)+", section, flags=re.M):
        rows = [tuple(cell.strip().strip("`") for cell in line.strip().split("|")[1:-1])
                for line in block.splitlines()]
        if len(rows) >= 2 and rows[0] == columns and len(rows[1]) == len(columns) and all(
            re.fullmatch(r":?-{3,}:?", cell) for cell in rows[1]
        ):
            return rows[2:]
    raise ValueError(f"Out of memory guide is missing the table {columns}")


def read_remedy(guide: str) -> tuple[str, list[str], PurePosixPath]:
    sections = re.split(r"^## ", guide, flags=re.M)
    section = next((part for part in sections if part.startswith("生成时出现 Out of memory\n")), "")
    blocks = re.findall(r"^```bash\n(.*?)\n```$", section, flags=re.M | re.S)
    if len(blocks) != 1:
        raise ValueError("Out of memory guide must provide one runnable Bash remedy")
    words = shlex.split(blocks[0])
    if len(words) != 9 or words[1:3] != ["cjdoc", "generate"]:
        raise ValueError("Out of memory remedy must run cjdoc generate from the project root")
    heap = re.fullmatch(r"cjHeapSize=([1-9][0-9]*(?:MB|GB))", words[0])
    options = dict(zip(words[3::2], words[4::2]))
    if not heap or options.keys() != {"--project", "--format", "--output"} or (
        options["--project"] != "." or options["--format"] != "html"
    ):
        raise ValueError("Out of memory remedy must set cjHeapSize, not the Doc IR budget")
    output = PurePosixPath(options["--output"])
    if output.parts[:1] != ("target",) or len(output.parts) < 2 or ".." in output.parts or (
        "\\" in options["--output"] or ":" in options["--output"]
    ):
        raise ValueError("Out of memory remedy must use a new output under the fixture's target/")

    limits = read_table(section, ("设置", "限制对象", "能否修复运行时堆耗尽"))
    if limits != [("cjHeapSize", "运行时堆", "是"), ("--max-doc-ir-mib", "编码后的 Doc IR 大小", "否")]:
        raise ValueError("Out of memory guide must distinguish the runtime heap from Doc IR size")
    # #229 observed these two heaps on the same repository snapshot. The modern
    # smoke test is not a remeasurement of the 256 MiB failure.
    observations = read_table(section,
                              ("记录性质", "仓颉源文件", "源码行数", "256 MiB 堆", "2 GB 堆"))
    if observations != [("单次观测（非项目规模阈值）", "522", "113,212", "Out of memory", "完成生成")]:
        raise ValueError("Out of memory guide must report the #229 observation, not a project-size threshold")
    return heap[1], words[2:], output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--workdir", type=Path, required=True)
    args = parser.parse_args()
    try:
        heap, command, output = read_remedy(GUIDE.read_text(encoding="utf-8"))
        binary = resolve_binary(args.binary)
        with tempfile.TemporaryDirectory(prefix="heap-guide-", dir=args.workdir) as work:
            project = Path(work) / "basic"
            shutil.copytree(REPO / "tests/fixtures/projects/basic", project)
            result = subprocess.run([str(binary), *command], cwd=project, timeout=120,
                                    env={**os.environ, "cjHeapSize": heap}, check=False)
            if result.returncode != 0 or not (project.joinpath(*output.parts) / "html/index.html").is_file():
                raise ValueError(f"documented heap command did not publish HTML (exit {result.returncode})")
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        parser.error(str(error))
    print("Heap guide: published remedy generated an HTML artifact; historical measurement and scope verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
