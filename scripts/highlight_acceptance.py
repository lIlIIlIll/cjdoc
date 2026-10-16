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
from highlight_process import assert_stopped, observe_cancel_targets, cleanup_observed
import subprocess
import time
import statistics
import sys
import zipfile

# Reuse the repository's strict complete-offline inventory and extraction checks.
from showcase_contract.offline import create_archive, extract_archive
from showcase_contract.site import Site

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = {
    "python": 'def greet(name):\n\treturn "中😀é<script>&amp;</code>"\n',
    "json": '{"enabled": true, "name": "中😀"}\n',
    "bash": '# comment\nprintf "%s\\n" "hello"\n',
    "toml": '[app]\nname = "中"\nenabled = true\n',
    "yaml": 'app:\n  enabled: true\n  name: "中"\n',
}
CANGJIE_CORPUS = [
    "let text = \"normal\\n\\\"quoted\\\"\"\nlet empty = \"\"\n",
    "let raw = ##\"a #\" b\"##\n",
    "let multiline = \"\"\"\nline one 中\nline two\n\"\"\"\n",
    "let rune = 'x'\nlet escaped = '\\n'\n",
    "let hex = 0xFF\nlet binary = 0b1010\nlet integer = 10i8\nlet decimal = 1.5e-3\n",
    "// comment\n/* a /* b */ c */ let 名称 = true\nf<Int64>(x: 1)\n@M\npublic macro m() { 0 }\n",
    "let interpolation = \"a ${x + 1} b\"\n",
]


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def blocks(document):
    return [n for n in walk(document) if n.get("kind") == "code_block"]


def check_bound_source(block):
    raw = block["literal"].encode()
    highlight = block["metadata"]["codeHighlight"]
    assert highlight["sourceHash"] == hashlib.sha256(raw).hexdigest()
    assert highlight["byteLength"] == len(raw)
    previous = 0
    for span in highlight["spans"]:
        start, end = span["startByte"], span["endByte"]
        assert previous <= start < end <= len(raw)
        raw[:start].decode(); raw[:end].decode()
        previous = end


def fixture(root):
    (root / "src").mkdir(parents=True)
    (root / "docs").mkdir()
    (root / "cjpm.toml").write_text('[package]\nname = "highlight_acceptance"\nversion = "1.0.0"\noutput-type = "static"\n', encoding='utf-8', newline='\n')
    (root / "cjdoc.toml").write_text('[highlight]\nlanguages = ["cangjie", "python", "json", "bash", "toml", "yaml", "unknown"]\n\n[[docs.pages]]\nsource = "docs/guide.md"\nroute = "concepts/guides/highlight"\ntitle = "Highlight guide"\n', encoding='utf-8', newline='\n')
    fences = []
    for language, code in LANGUAGES.items():
        fences.append(f'```{language}\n{code}```\n')
    fences += ['```py\n' + LANGUAGES["python"] + '```\n',
               '```python\n' + LANGUAGES["python"] + '```\n']
    fences += ["```yml\n" + LANGUAGES["yaml"] + "```\n"]
    for index in range(6):
        fences.append(f'```python\nvalue = {index}\n```\n')
    fences += ['```cj\nlet 名称 = #"raw <script>"#\n/* nested /* inner */ end */\n```\n',
               '```cj\nfunc incomplete(\n```\n', '```cj\nlet text = "unterminated\n```\n',
               '```text\n<script>&amp;</code>\n```\n', '```\nno language\n```\n',
               '```unknown\nunknown language\n```\n']
    fences += ["```cj\n" + code + "```\n" for code in CANGJIE_CORPUS]
    doc = '\n'.join(fences)
    comment = '\n'.join(' * ' + line for line in doc.splitlines())
    example = "@example\n```python\n" + LANGUAGES["python"] + "```\n"
    comment += "\n *\n" + "\n".join(" * " + line for line in example.splitlines())
    source = 'package highlight_acceptance\n/**\n * Highlight examples.\n *\n' + comment + '\n */\npublic func sample(): Unit {}\n'
    source += '/** Hidden.\n * ```python\n * secret_private = 12345\n * ```\n */\nprivate func hidden(): Unit {}\n'
    source += '\npublic class Token {}\npublic func accept(label!: String = "Token", item!: Token): Token { item }\n'
    (root / 'src/api.cj').write_text(source, encoding='utf-8', newline='\n')
    (root / 'docs/guide.md').write_text('# Highlight guide\n\n![pixel](images/pixel.gif)\n\n'
        '<!-- cjdoc-bind target="highlight_acceptance.sample" selector="symbol" -->\n\n'
        '```python\n' + LANGUAGES['python'] + '```\n', encoding='utf-8', newline='\n')
    (root / 'docs/images').mkdir()
    shutil.copyfile(ROOT / 'tests/fixtures/projects/local_assets/src/images/pixel.gif',
                    root / 'docs/images/pixel.gif')
    (root / 'docs/index.md').write_text('# Default overview\n\nFrozen author overview.\n', encoding='utf-8', newline='\n')
    (root / 'docs/empty.md').write_text('', encoding='utf-8', newline='\n')
    with (root / 'cjdoc.toml').open('a', encoding='utf-8', newline='\n') as config:
        config.write('\n[[docs.pages]]\nsource = "docs/empty.md"\nroute = "concepts/guides/empty"\ntitle = "Empty author page"\n')


