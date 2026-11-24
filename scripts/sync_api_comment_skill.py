#!/usr/bin/env python3
"""Synchronize the offline API comment reference from its authoring guides."""

import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = Path('skills/cjdoc-api-comments/references/authoring.md')
SOURCES = {
    'README.md': {'1. 为一个 API 写注释': 'cangjie'},
    'docs/reference/doc-comments.md': {
        '行为契约': 'table',
        '在同一声明里写多个提示': 'text',
        '多语言注释': 'cangjie',
    },
    'examples/pocketkit/demo-v2/docs/doc-comments.md': {
        '参数与返回值': 'text',
        '示例与输出': 'text',
        '弃用与版本': 'text',
        '分组与分类': 'text',
        '提供译文': 'toml',
    },
}
HEADING = re.compile(r' {0,3}(#{1,6})[ \t]+(.*)')
FENCE = re.compile(r' {0,3}(`{3,}|~{3,})(.*)')
TABLE_DIVIDER = re.compile(r'[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*')


def table_end(lines: list[str], start: int) -> int:
    if ('|' not in lines[start] or start + 1 >= len(lines)
            or not TABLE_DIVIDER.fullmatch(lines[start + 1].rstrip('\r\n'))):
        return start
    end = start + 2
    while end < len(lines) and lines[end].lstrip().startswith('|'):
        end += 1
    return end


def extract_blocks(path: Path, selections: dict[str, str]) -> dict[str, str]:
    lines = path.read_bytes().decode('utf-8').splitlines(keepends=True)
    seen = set()
    blocks = {}
    title = '文档开头'
    section, level = '', 0
    fence, language, start = '', '', 0
    for index, line in enumerate(lines):
        text = line.rstrip('\r\n')
        opening = FENCE.fullmatch(text)
        if fence:
            if (opening and opening[1][0] == fence[0] and len(opening[1]) >= len(fence)
                    and not opening[2].strip(' \t')):
                if section not in blocks and selections.get(section) == language and language != 'table':
                    blocks[section] = ''.join(lines[start:index + 1])
                fence = ''
            continue
        if opening and (opening[1][0] == '~' or '`' not in opening[2]):
            fence = opening[1]
            info = opening[2].split()
            language = info[0] if info else ''
            start = index
            continue
        heading = HEADING.fullmatch(text)
        if heading:
            title = re.sub(r'(?:^|[ \t]+)#+[ \t]*$', '', heading[2]).strip(' \t')
            depth = len(heading[1])
            if depth <= level:
                section, level = '', 0
            if title in selections:
                if title in seen:
                    raise ValueError(f'{path}: 「{title}」标题重复')
                seen.add(title)
                section, level = title, depth
            continue
        if section not in blocks and selections.get(section) == 'table':
            end = table_end(lines, index)
            if end != index:
                blocks[section] = ''.join(lines[index:end])
    if fence:
        raise ValueError(f'{path}: 「{title}」围栏未闭合')
    for selected, kind in selections.items():
        if selected not in seen:
            raise ValueError(f'{path}: 找不到标题「{selected}」')
        if selected not in blocks:
            raise ValueError(f'{path}: 「{selected}」找不到 {kind} 块')
    return blocks


def render_reference(root: Path) -> bytes:
    parts = ['# cjdoc 注释写法\n\n<!-- 由 scripts/sync_api_comment_skill.py 同步，请勿手改。 -->\n\n']
    for source, selections in SOURCES.items():
        blocks = extract_blocks(root / source, selections)
        for title in selections:
            block = blocks[title]
            parts.extend((f'## {title}\n\n', block, '\n' if block.endswith('\n') else '\n\n'))
    return ''.join(parts).encode('utf-8')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail if the reference is missing or stale')
    args = parser.parse_args()
    destination = ROOT / REFERENCE
    try:
        expected = render_reference(ROOT)
        if destination.exists() and destination.read_bytes() == expected:
            return 0
        if args.check:
            print(f'{REFERENCE} 缺失或已过期；运行 python3 scripts/sync_api_comment_skill.py 更新。',
                  file=sys.stderr)
            return 1
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(expected)
        return 0
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
