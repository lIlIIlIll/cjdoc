#!/usr/bin/env python3
"""Deterministic proof-integrity regressions; no model or compiler is simulated.

Synthetic capture records exercise validation/state boundaries only. Actual
compiler, sandbox and executable witnesses are exercised by the explicit native
verification flow, never replaced with fabricated successful SDK receipts here.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import select
import signal
import sys
import tempfile
import unittest
from types import SimpleNamespace

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import agent_evaluation as evaluation
import agent_evaluation_proof as proof
import agent_evaluation_runtime as runtime

REPO = SCRIPTS.parent
PROTOCOL = REPO / 'tests/agent/evaluation-protocol.json'
RUBRIC = REPO / 'tests/agent/evaluation-rubric.json'
SAMPLE_CONSUMER = 'main(): Int64 { println("synthetic state-machine input"); return 0 }\n'


def write_json(path: Path, value: object) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
    return path


def frozen():
    protocol = evaluation.load_protocol(PROTOCOL)
    return protocol, evaluation.load_rubric(RUBRIC, protocol)


def answer_text(task: dict, code: str = '') -> str:
    return json.dumps({'selectedScopes': [task['scope']], 'apiChoices': [],
        'facts': ['synthetic state-machine input'], 'caveats': [], 'citations': [],
        'consumerCode': code})


def session_record(task: dict, arm: str, *, code: str = '', budgets=None) -> dict:
    return {'schemaVersion': 'cjdoc.agent-evaluation-record/1',
        'task': {'id': task['id'], 'scope': task['scope'], 'prompt': task['prompt'],
                 'behaviorRequired': task['behaviorRequired'],
                 'requiredFacts': list(task['requiredFacts'])},
        'arm': arm, 'ordinal': 1, 'armPosition': 0,
        'client': {'process': {'exitCode': 0, 'timedOut': False, 'elapsedMs': 1},
                   'threadId': None, 'failedTurns': 0, 'errors': []},
        'toolUse': {'calls': 0, 'resultBytes': 0, 'requests': [], 'results': []},
        'answer': {'raw': answer_text(task, code), 'consumerCode': code,
                   'present': True, 'missingFields': [], 'extraFields': [], 'parseError': None},
        'budgets': budgets or frozen()[0]['budgets'], 'budgetFailures': [],
        'budgetExceeded': [], 'contractBreaches': [], 'measurementGaps': []}


def build_capture(root: Path, *, codes=None, no_code=None, budgets=None) -> Path:
    protocol, _ = frozen()
    output = root / 'run'
    output.mkdir(parents=True, exist_ok=True)
    write_json(output / evaluation.MANIFEST_NAME, {
        'schemaVersion': 'cjdoc.agent-evaluation-run/1',
        'purpose': 'synthetic integrity fixture; no Agent was invoked',
        'protocol': {'sha256': proof.digest_of(PROTOCOL)},
        'rubric': {'sha256': proof.digest_of(RUBRIC)},
        'budgets': budgets or protocol['budgets']})
    for task in protocol['tasks']:
        for arm in evaluation.ARMS:
            code = '' if task['id'] in (no_code or set()) else (codes or {}).get(task['id'], SAMPLE_CONSUMER)
            write_json(output / 'sessions' / task['id'] / arm / evaluation.RECORD_NAME,
                       session_record(task, arm, code=code, budgets=budgets))
    return output


class CaptureIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.protocol, self.rubric = frozen()
        self.output = build_capture(self.root)

    def capture(self):
        return proof.Capture(self.output, self.protocol, self.rubric, PROTOCOL, RUBRIC)

    def mutate_record(self, mutate, task='AG-01', arm=evaluation.ARMS[0]):
        path = self.output / 'sessions' / task / arm / evaluation.RECORD_NAME
        document = json.loads(path.read_text('utf-8'))
        mutate(document)
        write_json(path, document)

    def test_missing_session_cannot_be_dropped_from_comparison(self):
        (self.output / 'sessions/AG-03' / evaluation.ARMS[1] / evaluation.RECORD_NAME).unlink()
        with self.assertRaises(proof.ProofError):
            self.capture()

    def test_changed_frozen_fact_is_not_a_valid_trial(self):
        self.mutate_record(lambda row: row['task']['requiredFacts'].pop())
        with self.assertRaises(proof.ProofError):
            self.capture()

    def test_changed_requested_scope_is_not_the_frozen_task(self):
        self.mutate_record(lambda row: row['task'].update(scope='pocketkit@0.1.0'))
        with self.assertRaises(proof.ProofError):
            self.capture()

    def test_changed_question_is_not_the_frozen_task(self):
        self.mutate_record(lambda row: row['task'].update(prompt='A different task'))
        with self.assertRaises(proof.ProofError):
            self.capture()

    def test_budget_relaxation_is_rejected(self):
        budgets = dict(self.protocol['budgets'])
        budgets['maximumToolCallsPerTask'] += 1
        with self.assertRaises(proof.ProofError):
            proof.checked_budgets(budgets, self.protocol['budgets'], 'fixture')

    def test_budget_policy_cannot_disappear(self):
        budgets = {key: value for key, value in self.protocol['budgets'].items() if type(value) is int}
        with self.assertRaises(proof.ProofError):
            proof.checked_budgets(budgets, self.protocol['budgets'], 'fixture')

    def test_boolean_is_not_an_integer_budget(self):
        budgets = dict(self.protocol['budgets'], maximumToolCallsPerTask=True)
        with self.assertRaises(proof.ProofError):
            proof.checked_budgets(budgets, self.protocol['budgets'], 'fixture')

    def test_cached_code_cannot_replace_the_raw_model_answer(self):
        self.mutate_record(lambda row: row['answer'].update(consumerCode='main(): Int64 { 99 }'))
        capture = self.capture()
        entry = proof.initial_consumer(capture, self.protocol['tasks'][0], evaluation.ARMS[0])
        self.assertIsNotNone(entry['integrityFailure'])
        self.assertEqual(entry['consumerCodeSha256'], proof.digest_text(SAMPLE_CONSUMER))

    def test_whitespace_program_is_not_silently_marked_not_applicable(self):
        task = next(task for task in self.protocol['tasks'] if not task['behaviorRequired'])
        self.mutate_record(lambda row: row['answer'].update(raw=answer_text(task, '  \n'), consumerCode='  \n'), task=task['id'])
        entry = proof.initial_consumer(self.capture(), task, evaluation.ARMS[0])
        self.assertEqual(entry['state'], 'pending')
        self.assertEqual(entry['consumerCodeBytes'], 3)

    def test_missing_required_program_is_not_a_compile_success(self):
        task = self.protocol['tasks'][0]
        self.mutate_record(lambda row: row['answer'].update(raw=answer_text(task, ''), consumerCode=''))
        entry = proof.initial_consumer(self.capture(), task, evaluation.ARMS[0])
        self.assertEqual(entry['state'], 'missing-code')
        self.assertIsNone(entry['compile'])

    def test_sdk_setup_failure_retains_every_generated_program(self):
        capture = self.capture()
        arguments = SimpleNamespace(project_root=REPO, verification=self.root / 'verification',
            sdk_root=self.root / 'missing-sdk', protocol=PROTOCOL, rubric=RUBRIC,
            compile_seconds=10, run_seconds=10)
        result = proof.verify_stage(arguments, self.protocol, self.rubric, capture)
        receipt = json.loads(result['path'].read_text('utf-8'))
        expected = {(task['id'], arm) for task in self.protocol['tasks'] for arm in evaluation.ARMS}
        self.assertEqual({(row['task'], row['arm']) for row in receipt['consumers']}, expected)
        self.assertEqual(receipt['setupFailures'][0]['stage'], 'toolchain')
        for row in receipt['consumers']:
            self.assertEqual(row['state'], 'infrastructure-failed')
            self.assertEqual(row['failure']['kind'], 'verification-infrastructure')
            self.assertIsNone(row['compile'])


class EvidenceAndGradeBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.protocol, _ = frozen()
        self.task = self.protocol['tasks'][0]
        self.record = session_record(self.task, evaluation.ARMS[0], code=SAMPLE_CONSUMER)
        # State-machine input only: these tests never submit this object as an
        # actual compiler/runtime witness to load_verification.
        self.receipt = {'task': self.task['id'], 'arm': evaluation.ARMS[0],
            'state': 'compiled', 'scopeBinding': {'state': 'verified'},
            'behavior': {'state': 'runtime-executed', 'run': {
                'exitCode': 0, 'timedOut': False, 'launchError': None,
                'stdout': {'text': 'synthetic state-machine input\n'}, 'stderr': {'text': ''}}}}
        self.adequate = {'behaviorReview': {'verdict': 'adequate', 'coversTaskBoundaries': True},
                         'behaviorAssertions': [{'verdict': 'observed'}]}

    def state(self, assessment=None):
        return proof.consumer_behavior_state(self.task, self.record, self.receipt, assessment)

    def test_exit_zero_alone_is_not_behavior_verified(self):
        self.assertEqual(self.state(), 'runtime-executed-behavior-unverified')

    def test_a_print_only_program_can_be_explicitly_graded_inadequate(self):
        self.assertEqual(self.state({'behaviorReview': {'verdict': 'inadequate'}, 'behaviorAssertions': []}), 'failed')

    def test_adequate_review_without_executed_checks_stays_unverified(self):
        self.assertEqual(self.state({'behaviorReview': {'verdict': 'adequate', 'coversTaskBoundaries': True},
                                    'behaviorAssertions': []}), 'runtime-executed-behavior-unverified')

    def test_review_not_covering_task_boundaries_stays_unverified(self):
        self.adequate['behaviorReview']['coversTaskBoundaries'] = False
        self.assertEqual(self.state(self.adequate), 'runtime-executed-behavior-unverified')

    def test_runtime_failure_cannot_be_overridden_by_a_review(self):
        self.receipt['behavior']['run']['exitCode'] = 7
        self.assertEqual(self.state(self.adequate), 'runtime-failed')

    def test_runtime_timeout_cannot_be_overridden_by_a_printed_marker(self):
        self.receipt['behavior']['run']['timedOut'] = True
        self.assertEqual(self.state(self.adequate), 'runtime-timeout')

    def test_unsupported_library_binding_is_not_verified_compilation(self):
        self.receipt['scopeBinding']['state'] = 'unavailable'
        self.assertEqual(proof.consumer_compile_state(self.receipt, self.task, self.record),
                         'compiled-without-requested-library')

    def test_an_asserted_output_must_actually_have_been_captured(self):
        errors = proof.check_assertion_evidence({'kind': 'stdout', 'quote': 'never printed'},
                                                self.receipt['behavior'], 'fixture')
        self.assertEqual(len(errors), 1)

    def test_boolean_false_is_not_an_exit_zero_observation(self):
        errors = proof.check_assertion_evidence({'kind': 'exit-code', 'exitCode': False},
                                                self.receipt['behavior'], 'fixture')
        self.assertEqual(len(errors), 1)

    def test_review_of_different_consumer_bytes_is_rejected(self):
        review = {'method': 'manual-source-and-control-flow-audit',
            'consumerCodeSha256': proof.digest_text(SAMPLE_CONSUMER + '\n'), 'verdict': 'adequate',
            'coversTaskBoundaries': True, 'codeQuote': 'return 0',
            'reason': 'Synthetic metadata validation; not a real adequacy claim'}
        errors = proof.check_behavior_review(review, SAMPLE_CONSUMER, 'fixture')
        self.assertEqual(len(errors), 1)

    def test_invalid_assessment_cannot_promote_behavior_or_api_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            output = build_capture(Path(directory))
            protocol, rubric = frozen()
            capture = proof.Capture(output, protocol, rubric, PROTOCOL, RUBRIC)
            adjudicated = dict(self.adequate, dimensions={'apiSelection': {'value': 1}},
                               contractOmissions=0, citations=[], citationDenominator=0)
            row = proof.row_for(capture, self.task, evaluation.ARMS[0], self.receipt,
                                {}, ['invalid source evidence'], adjudicated, protocol)
            self.assertEqual(row['adjudication']['state'], 'invalid')
            self.assertIsNone(row['dimensions']['apiSelection'])
            self.assertIsNone(row['dimensions']['contractOmissions'])
            self.assertEqual(row['dimensions']['consumerBehavior'], 'runtime-executed-behavior-unverified')


class ScopeAndProcessBoundaryTests(unittest.TestCase):
    def test_wrong_actual_package_version_is_rejected(self):
        protocol, _ = frozen()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / 'examples/pocketkit/demo-v2/cjpm.toml'
            manifest.parent.mkdir(parents=True)
            manifest.write_text('[package]\nname="pocketkit"\nversion="9.9.9"\n', encoding='utf-8')
            with self.assertRaises(proof.ProofError):
                proof.resolve_scopes({'tasks': [protocol['tasks'][0]]}, root)

    def test_unmapped_scope_cannot_be_rebound_to_the_available_library(self):
        protocol, _ = frozen()
        task = dict(protocol['tasks'][0], scope='unrecorded@9.9.9')
        with self.assertRaises(proof.ProofError):
            proof.resolve_scopes({'tasks': [task]}, REPO)

    def test_dependency_cannot_escape_the_frozen_project_root(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / 'repo'
            library = root / 'lib'
            library.mkdir(parents=True)
            (base / 'outside').mkdir()
            (base / 'outside/cjpm.toml').write_text('[package]\nname="outside"\nversion="1.0.0"\n', encoding='utf-8')
            (library / 'cjpm.toml').write_text('[package]\nname="lib"\nversion="1.0.0"\n[dependencies]\noutside={path="../../outside"}\n', encoding='utf-8')
            with self.assertRaises((RuntimeError, ValueError)):
                runtime.source_closure(root, [library])

    @unittest.skipUnless(hasattr(signal, 'pause'), 'timeout scenario requires POSIX signals')
    def test_timeout_has_a_bounded_real_process_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            labels = proof.Labels([(root, '<test>')])
            result = runtime.run_process([sys.executable, '-c', 'import signal; signal.pause()'],
                root, {'PATH': os.defpath}, 0.05, root / 'logs', labels)
            self.assertTrue(result['timedOut'])
            self.assertLess(result['exitCode'], 0)
            self.assertIsNone(result['launchError'])

    @unittest.skipUnless(sys.platform.startswith('linux') and hasattr(os, 'fork') and hasattr(os, 'pidfd_open'),
                         'process-group lifecycle requires Linux pidfds')
    def test_exited_leader_does_not_leave_a_live_descendant(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            labels = proof.Labels([(root, '<test>')])
            program = ('import os,signal\n'
                'ready_r,ready_w=os.pipe()\n'
                'pid=os.fork()\n'
                'if pid==0:\n'
                ' os.close(ready_r); os.write(ready_w,b"1"); os.close(ready_w); signal.pause()\n'
                'else:\n'
                ' os.close(ready_w); os.read(ready_r,1); os.close(ready_r); print(pid,flush=True)\n')
            result = runtime.run_process([sys.executable, '-c', program], root,
                {'PATH': os.defpath}, 2, root / 'logs', labels)
            self.assertEqual(result['exitCode'], 0)
            descendant = int(result['stdout']['text'].strip())
            try:
                descriptor = os.pidfd_open(descendant)
            except ProcessLookupError:
                return
            try:
                readable, _, _ = select.select([descriptor], [], [], 2)
                self.assertEqual(readable, [descriptor])
            finally:
                os.close(descriptor)

    def test_stream_summary_binds_actual_bytes_not_normalized_display_length(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / 'output'
            payload = (str(root) + '/result 汉字\n').encode('utf-8')
            log.write_bytes(payload)
            summary = runtime.stream_record(log, proof.Labels([(root, '<test>')]))
            self.assertEqual(summary['bytes'], len(payload))
            self.assertEqual(summary['sha256'], proof.digest_of(log))
            self.assertEqual(summary['text'], '<test>/result 汉字\n')
            self.assertFalse(summary['truncated'])


if __name__ == '__main__':
    unittest.main()