# Executed by a real fixture child on Windows, never modeled on other hosts.
# NULL selects the caller's immediate job even under the runner's outer job:
# https://learn.microsoft.com/windows/win32/api/jobapi2/nf-jobapi2-queryinformationjobobject
WINDOWS_INITIALIZATION_JOB_PROBE = r'''
import ctypes
from ctypes import wintypes
import json
import os
import sys

kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.QueryInformationJobObject.argtypes = [
    wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD)]
kernel.QueryInformationJobObject.restype = wintypes.BOOL

class ProcessList(ctypes.Structure):
    _fields_ = [("assigned", wintypes.DWORD), ("count", wintypes.DWORD),
                ("pids", ctypes.c_size_t * 64)]

members = ProcessList()
if not kernel.QueryInformationJobObject(None, 3, ctypes.byref(members),
                                       ctypes.sizeof(members), None):
    raise ctypes.WinError(ctypes.get_last_error())
assert members.assigned == members.count <= 64, "incomplete private job cohort"
pids = set(members.pids[:members.count])
worker, child, owner = map(int, sys.argv[1:])
assert ctypes.sizeof(ctypes.c_void_p) == 8, "Windows x64 acceptance required"
limits = (ctypes.c_uint64 * 18)()
if not kernel.QueryInformationJobObject(None, 9, ctypes.byref(limits),
                                       ctypes.sizeof(limits), None):
    raise ctypes.WinError(ctypes.get_last_error())
job_limit_flags = ctypes.c_uint32.from_buffer(limits, 16).value
assert job_limit_flags == 0x2000, "immediate job is not the product's exact kill-on-close job"
facts = {"worker": worker in pids, "initializationChild": child in pids,
         "probe": os.getpid() in pids, "ownerExcluded": owner not in pids,
         "killOnClose": bool(job_limit_flags & 0x2000), "jobLimitFlags": job_limit_flags}
assert all(facts.values()), "initialization child escaped the worker's private job"
print(json.dumps(facts))
'''


