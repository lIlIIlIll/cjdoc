#!/usr/bin/env python3
"""Capture one fixed reader cohort; a bounded unsupported scale is never labelled PASS."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
try:
    from .reader_benchmark import run
    from .reader_corpus import generate_corpus
    from .reader_external import prepare
    from .strict_json import strict_load
except ImportError:
    from reader_benchmark import run
    from reader_corpus import generate_corpus
    from reader_external import prepare
    from strict_json import strict_load


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--corpus", choices=("1000", "10000", "50000", "external"), default="1000")
    parser.add_argument("--label", choices=("baseline", "after"), default="baseline")
    args = parser.parse_args()
    root = args.output.absolute()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    corpus = root / "corpus"
    if args.corpus == "external":
        prepared = prepare(corpus)
        project = corpus / prepared["project"]
    else:
        generate_corpus(corpus, int(args.corpus))
        project = corpus
    options = argparse.Namespace(binary=args.binary, project=project, manifest=corpus / "reader-corpus.json",
        output=root / "observation", revision=args.revision, label=args.label,
        locales=["en", "zh-CN"], samples=20, transports="root,subpath,file", screenshots=True,
        no_browser=False, timeout=1800, browser_timeout=1800)
    code = run(options)
    observation = strict_load(options.output / "reader-generation.json")
    status = observation["status"]
    print(json.dumps({"corpus": args.corpus, "status": status,
                      "semantics": "measurement completed is not a claim of supported scale or human usability"}))
    # The supported 1k cohort must complete. Larger/manual cohorts may measure
    # a native rejection, but an arbitrary failure must still fail the workflow.
    if code and args.corpus != "1000" and status == "resource-limited":
        return 0
    return code


if __name__ == "__main__":
    raise SystemExit(main())
