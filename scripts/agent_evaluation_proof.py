#!/usr/bin/env python3
"""Compile every captured consumer verbatim and adjudicate the frozen Agent comparison.

`verify` uses the selected Cangjie SDK inside a Linux x86-64 bubblewrap sandbox.
It captures the requested local dependency closure, builds fresh static exports,
and invokes cjc once on the exact consumerCode UTF-8 bytes. It never inserts a
package declaration, repairs imports or retries a generated program. Every task
and arm is checkpointed, including missing code and infrastructure failures.

Required programs execute with only runtime libraries, no inherited credentials,
no host home or network, read-only filesystems, bounded logs and a process-group
deadline. The supervisor blocks process creation in runtime consumers. Compiler
and runtime receipts identify their actual executable and source/output bytes.

`template` lists every frozen fact, citation and separately adjudicated dimension.
`report` binds evidence to captured Doc IR hashes and actual source identities.
A zero exit status or printed marker alone is not behavioral proof. Required
behavior also needs a manual whole-program/source/control-flow adequacy review,
exact exercise/check code excerpts, implementation-source evidence and observed
runtime evidence. These are explicit reviewer judgments, not automatic semantic
proof or keyword scoring. Invalid assessments never promote behavior to verified.

Run verify --output "$RUN" --project-root . --sdk-root "$SDK" first; fill the
emitted adjudication template, then run report with --adjudications and --doc-ir
LABEL=PATH. Optional --final PATH overrides the default final-report.json.
`report` refuses final publication while any verification/adjudication gap remains.
`observations` retains measured outcomes without assigning natural-language scores.
Published reports normalize registered local roots; private captures retain the
original bytes used for hashes and compilation.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
try:
    from .agent_evaluation_assessment import template_stage
    from .agent_evaluation_capture import (
        PROTOCOL, REPO, RUBRIC, VERIFICATION_DIRECTORY, VERIFICATION_NAME,
        Capture, ProofError, load_frozen)
    from .agent_evaluation_consumers import (
        DEFAULT_COMPILE_SECONDS, DEFAULT_RUN_SECONDS, verify_stage)
    from .agent_evaluation_report import labels_scrub, observations_stage, report_stage
except ImportError:  # Direct script execution.
    from agent_evaluation_assessment import template_stage
    from agent_evaluation_capture import (
        PROTOCOL, REPO, RUBRIC, VERIFICATION_DIRECTORY, VERIFICATION_NAME,
        Capture, ProofError, load_frozen)
    from agent_evaluation_consumers import (
        DEFAULT_COMPILE_SECONDS, DEFAULT_RUN_SECONDS, verify_stage)
    from agent_evaluation_report import labels_scrub, observations_stage, report_stage

try:
    import agent_evaluation as evaluation
except ImportError:  # Package execution.
    from . import agent_evaluation as evaluation

# Stage ownership, so a policy change has one destination:
# * agent_evaluation_capture -- frozen inputs, scopes, budgets, the capture
# * agent_evaluation_consumers -- the one-shot compile/run verification stage
# * agent_evaluation_evidence -- source/Doc IR evidence admissibility
# * agent_evaluation_assessment -- adjudication rules and the review template
# * agent_evaluation_states -- per-row outcomes and rubric aggregation
# * agent_evaluation_report -- receipt validation, final report, observations


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Compile, run and adjudicate the frozen paired Agent evaluation.",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    def common(subparser: argparse.ArgumentParser) -> None:
        subparser.add_argument("--output", required=True, type=Path,
                               help="captured evaluator output directory")
        subparser.add_argument("--protocol", default=PROTOCOL, type=Path)
        subparser.add_argument("--rubric", default=RUBRIC, type=Path)
        subparser.add_argument("--project-root", default=REPO, type=Path,
                               help="checkout containing the frozen scope sources")

    verify = subparsers.add_parser(
        "verify", help="compile and run every generated consumer once")
    common(verify)
    verify.add_argument("--verification", type=Path,
                        help="verification directory (default <output>/verification)")
    verify.add_argument("--sdk-root", type=Path,
                        help="installed Cangjie SDK root; sets CANGJIE_HOME")
    verify.add_argument("--compile-seconds", type=int, default=DEFAULT_COMPILE_SECONDS)
    verify.add_argument("--run-seconds", type=int, default=DEFAULT_RUN_SECONDS)

    report = subparsers.add_parser(
        "report", help="combine capture, verification and adjudication")
    common(report)
    report.add_argument("--verification", type=Path,
                        help="verification receipt "
                             "(default <output>/verification/verification.json)")
    report.add_argument("--adjudications", required=True, type=Path)
    report.add_argument("--doc-ir", action="append", default=[], metavar="LABEL=PATH")
    report.add_argument("--final", type=Path,
                        help="final report path (default <output>/final-report.json)")
    report.add_argument("--observations", type=Path,
                        help="also write explicit observations next to the report")

    observe = subparsers.add_parser(
        "observations", help="publish measured facts without any score")
    common(observe)
    observe.add_argument("--verification", type=Path)
    observe.add_argument("--out", type=Path)

    template = subparsers.add_parser(
        "template", help="write an empty adjudication skeleton for reviewers")
    common(template)
    template.add_argument("--out", required=True, type=Path)
    return parser


def _capture(args: argparse.Namespace) -> tuple[dict, dict, Capture]:
    protocol_path = Path(os.path.abspath(args.protocol))
    rubric_path = Path(os.path.abspath(args.rubric))
    protocol, rubric = load_frozen(protocol_path, rubric_path)
    if "sourceCitationBaseline" in protocol:
        evaluation.verify_source_slices(protocol, args.project_root)
    capture = Capture(Path(args.output), protocol, rubric, protocol_path, rubric_path)
    return protocol, rubric, capture


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        protocol, rubric, capture = _capture(args)
        if args.command == "verify":
            result = verify_stage(args, protocol, rubric, capture)
            print(result["path"])
            return 0
        if args.command == "observations":
            verification_file = (Path(os.path.abspath(args.verification))
                                 if args.verification else None)
            observations = observations_stage(capture, verification_file, protocol)
            destination = Path(os.path.abspath(args.out)) if args.out else \
                capture.output / "observations.json"
            evaluation.write_json(destination, observations)
            print(destination)
            return 0
        if args.command == "template":
            destination = Path(os.path.abspath(args.out))
            evaluation.write_json(destination, template_stage(capture, protocol))
            print(destination)
            return 0
        report, gaps = report_stage(args, protocol, rubric, capture)
        destination = (Path(os.path.abspath(args.final)) if args.final
                       else capture.output / "final-report.json")
        if args.observations:
            # Observations are measurable with or without a final report.
            verification_file = Path(os.path.abspath(
                args.verification or capture.output / VERIFICATION_DIRECTORY
                / VERIFICATION_NAME))
            evaluation.write_json(
                Path(os.path.abspath(args.observations)),
                labels_scrub(observations_stage(capture, verification_file,
                                                protocol), capture))
        if gaps:
            for gap in gaps:
                print(f"gap {gap['kind']} {gap['task']}:{gap['arm']}: {gap['detail']}",
                      file=sys.stderr)
            print(f"error: refusing a final report with {len(gaps)} outstanding "
                  f"items; supply complete source-backed assessments", file=sys.stderr)
            return 3
        evaluation.write_json(destination, report)
        print(destination)
        return 0
    except (ProofError, evaluation.ProtocolError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