def threaded_adapter_wrapper(path, log):
    """A real grammar consumer, file Worker and nested CommonJS fork, all host-authorized."""
    helper = path.with_suffix('.helper.cjs')
    helper.write_text(
        "const assert = require('node:assert/strict');\n"
        "assert.equal(require.main, module);\n"
        "process.send({pid:process.pid, parent:process.ppid, main:true}, error => {\n"
        "  if (error) throw error;\n"
        "  process.disconnect();\n"
        "});\n",
        encoding='utf-8', newline='\n',
    )
    target = (ROOT / 'tools/highlight/adapter.mjs').as_uri()
    path.write_text(f'''import {{ handleRequest }} from {json.dumps(target)};
    import assert from 'node:assert/strict';
    import {{ appendFileSync }} from 'node:fs';
    import {{ createInterface }} from 'node:readline';
    import {{ fork }} from 'node:child_process';
    import {{ once }} from 'node:events';
    import {{ Worker, isMainThread, parentPort, threadId }} from 'node:worker_threads';
    const log = {json.dumps(str(log))};
    const record = value => appendFileSync(log, JSON.stringify(value) + '\\n');
    if (!isMainThread) {{
      assert.deepEqual(Object.keys(process.env), []);
      const helper = fork({json.dumps(str(helper))}, [],
        {{env:{{}}, stdio:['ignore','ignore','inherit','ipc']}});
      const message = once(helper, 'message');
      const exited = once(helper, 'exit');
      const [ready] = await message;
      const [code, signal] = await exited;
      assert.deepEqual(ready, {{pid:helper.pid, parent:process.pid, main:true}});
      assert.equal(code, 0);
      assert.equal(signal, null);
      record({{event:'fork-exit', pid:helper.pid, parent:process.pid, code, main:ready.main}});
      record({{event:'thread-ready', pid:process.pid, threadId, emptyEnvironment:true}});
      parentPort.on('message', request => {{
        const response = handleRequest(request);
        record({{event:'response', response}});
        parentPort.postMessage(response);
      }});
      parentPort.postMessage({{ready:true}});
    }} else {{
      record({{event:'start', pid:process.pid,
        injected:!!process.env.NODE_OPTIONS || !!process.env.NODE_PATH}});
      const worker = new Worker(new URL(import.meta.url), {{env:{{}}}});
      const [ready] = await once(worker, 'message');
      assert.deepEqual(ready, {{ready:true}});
      for await (const line of createInterface({{input:process.stdin, crlfDelay:Infinity}})) {{
        const request = JSON.parse(line);
        record({{event:'request', id:request.id, language:request.language, code:request.code}});
        const answered = once(worker, 'message');
        worker.postMessage(request);
        const [response] = await answered;
        // Independent pinned grammar evaluation, never a generated-output oracle.
        assert.deepEqual(response, handleRequest(request));
        process.stdout.write(JSON.stringify(response) + '\\n');
      }}
      await worker.terminate();
    }}
    ''', encoding='utf-8', newline='\n')


def assert_threaded_consumer(document, records):
    threads = [event for event in records if event['event'] == 'thread-ready']
    helpers = [event for event in records if event['event'] == 'fork-exit']
    starts = [event for event in records if event['event'] == 'start']
    requests = [event for event in records if event['event'] == 'request']
    responses = [event['response'] for event in records if event['event'] == 'response']
    assert len(starts) == len(threads) == len(helpers) == 1
    assert threads[0]['threadId'] > 0 and threads[0]['pid'] == starts[0]['pid']
    assert threads[0]['emptyEnvironment'] is True
    assert helpers[0]['main'] is True and helpers[0]['code'] == 0
    assert helpers[0]['parent'] == starts[0]['pid']
    assert_stopped(helpers[0]['pid'])
    corpus = list(LANGUAGES.items()) + [('python', f'value = {index}\n') for index in range(6)]
    assert len(requests) == len(responses) == len(corpus)
    assert {(event['language'], event['code']) for event in requests} == set(corpus)
    first_request = next(index for index, event in enumerate(records) if event['event'] == 'request')
    assert next(index for index, event in enumerate(records) if event['event'] == 'fork-exit') < first_request
    actual = {response['id']: response for response in responses}
    assert len(actual) == len(responses)
    prepared = [block for block in blocks(document) if 'codeHighlight' in block.get('metadata', {})]
    for language, source in corpus:
        request = [event for event in requests if event['language'] == language and event['code'] == source]
        assert len(request) == 1, 'fixed corpus was not served by the real Worker'
        response = actual[request[0]['id']]
        assert response['state'] == 'complete' and response['spans']
        expected = {key: response[key] for key in ['language', 'sourceHash', 'byteLength', 'state', 'spans']}
        expected.update(engineId=response['engine']['id'], engineRevision=response['engine']['revision'],
                        reason=response.get('reason'))
        matches = [block for block in prepared if block['literal'] == source]
        assert matches
        for block in matches:
            check_bound_source(block)
            assert block['metadata']['codeHighlight'] == expected
    return {'fileWorker': True, 'workerEmptyEnvironment': True, 'nestedForkEmptyEnvironment': True,
            'commonJsMain': True, 'helperExitCode': 0, 'fixedCorpusLanguages': len(LANGUAGES),
            'fixedCorpusRequests': len(corpus),
            'oracle': 'independent pinned handleRequest; exact metadata and spans'}


