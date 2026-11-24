"""Generate the shared highlighter fixture and exercise real worker lifecycles."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from highlight_process import assert_stopped, cleanup_observed, observe_cancel_targets

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


def _check_worker_mode(args, project, mode, original_literals, report):
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
    return original_literals


def check_worker_modes(args, project, report):
    original_literals = None
    for mode in (
        'real', 'threaded', 'wrong-id', 'wrong-engine', 'crash', 'timeout',
        'oversized-output', 'noisy-stderr',
    ):
        original_literals = _check_worker_mode(args, project, mode, original_literals, report)


def check_cli_cancellation(args, project, report):
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


def check_api_cancellation(args, project, report):
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
