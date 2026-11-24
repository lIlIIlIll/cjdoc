#!/usr/bin/env python3
"""Real CLI acceptance for the optional, offline-provisioned highlight worker.

Run after building cjdoc and `npm ci --ignore-scripts --offline` in tools/highlight.
All generated fixtures, protocol observations and measurements stay in --workdir.
"""
import argparse
import hashlib
import base64
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import shutil
from highlight_ci import traceback_locations
from highlight_acceptance_worker import (
    LANGUAGES, blocks, check_api_cancellation, check_bound_source, check_cli_cancellation,
    check_worker_modes, fixture, generate, walk,
)
import subprocess
import statistics
import sys
import zipfile

# Reuse the repository's strict complete-offline inventory and extraction checks.
from showcase_contract.offline import create_archive, extract_archive
from showcase_contract.site import Site

ROOT = Path(__file__).resolve().parents[1]


def has_token_class(classes):
    """True when a span carries a highlight token class from the cjdoc vocabulary."""
    return any(name.startswith('cj-tok-') for name in classes.split())


class CodeSurface(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'code' and 'data-cjdoc-source' in attrs:
            self.current = {'source': json.loads(attrs['data-cjdoc-source']), 'links': [], 'colors': []}
        elif self.current is not None and tag == 'a':
            self.current['links'].append(attrs.get('href'))
        elif self.current is not None and tag == 'span' and has_token_class(attrs.get('class', '')):
            self.current['colors'].append(attrs['class'])

    def handle_endtag(self, tag):
        if tag == 'code' and self.current is not None:
            self.rows.append(self.current)
            self.current = None


class GuideSurface(CodeSurface):
    def __init__(self):
        super().__init__()
        self.images = []
        self.text = []

    def handle_starttag(self, tag, attrs):
        super().handle_starttag(tag, attrs)
        if tag == 'img':
            self.images.append(dict(attrs))

    def handle_data(self, data):
        self.text.append(data)
        if self.current is not None:
            self.current['rendered'] = self.current.get('rendered', '') + data


def assert_captured_guide_image(project, output, document):
    """Assert the existing native capture contract, not just a readable page."""
    page, = [page for page in document['pages'] if page['source'] == 'docs/guide.md']
    image, = [node for node in walk(page['markdown']) if node.get('kind') == 'image']
    assert ''.join(node['literal'] for node in walk(image) if node.get('kind') == 'text') == 'pixel', \
        'captured guide lost the image alt text'
    assert '![pixel](images/pixel.gif)' in page['text'], 'captured guide lost the author image reference'
    assert any(block['literal'] == LANGUAGES['python'] for block in blocks(page['markdown'])), \
        'captured guide lost its author code'
    guide_path = output / 'html/concepts/guides/highlight.html'
    surface = GuideSurface()
    surface.feed(guide_path.read_text(encoding='utf-8'))
    assert 'Highlight guide' in surface.text, 'captured guide lost its readable heading'
    assert any(row.get('rendered') == LANGUAGES['python'] for row in surface.rows), \
        'captured guide lost its rendered original code'
    expected = (project / 'docs/images/pixel.gif').read_bytes()
    diagnostics = [item for item in document['diagnostics'] if item['code'] == 'CJDOC4026'
                   and (item.get('source') or {}).get('path') == 'docs/guide.md']
    if sys.platform.startswith('linux') or sys.platform == 'darwin':
        asset, = document['assets']
        assert asset['sourcePath'] == 'docs/images/pixel.gif' and asset['mediaType'] == 'image/gif'
        assert base64.b64decode(asset['base64'], validate=True) == expected
        assert image['literal'] == asset['id'] == 'sha256-' + hashlib.sha256(expected).hexdigest()
        assert not diagnostics, 'supported local guide image was diagnosed as omitted'
        rendered, = surface.images
        assert rendered['alt'] == 'pixel'
        source = rendered['src']
        assert not source.startswith('/') and ':' not in source and '\\' not in source
        actual = (guide_path.parent / source).resolve()
        assert actual.is_relative_to((output / 'html/assets').resolve())
        assert actual.read_bytes() == expected, 'captured guide lost the exact local GIF bytes'
        result = {'state': 'embedded', 'mediaType': 'image/gif',
                  'sha256': hashlib.sha256(expected).hexdigest(), 'bytes': len(expected)}
    else:
        # Unsupported native targets reject descriptor-relative asset capture;
        # rendering already captured image assets remains cross-platform.
        assert document['status'] == 'partial' and document['assets'] == [], \
            'unsupported native capture must not embed a local image'
        assert image['literal'] == 'images/pixel.gif', 'rejected image lost its frozen relative reference'
        assert diagnostics and all(item['severity'] == 'warning' and not item.get('symbolId')
                                   for item in diagnostics), 'rejected guide image lacks CJDOC4026'
        assert not surface.images and 'pixel' in surface.text, \
            'rejected guide image must render safe readable alt text, not an image request'
        assert not any(path.read_bytes() == expected for path in (output / 'html/assets').rglob('*')
                       if path.is_file()), 'rejected guide image was still published'
        result = {'state': 'unsupported', 'diagnostic': 'CJDOC4026',
                  'fallback': 'frozen relative image reference and readable HTML alt text; no embedded asset'}
    return result


def compare_plain_source_surfaces(colored, plain):
    colors, links = 0, 0
    for path in sorted((colored / 'html').rglob('*.html')):
        left, right = CodeSurface(), CodeSurface()
        left.feed(path.read_text(encoding='utf-8'))
        right.feed((plain / path.relative_to(colored)).read_text(encoding='utf-8'))
        assert len(left.rows) == len(right.rows), path.name
        for before, after in zip(left.rows, right.rows):
            assert before['source'] == after['source'] and before['links'] == after['links'], path.name
            assert not after['colors'], 'plain signature regained witness colors: ' + path.name
            colors += len(before['colors'])
            links += len(before['links'])
    assert colors > 5, colors
    return {"colored_spans": colors, "reliable_links": links}


def assert_plain_preserves_surfaces(colored, plain):
    """Non-vacuous link check for public IR with resolved type evidence."""
    evidence = compare_plain_source_surfaces(colored, plain)
    assert evidence["reliable_links"] > 0, evidence
    return evidence


class SiteCost(HTMLParser):
    def __init__(self):
        super().__init__()
        self.nodes = 0
        self.spans = 0

    def handle_starttag(self, tag, attrs):
        self.nodes += 1
        if tag == 'span' and any(key == 'class' and has_token_class(value) for key, value in attrs):
            self.spans += 1


def cost(output):
    parser = SiteCost()
    html_bytes = 0
    for page in sorted((output / 'html').rglob('*.html')):
        raw = page.read_bytes()
        html_bytes += len(raw)
        parser.feed(raw.decode())
    return {'ir_bytes': (output / 'docs.json').stat().st_size,
            'html_bytes': html_bytes, 'dom_elements': parser.nodes, 'code_spans': parser.spans}


def replay(binary, document, output):
    environment = render_environment()
    result = subprocess.run([str(binary), 'render', '--input', str(document), '--format', 'json',
                             '--format', 'html', '--output', str(output)],
                            capture_output=True, env=environment, timeout=30)
    assert result.returncode == 0, result.stderr.decode()


def compare_outputs(left, right):
    paths = {'docs.json'} | {str(p.relative_to(left)) for p in (left / 'html').rglob('*') if p.is_file()}
    reproduced = {'docs.json'} | {str(p.relative_to(right)) for p in (right / 'html').rglob('*') if p.is_file()}
    assert paths == reproduced, (sorted(paths - reproduced), sorted(reproduced - paths))
    for name in sorted(paths):
        assert (left / name).read_bytes() == (right / name).read_bytes(), name


def verify_adapter_package(args, project, expected, report):
    adapter_root = ROOT / 'tools/highlight'
    package_zip = args.workdir / 'cjdoc-highlight-adapter.zip'
    members = ['adapter.mjs', 'package.json', 'package-lock.json', '.node-version', 'NOTICE', 'highlight.js-LICENSE']
    with zipfile.ZipFile(package_zip, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(members):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.external_attr = 0o100644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, (adapter_root / name).read_bytes())
    extracted = args.workdir / 'adapter-package'
    with zipfile.ZipFile(package_zip) as archive:
        archive.extractall(extracted)
    lock = json.loads((extracted / 'package-lock.json').read_text(encoding='utf-8'))
    integrity = lock['packages']['node_modules/highlight.js']['integrity']
    algorithm, encoded = integrity.split('-', 1)
    assert algorithm == 'sha512'
    digest = base64.b64decode(encoded).hex()
    npm = shutil.which('npm')
    assert npm, 'explicit adapter package acceptance requires npm'
    cache_result = subprocess.run([npm, 'config', 'get', 'cache'], capture_output=True, text=True, check=True)
    cached_archive = Path(cache_result.stdout.strip()) / '_cacache/content-v2/sha512' / digest[:2] / digest[2:4] / digest[4:]
    assert cached_archive.is_file(), 'locked dependency must be pre-provisioned in the offline npm cache'
    assert hashlib.sha512(cached_archive.read_bytes()).hexdigest() == digest
    # npm identifies local archives by suffix; the content-addressed cache blob
    # has none and is otherwise treated as a directory/package specification.
    tarball = args.workdir / "locked-highlight.js.tgz"
    shutil.copyfile(cached_archive, tarball)
    cache = args.workdir / 'adapter-npm-cache'
    for command in [[npm, 'cache', 'add', str(tarball), '--offline', '--ignore-scripts', '--cache', str(cache)],
                    [npm, 'ci', '--offline', '--ignore-scripts', '--cache', str(cache)]]:
        result = subprocess.run(command, cwd=extracted, capture_output=True, timeout=30)
        assert result.returncode == 0, result.stderr.decode()
    reproduced = args.workdir / 'adapter-package-output'
    generate(args.binary.resolve(), project, reproduced, extracted / 'adapter.mjs', args.node.resolve())
    compare_outputs(expected, reproduced)
    report['adapter_package'] = {'sha256': hashlib.sha256(package_zip.read_bytes()).hexdigest(),
                                 'result': 'independent ZIP + isolated offline lockfile install; generated output byte-identical'}


def runtime_provenance(binary, node, receipt_path=None):
    result = {'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'node': subprocess.run([str(node), '--version'], capture_output=True, text=True, check=True).stdout.strip(),
              'lexer_mapping_revision': '2', 'linked_lexer_artifacts': []}
    if sys.platform.startswith('linux'):
        loaded = subprocess.run(['ldd', str(binary)], capture_output=True, text=True, check=True)
        for line in loaded.stdout.splitlines():
            name, separator, selected = line.partition('=>')
            if separator and name.strip() in ['libcangjie-std-ast.so', 'libstdFFI.so', 'libcangjie-runtime.so']:
                selected_path = Path(selected.rsplit(' (', 1)[0].strip())
                result['linked_lexer_artifacts'].append({'name': name.strip(),
                    'sha256': hashlib.sha256(selected_path.read_bytes()).hexdigest(),
                    'bytes': selected_path.stat().st_size})
    if receipt_path:
        receipt = json.loads(receipt_path.read_text(encoding='utf-8'))
        result['sdk_receipt'] = {key: receipt[key] for key in [
            'schemaVersion', 'compilerArchiveName', 'compilerArchiveSha256',
            'compilerTarget', 'compilerVersion', 'stdxArchiveName', 'stdxArchiveSha256', 'treeSha256']}
        result['sdk_receipt']['receipt_sha256'] = hashlib.sha256(receipt_path.read_bytes()).hexdigest()
        for filename, key in [('.cjdoc-sdk-archive', 'compilerArchiveSha256'),
                              ('.cjdoc-stdx-archive', 'stdxArchiveSha256')]:
            with (receipt_path.parent / filename).open('rb') as archive:
                assert hashlib.file_digest(archive, 'sha256').hexdigest() == receipt[key]
        result['sdk_receipt']['archives_verified'] = True
    result['identity_boundary'] = ('Lexer behavior witness is not a complete SDK build identity; '
                                   'loader-selected artifact digests and verified archive receipt identify this run')
    return result


def command_in_directory(directory, command):
    candidate = directory / command
    # CreateProcessW appends .exe independently of PATHEXT and Python's X_OK policy.
    return (shutil.which(str(candidate)) is not None
            or (os.name == "nt" and (directory / (command + ".exe")).is_file()))


def without_tools_environment(environment, commands):
    # An empty PATH still lets native process lookup search the working directory.
    for command in commands:
        assert not command_in_directory(Path.cwd(), command), \
            "tool-free acceptance requires a working directory without " + command
    directories = environment.get("PATH", "").split(os.pathsep)
    retained = [
        directory for directory in directories
        if not any(command_in_directory(Path(directory or os.curdir).absolute(), command)
                   for command in commands)
    ]
    result = dict(environment, PATH=os.pathsep.join(retained))
    for command in commands:
        assert shutil.which(command, path=result["PATH"]) is None
    return result


def render_environment():
    environment = without_tools_environment(os.environ, ("node", "cjc", "cjpm"))
    for name in ("CANGJIE_HOME", "CANGJIE_SDK_ROOT", "CANGJIE_STDX_PATH",
                 "CANGJIE_STDX_PATH_STATIC", "CANGJIE_STDX_PATH_DYNAMIC",
                 "CJDOC_STDX_PATH", "CJDOC_STDX_LINK_OPTIONS"):
        environment.pop(name, None)
    return environment


def _record_failure_locations(workdir):
    original_excepthook = sys.excepthook

    def record_failure(error_type, error, traceback):
        try:
            (workdir / "failure-locations.json").write_text(
                json.dumps(traceback_locations(ROOT, traceback)), encoding="utf-8")
        except OSError:
            print("acceptance failure location recording unavailable", file=sys.stderr)
        original_excepthook(error_type, error, traceback)

    sys.excepthook = record_failure


def check_highlight_policy(args, project, report):
    # No authorization is explainable plain; ordinary check never executes Node.
    plain = args.workdir / 'unauthorized'
    no_node = without_tools_environment(os.environ, ("node",))
    generate(args.binary.resolve(), project, plain, environment=no_node)
    document = json.loads((plain / 'docs.json').read_text(encoding='utf-8'))
    assert any(n.get('reason') == 'backend-unavailable' for n in walk(document))
    assert any(n.get('language') == 'cangjie' and n.get('state') == 'complete' for n in walk(document))
    report['default_without_node'] = 'builtin complete; external backend-unavailable with no Node in PATH'
    checked = subprocess.run([str(args.binary.resolve()), 'check', '--project', str(project),
                              '--lint-profile', 'off', '--no-cache'], capture_output=True, timeout=30,
                             env=no_node)
    assert checked.returncode == 0, checked.stderr.decode()
    strict_project = args.workdir / 'strict-project'
    shutil.copytree(project, strict_project)
    config = strict_project / 'cjdoc.toml'
    config.write_text(config.read_text(encoding='utf-8').replace('[highlight]', '[highlight]\non-error = "error"'), encoding='utf-8', newline='\n')
    strict_output = args.workdir / 'strict-output'
    result, _ = generate(args.binary.resolve(), strict_project, strict_output, strict=True)
    assert b'CJDOC4027' in result.stderr
    # generate deliberately publishes complete diagnostic-bearing output on an
    # error; preserve that existing transaction policy instead of weakening it.
    strict_document = json.loads((strict_output / 'docs.json').read_text(encoding='utf-8'))
    original_document = json.loads((args.workdir / 'real/docs.json').read_text(encoding='utf-8'))
    assert {s['id']: s['headerSpelling'] for s in strict_document['declarations']} == {
        s['id']: s['headerSpelling'] for s in original_document['declarations']}
    assert [b["literal"] for b in blocks(strict_document)] == [b["literal"] for b in blocks(original_document)]
    assert any(d['code'] == 'CJDOC4027' and d['severity'] == 'error' for d in strict_document['diagnostics'])
    for block in blocks(strict_document):
        if 'codeHighlight' in block.get('metadata', {}):
            check_bound_source(block)
    assert {p.relative_to(strict_output / 'html') for p in (strict_output / 'html').rglob('*') if p.is_file()} == {
        p.relative_to(args.workdir / 'real/html') for p in (args.workdir / 'real/html').rglob('*') if p.is_file()}
    report['strict_policy'] = 'ordinary check needs no Node; explicit strict exits nonzero and preserves complete diagnostic-bearing generate transaction'


def check_frozen_replay(args, binary, project, real, report):
    captured = json.loads((real / 'docs.json').read_text(encoding='utf-8'))
    report['captured_guide_image'] = assert_captured_guide_image(project, real, captured)
    assert (real / 'html/concepts/guides/empty.html').is_file(), 'explicit empty page was lost'
    assert any('Frozen author overview.' in page.read_text(encoding='utf-8') for page in (real / 'html').rglob('*.html'))
    assert any(binding.get('state') == 'resolved' and binding.get('targetSymbolId')
        for page in captured['pages'] for binding in page.get('bindings', [])), 'guide API binding was lost'
    report['captured_pages'] = 'author guide, native image capability contract, API binding, default overview and explicit empty page retained'
    frozen = args.workdir / 'replay'
    # Replay must not accidentally read still-accessible source Markdown/assets.
    detached_project = args.workdir / "detached-project"
    project.rename(detached_project)
    try:
        replay(binary, real / "docs.json", frozen)
    finally:
        detached_project.rename(project)
    compare_outputs(real, frozen)
    repeat = args.workdir / 'repeat'
    generate(binary, project, repeat, (args.workdir / 'real.mjs').resolve(), args.node.resolve())
    compare_outputs(real, repeat)
    report["determinism"] = "generate/repeat/replay byte-identical including captured guides and native image outcome; replay compiler/Node unavailable, SDK discovery unset, native runtime retained and original project path absent"


def compare_plain_render_and_cost(args, binary, project, real, report):
    off_project = args.workdir / 'off-project'
    shutil.copytree(project, off_project)
    configuration = off_project / 'cjdoc.toml'
    configuration.write_text(configuration.read_text(encoding='utf-8').replace('[highlight]', '[highlight]\nmode = "off"'), encoding='utf-8', newline='\n')
    off = args.workdir / 'off'
    _, off_seconds = generate(binary, off_project, off)
    report["source_surface_comparison"] = {"off": compare_plain_source_surfaces(real, off)}
    legacy_document = json.loads((real / 'docs.json').read_text(encoding='utf-8'))
    for node in walk(legacy_document):
        node.pop('signatureHighlight', None)
        node.pop('codeHighlight', None)
    legacy_ir = args.workdir / 'missing-metadata.json'
    legacy_ir.write_text(json.dumps(legacy_document, ensure_ascii=False), encoding='utf-8', newline='\n')
    legacy = args.workdir / 'missing-metadata'
    replay(binary, legacy_ir, legacy)
    report["source_surface_comparison"]["missing_metadata"] = compare_plain_source_surfaces(real, legacy)
    surfaces = []
    for document in [real / 'docs.json', off / 'docs.json', legacy_ir]:
        result = subprocess.run([str(binary), 'render', '--input', str(document), '--format',
                                 'api-surface', '--stdout'], env=render_environment(),
                                capture_output=True, timeout=30, check=True)
        surfaces.append(result.stdout)
    assert surfaces[0] == surfaces[1] == surfaces[2]
    report["plain_signature_policy"] = "source fixture off/missing metadata remove colors and preserve bound original/API identity; reliable-link acceptance requires nonempty resolved public IR separately"
    report['cost'] = {'static': dict(cost(real), seconds=report['runs']['real']['seconds']),
                      'off': dict(cost(off), seconds=off_seconds)}
    # Alternate three fresh-output runs with identical binary/SDK/renderer/input.
    # Use the distributed adapter directly, excluding audit-wrapper overhead.
    samples = {"static": [], "off": []}
    for index in range(3):
        for mode, source in [("static", project), ("off", off_project)]:
            adapter = (ROOT / "tools/highlight/adapter.mjs").resolve() if mode == "static" else None
            output = args.workdir / f"cost-{mode}-{index}"
            _, seconds = generate(binary, source, output, adapter, args.node.resolve())
            compare_outputs(real if mode == "static" else off, output)
            samples[mode].append(seconds)
    for mode in samples:
        report["cost"][mode]["samples_seconds"] = samples[mode]
        report["cost"][mode]["median_seconds"] = statistics.median(samples[mode])
    report["cost"]["method"] = "three alternating no-cache fresh-output samples; same binary and captured author inputs; no speed guarantee"
    if args.baseline_binary:
        baseline = args.workdir / 'baseline'
        _, seconds = generate(args.baseline_binary.resolve(), project, baseline,
                              (args.workdir / 'real.mjs').resolve(), args.node.resolve())
        report['cost']['baseline'] = dict(cost(baseline), seconds=seconds)


def check_crlf_replay(args, binary, real, report):
    # Exercise the public frozen-IR rendering boundary with genuine CRLF literals.
    crlf_document = json.loads((real / 'docs.json').read_text(encoding='utf-8'))
    for block in blocks(crlf_document):
        if block.get('metadata', {}).get('codeHighlight', {}).get('language') != 'python':
            continue
        old = block['literal'].encode()
        raw = old.replace(b'\n', b'\r\n')
        block['literal'] = raw.decode()
        highlight = block['metadata']['codeHighlight']
        highlight['sourceHash'] = hashlib.sha256(raw).hexdigest()
        highlight['byteLength'] = len(raw)
        for span in highlight['spans']:
            for bound in ['startByte', 'endByte']:
                span[bound] += old[:span[bound]].count(b'\n')
    crlf_path = args.workdir / 'crlf-input.json'
    crlf_path.write_text(json.dumps(crlf_document, ensure_ascii=False), encoding='utf-8', newline='\n')
    replay(binary, crlf_path, args.workdir / 'crlf')
    report['crlf'] = 'public frozen IR rendered; browser fixture crlf/html retains bound original'


def check_archives(args, binary, project, real, report):
    # Reproduce from a source-only archive, not a copied generated site.
    source_zip = args.workdir / 'highlight-source.zip'
    with zipfile.ZipFile(source_zip, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for item in sorted(project.rglob('*')):
            if item.is_file() and 'target' not in item.relative_to(project).parts:
                entry = zipfile.ZipInfo(item.relative_to(project).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
                entry.external_attr = 0o100644 << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(entry, item.read_bytes())
    extracted = args.workdir / 'source-extracted'
    with zipfile.ZipFile(source_zip) as archive:
        archive.extractall(extracted)
    reproduced = args.workdir / 'source-reproduced'
    generate(binary, extracted, reproduced, (args.workdir / 'real.mjs').resolve(), args.node.resolve())
    compare_outputs(real, reproduced)
    verify_adapter_package(args, project, real, report)
    # Package a separate copy so the compared native outputs remain immutable.
    published = args.workdir / "published/html"
    shutil.copytree(real / "html", published)
    downloads = published / "downloads"
    downloads.mkdir(exist_ok=True)
    shutil.copyfile(source_zip, downloads / source_zip.name)
    offline = create_archive(published)
    extracted_site = args.workdir / 'offline-extracted'
    snapshot = Site(published)
    extract_archive(offline, extracted_site, snapshot)
    assert not any('highlight.js' in str(item.relative_to(extracted_site)) or 'node_modules' in item.parts
                   for item in extracted_site.rglob('*'))
    report["archives"] = {"result": "source-only ZIP reproduction byte-identical; complete offline archive inventory verified",
        "native_payload": "real/html", "packaged_payload": "published/html",
        "source_sha256": hashlib.sha256(source_zip.read_bytes()).hexdigest(),
        "offline_sha256": hashlib.sha256(offline.read_bytes()).hexdigest(),
        "source_bytes": source_zip.stat().st_size, "offline_bytes": offline.stat().st_size,
        "offline_files": len(Site(extracted_site).files)}
    assert (extracted_site / "downloads" / source_zip.name).read_bytes() == source_zip.read_bytes()


def _record_input_provenance(args, project, real, report):
    report["provenance"]["author_inputs"] = {p.relative_to(project).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(project.rglob("*")) if p.is_file() and "target" not in p.relative_to(project).parts}
    report["provenance"]["renderer_sources"] = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted((ROOT / "src/render").rglob("*.cj"))}
    report["provenance"]["adapter_version"] = json.loads((ROOT / "tools/highlight/package-lock.json").read_text(encoding='utf-8'))["packages"]["node_modules/highlight.js"]["version"]
    report['provenance']['doc_ir_sha256'] = hashlib.sha256((real / 'docs.json').read_bytes()).hexdigest()
    report['provenance']['lexer_behavior_revisions'] = sorted({
        b['metadata']['codeHighlight']['engineRevision'] for b in blocks(json.loads((real / 'docs.json').read_text(encoding='utf-8')))
        if b.get('metadata', {}).get('codeHighlight', {}).get('language') == 'cangjie'})
    assert hashlib.sha256(args.binary.read_bytes()).hexdigest() == report['provenance']['binary_sha256'], 'binary changed during acceptance'


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--node', type=Path, default=Path(shutil.which('node') or 'node'))
    parser.add_argument('--workdir', type=Path, required=True)
    parser.add_argument('--baseline-binary', type=Path)
    parser.add_argument('--api-probe', type=Path)
    parser.add_argument('--sdk-receipt', type=Path)
    args = parser.parse_args()
    args.workdir.mkdir(parents=True, exist_ok=False, mode=0o700)
    _record_failure_locations(args.workdir)
    project = args.workdir / 'project'
    fixture(project)
    report = {'platform': sys.platform, 'runs': {},
              'provenance': runtime_provenance(args.binary.resolve(), args.node.resolve(), args.sdk_receipt)}
    if args.api_probe:
        report['provenance']['api_probe_sha256'] = hashlib.sha256(args.api_probe.read_bytes()).hexdigest()
    check_worker_modes(args, project, report)
    check_cli_cancellation(args, project, report)
    if args.api_probe:
        check_api_cancellation(args, project, report)
    check_highlight_policy(args, project, report)

    binary = args.binary.resolve()
    real = args.workdir / 'real'
    check_frozen_replay(args, binary, project, real, report)
    compare_plain_render_and_cost(args, binary, project, real, report)
    check_crlf_replay(args, binary, real, report)
    check_archives(args, binary, project, real, report)
    _record_input_provenance(args, project, real, report)
    (args.workdir / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