def adapter_wrapper(path, log, mode):
    if mode == 'threaded':
        threaded_adapter_wrapper(path, log)
        return
    # Host-authorized fixture: input code never selects paths or modules.
    target = (ROOT / 'tools/highlight/adapter.mjs').as_uri()
    path.write_text(f'''import {{ handleRequest }} from {json.dumps(target)};
    import {{ appendFileSync, existsSync, writeFileSync }} from 'node:fs';
    import {{ createInterface }} from 'node:readline';
    import {{ spawn }} from 'node:child_process';
    const log = {json.dumps(str(log))};
    const mode = {json.dumps(mode)};
    const record = value => appendFileSync(log, JSON.stringify(value) + '\\n');
    record({{event:'start', pid:process.pid, injected:!!process.env.NODE_OPTIONS || !!process.env.NODE_PATH}});
    // Windows detachment skips libuv's own private job, not inherited product
    // jobs. POSIX must remain in the existing supervised process group.
    const child = mode === 'timeout' ? spawn(process.execPath,
      ['-e', 'setInterval(()=>{{}},1000)', log],
      {{stdio:'ignore', detached:process.platform === 'win32'}}) : null;
    if (child) record({{event:'child', pid:child.pid, parent:process.pid}});
    if (child && process.platform === 'win32') {{
      // The descendant above is deliberately spawned at module initialization,
      // not after the first request or after the ownership observation.
      const probe = (await import('node:child_process')).spawnSync(
        {json.dumps(sys.executable)},
        ['-c', {json.dumps(WINDOWS_INITIALIZATION_JOB_PROBE)},
          String(process.pid), String(child.pid), String(process.ppid)],
        {{stdio:['ignore','pipe','inherit'], timeout:2000, detached:true}});
      if (probe.error) throw probe.error;
      record({{event:'initialization-job', pid:process.pid, status:probe.status,
        facts:probe.status === 0 ? JSON.parse(probe.stdout.toString('utf8')) : null}});
    }}
    for await (const line of createInterface({{input:process.stdin, crlfDelay:Infinity}})) {{
      const request = JSON.parse(line);
      record({{event:'request', id:request.id, language:request.language, code:request.code}});
      writeFileSync(log + '.request', '1');
      if (mode === 'crash') process.exit(17);
      if (mode === 'timeout') continue;
      if (mode === 'oversized-output') {{ process.stdout.write('x'.repeat(3145730)); continue; }}
      if (mode === 'noisy-stderr') {{ process.stderr.write('x'.repeat(16384)); continue; }}
      const response = handleRequest(request);
      if (['wrong-id', 'wrong-engine'].includes(mode) && !existsSync(log + '.failed')) {{
    writeFileSync(log + '.failed', '1');
    if (mode === 'wrong-id') response.id = 'wrong-id';
    else response.engine = {{...response.engine, revision:'wrong-revision'}};
      }}
      process.stdout.write(JSON.stringify(response) + '\\n');
    }}
    ''', encoding='utf-8', newline='\n')


def events(log):
    return [json.loads(line) for line in log.read_text(encoding='utf-8').splitlines()] if log.exists() else []


