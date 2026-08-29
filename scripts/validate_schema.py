#!/usr/bin/env python3
"""Validate cjdoc JSON artifacts against a selected Draft 2020-12 schema."""

import json
import pathlib
import sys

from jsonschema import Draft202012Validator
from referencing import Registry, Resource


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: validate_schema.py <schema.json> <docs.json>...", file=sys.stderr)
        return 2

    schema_path = pathlib.Path(sys.argv[1])
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    registry = Registry()
    for sibling in schema_path.parent.glob("*.json"):
        sibling_schema = json.loads(sibling.read_text(encoding="utf-8"))
        if schema_id := sibling_schema.get("$id"):
            registry = registry.with_resource(schema_id, Resource.from_contents(sibling_schema))
    validator = Draft202012Validator(schema, registry=registry)

    failed = False
    for document_name in sys.argv[2:]:
        document_path = pathlib.Path(document_name)
        document = json.loads(document_path.read_text(encoding="utf-8"))
        errors = sorted(validator.iter_errors(document), key=lambda error: list(error.absolute_path))
        if errors:
            failed = True
            for error in errors:
                location = "/".join(str(part) for part in error.absolute_path) or "<root>"
                print(f"{document_path}:{location}: {error.message}", file=sys.stderr)
        else:
            print(f"schema valid: {document_path}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
