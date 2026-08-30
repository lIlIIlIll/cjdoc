#!/usr/bin/env python3
"""Strict JSON decoding shared by repository, release, and evidence tooling."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number is forbidden: {value}")


def _parse_finite_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed):
        raise ValueError(f"non-finite JSON number is forbidden: {value}")
    return parsed


def _reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON object key is forbidden: {key}")
        result[key] = value
    return result


def strict_loads(value: str | bytes | bytearray, *, description: str = "JSON") -> Any:
    try:
        if isinstance(value, (bytes, bytearray)):
            value = bytes(value).decode("utf-8", "strict")
        return json.loads(
            value,
            object_pairs_hook=_reject_duplicates,
            parse_constant=_reject_constant,
            parse_float=_parse_finite_float,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError(f"invalid strict {description}: {error}") from error


def strict_load(path: Path, *, description: str | None = None) -> Any:
    label = description or path.as_posix()
    try:
        content = path.read_bytes()
    except OSError:
        raise
    return strict_loads(content, description=label)


def strict_dumps(value: Any, **kwargs: Any) -> str:
    kwargs["allow_nan"] = False
    return json.dumps(value, **kwargs)