def assert_initialization_ownership(records):
    """Keep the real init-spawn ordering; native Windows additionally proves its job."""
    starts = [index for index, event in enumerate(records) if event['event'] == 'start']
    for position, start in enumerate(starts):
        end = starts[position + 1] if position + 1 < len(starts) else len(records)
        session = records[start:end]
        child = next(index for index, event in enumerate(session) if event['event'] == 'child')
        request = next(index for index, event in enumerate(session) if event['event'] == 'request')
        assert child < request, 'timeout descendant was not spawned during module initialization'
        if sys.platform == 'win32':
            probes = [(index, event) for index, event in enumerate(session)
                      if event['event'] == 'initialization-job']
            assert len(probes) == 1, 'missing native initialization-job observation'
            index, probe = probes[0]
            assert child < index < request, 'job membership was not observed before the first request'
            assert probe['pid'] == session[0]['pid'] and probe['status'] == 0
            assert probe['facts'] == {
                'worker': True, 'initializationChild': True, 'probe': True,
                'ownerExcluded': True, 'killOnClose': True, 'jobLimitFlags': 0x2000,
            }, 'worker and initialization descendant do not share a private kill-on-close job'
    assert starts, 'missing initialization worker'
    result = {'sessions': len(starts),
              'backend': 'windows-immediate-private-job' if sys.platform == 'win32'
                         else 'real-initialization-spawn-order'}
    if sys.platform == 'win32':
        result['jobLimitFlags'] = 0x2000
    return result





