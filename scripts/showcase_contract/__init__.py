"""Fail-closed contracts for cjdoc's static showcase (issue #50).

This package consumes generated navigation/report artifacts. It does not infer
Cangjie semantics or replace the generator, browser scenarios, or report engines.
"""

from .contract import ContractError, resolve_plan
from .evidence import validate_evidence
from .site import Site

__all__ = ["ContractError", "Site", "resolve_plan", "validate_evidence"]