def generate(binary, project, out, adapter=None, node=None, strict=False, environment=None):
    command = [str(binary), 'generate', '--project', str(project), '--format', 'json', '--format', 'html', '--output', str(out), '--lint-profile', 'off', '--no-cache']
    if adapter:
        command += ['--highlight-adapter', str(adapter), '--highlight-node', str(node)]
    started = time.perf_counter()
    result = subprocess.run(command, capture_output=True, timeout=90, env=environment)
    if strict:
        assert result.returncode != 0, result.stderr.decode()
    else:
        assert result.returncode == 0, result.stderr.decode()
    return result, time.perf_counter() - started


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
        elif self.current is not None and tag == 'span' and attrs.get('class', '').startswith('code-'):
            self.current['colors'].append(attrs['class'])

    def handle_endtag(self, tag):
        if tag == 'code' and self.current is not None:
            self.rows.append(self.current)
            self.current = None


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
        if tag == 'span' and any(key == 'class' and value.startswith('code-') for key, value in attrs):
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
    environment = dict(os.environ, PATH='')
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
    project = args.workdir / 'project'
    fixture(project)
    report = {'platform': sys.platform, 'runs': {},
              'provenance': runtime_provenance(args.binary.resolve(), args.node.resolve(), args.sdk_receipt)}
    if args.api_probe:
        report['provenance']['api_probe_sha256'] = hashlib.sha256(args.api_probe.read_bytes()).hexdigest()
    for mode in ['real', 'threaded', 'wrong-id', 'wrong-engine', 'crash', 'timeout', 'oversized-output', 'noisy-stderr']:
        log = args.workdir / (mode + '.jsonl')
        wrapper = args.workdir / (mode + '.mjs')
        adapter_wrapper(wrapper, log, mode)
        out = args.workdir / mode
        authorized_environment = dict(os.environ, NODE_OPTIONS='--trace-warnings',
                                      NODE_PATH=str(args.workdir / 'untrusted-module-path'))
        result, elapsed = generate(args.binary.resolve(), project, out, wrapper.resolve(), args.node.resolve(),
                              environment=authorized_environment)
        document = json.loads((out / 'docs.json').read_text(encoding='utf-8'))
        if mode == "real":
            original_literals = [b["literal"] for b in blocks(document)]
        else:
            assert [b["literal"] for b in blocks(document)] == original_literals, "backend failure changed code"
        assert b"x" * 256 not in result.stdout + result.stderr, "untrusted worker output leaked into CLI diagnostics"
        observed = events(log)
        starts = [e for e in observed if e['event'] == 'start']
        requests = [e for e in observed if e['event'] == 'request']
        assert all(not e['injected'] for e in starts)
        assert all('secret_private' not in e['code'] for e in requests)
        assert len(starts) == (1 if mode in ['real', 'threaded'] else 2 if mode in ['wrong-id', 'wrong-engine'] else 3), starts
        assert len({e['id'] for e in requests}) == len(requests)
        for e in observed:
            if e['event'] in ['start', 'child']:
                assert_stopped(e['pid'])
        prepared = [b for b in blocks(document) if 'codeHighlight' in b.get('metadata', {})]
        for block in prepared:
            check_bound_source(block)
        python = [b for b in prepared if b['metadata']['codeHighlight']['language'] == 'python']
        if mode in ['real', 'threaded']:
            assert all(b['metadata']['codeHighlight']['state'] == 'complete' for b in python)
            assert sum(e['language'] == 'python' and e['code'] == LANGUAGES['python'] for e in requests) == 1
            assert sum(e["language"] == "yaml" and e["code"] == LANGUAGES["yaml"] for e in requests) == 1
            assert {e['language'] for e in requests} == set(LANGUAGES)
            for source in CANGJIE_CORPUS:
                matches = [b for b in prepared if b["literal"] == source]
                assert matches and all(b["metadata"]["codeHighlight"]["state"] == "complete" for b in matches), source
            assert any(n.get("exampleMarkdown") for n in walk(document)), "example preparation was not captured"
            if mode == 'threaded':
                report['threaded_consumer'] = assert_threaded_consumer(document, observed)
        elif mode in ['wrong-id', 'wrong-engine']:
            assert any(b['metadata']['codeHighlight']['state'] == 'plain' for b in python)
            assert any(b['metadata']['codeHighlight']['state'] == 'complete' for b in python[1:])
            assert sum(e['language'] == 'python' and e['code'] == LANGUAGES['python'] for e in requests) == 2
        else:
            assert all(b['metadata']['codeHighlight']['reason'] == 'backend-unavailable' for b in python)
        report['runs'][mode] = {'seconds': elapsed, 'starts': len(starts), 'requests': len(requests), 'blocks': len(prepared)}
        if mode == 'timeout':
            report['initialization_ownership'] = assert_initialization_ownership(observed)
    # A cancelled CLI must not leave the isolated Node group behind or publish output.
    log = args.workdir / 'cancel.jsonl'
    wrapper = args.workdir / 'cancel.mjs'
    adapter_wrapper(wrapper, log, 'timeout')
    # Abrupt host death intentionally leaves fail-closed ownership evidence.
    # Isolate that parent; never delete its lock or reuse it for later runs.
    cancelled_output = args.workdir / 'cancelled-parent' / 'result'
    cancelled_output.parent.mkdir()
    command = [str(args.binary.resolve()), 'generate', '--project', str(project), '--format', 'json',
               '--output', str(cancelled_output), '--lint-profile', 'off', '--no-cache',
               '--highlight-adapter', str(wrapper.resolve()), '--highlight-node', str(args.node.resolve())]
    host = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    observed = {}
    try:
        deadline = time.monotonic() + 10
        while not Path(str(log) + '.request').exists():
            assert host.poll() is None and time.monotonic() < deadline, 'host did not request highlighting'
            time.sleep(.01)
        observed = observe_cancel_targets(events(log), node=args.node.resolve(),
            wrapper=wrapper.resolve(), child_marker=str(log.resolve()), parent_pid=host.pid)
        report['cancellation_initialization_ownership'] = assert_initialization_ownership(events(log))
        host.terminate()
        host.communicate(timeout=3)
        deadline = time.monotonic() + 3
        while True:
            try:
                for event in events(log):
                    if event['event'] in ['start', 'child']:
                        assert_stopped(event['pid'], observed[event['pid']])
                break
            except AssertionError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.02)
        assert not (cancelled_output / 'docs.json').exists(), 'cancelled host published partial output'
        assert (cancelled_output.parent / ".cjdoc-output-parent.lock").is_dir(), "host death lost fail-closed ownership evidence"
    finally:
        if host.poll() is None:
            host.kill(); host.communicate(timeout=3)
        cleanup_observed(observed)
    report['cancellation'] = 'terminated host; worker and child stopped, no partial publication'
    report['cancellation_observations'] = {'count': len(observed),
        'backends': sorted({process.backend for process in observed.values()})}
    if args.api_probe:
        log = args.workdir / 'api-cancel.jsonl'
        wrapper = args.workdir / 'api-cancel.mjs'
        adapter_wrapper(wrapper, log, 'timeout')
        # The public host waits for a separate gate, so observations precede its
        # real Future.cancel(), rather than racing a process that has already died.
        ready = Path(str(log) + '.cancel-ready')
        command = [str(args.api_probe.resolve()), str(project), str(args.binary.resolve()),
                   str(args.node.resolve()), str(wrapper.resolve()), str(ready)]
        host = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        observed = {}
        try:
            deadline = time.monotonic() + 10
            while not Path(str(log) + '.request').exists():
                assert host.poll() is None and time.monotonic() < deadline, 'public host did not request highlighting'
                time.sleep(.01)
            observed = observe_cancel_targets(events(log), node=args.node.resolve(),
                wrapper=wrapper.resolve(), child_marker=str(log.resolve()), parent_pid=host.pid)
            report['api_cancellation_initialization_ownership'] = assert_initialization_ownership(events(log))
            ready.write_text('observed', encoding='utf-8')
            stdout, stderr = host.communicate(timeout=20)
            assert host.returncode == 0, stderr.decode() + stdout.decode()
            for event in events(log):
                if event['event'] in ['start', 'child']:
                    assert_stopped(event['pid'], observed[event['pid']])
            report['api_cancellation'] = stdout.decode().strip()
            report['api_cancellation_observations'] = {'count': len(observed),
                'backends': sorted({process.backend for process in observed.values()})}
        finally:
            if host.poll() is None:
                host.kill(); host.communicate(timeout=3)
            cleanup_observed(observed)
    # No authorization is explainable plain; ordinary check never executes Node.
    plain = args.workdir / 'unauthorized'
    system_paths = [str(Path(os.environ["CANGJIE_HOME"]) / "bin")]
    if os.name == "nt":
        # Removing Node must not also remove the existing PowerShell supervisor.
        windows = Path(os.environ["SystemRoot"])
        system_paths += [str(windows), str(windows / "System32"),
                         str(windows / "System32/WindowsPowerShell/v1.0")]
    no_node = dict(os.environ, PATH=os.pathsep.join(system_paths))
    assert shutil.which("node", path=no_node["PATH"]) is None
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
    binary = args.binary.resolve()
    real = args.workdir / 'real'
    guide = (real / 'html/concepts/guides/highlight.html').read_text(encoding='utf-8')
    expected_image = (project / 'docs/images/pixel.gif').read_bytes()
    assert '<img ' in guide and any(asset.name in guide and asset.read_bytes() == expected_image
        for asset in (real / 'html/assets').rglob('*') if asset.is_file()), 'captured guide lost local image'
    assert (real / 'html/concepts/guides/empty.html').is_file(), 'explicit empty page was lost'
    assert any('Frozen author overview.' in page.read_text(encoding='utf-8') for page in (real / 'html').rglob('*.html'))
    captured = json.loads((real / 'docs.json').read_text(encoding='utf-8'))
    assert any(binding.get('state') == 'resolved' and binding.get('targetSymbolId')
        for page in captured['pages'] for binding in page.get('bindings', [])), 'guide API binding was lost'
    report['captured_pages'] = 'author guide, exact local GIF, API binding, default overview and explicit empty page retained'
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
    report["determinism"] = "generate/repeat/replay byte-identical including captured guides; replay PATH empty and original project path absent"
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
                                 'api-surface', '--stdout'], env=dict(os.environ, PATH=''),
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
    report["provenance"]["author_inputs"] = {p.relative_to(project).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(project.rglob("*")) if p.is_file() and "target" not in p.relative_to(project).parts}
    report["provenance"]["renderer_sources"] = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted((ROOT / "src/render").glob("*.cj"))}
    report["provenance"]["adapter_version"] = json.loads((ROOT / "tools/highlight/package-lock.json").read_text(encoding='utf-8'))["packages"]["node_modules/highlight.js"]["version"]
    report['provenance']['doc_ir_sha256'] = hashlib.sha256((real / 'docs.json').read_bytes()).hexdigest()
    report['provenance']['lexer_behavior_revisions'] = sorted({
        b['metadata']['codeHighlight']['engineRevision'] for b in blocks(json.loads((real / 'docs.json').read_text(encoding='utf-8')))
        if b.get('metadata', {}).get('codeHighlight', {}).get('language') == 'cangjie'})
    assert hashlib.sha256(args.binary.read_bytes()).hexdigest() == report['provenance']['binary_sha256'], 'binary changed during acceptance'
    (args.workdir / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
