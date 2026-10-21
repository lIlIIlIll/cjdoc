"""Normalize Doc IR 16 / inventory 2 wire into public model-shaped tooling data.

Only Doc IR 16 TypeRef wire flattens the three named semantic facts. Navigation
normalization does not resolve or authenticate links, and published legacy
Doc IR/provider/index/API-surface formats are not rewritten.
"""
from __future__ import annotations

FIELDS = ('state', 'matchLevel', 'reason', 'dependencyInstanceId', 'documentSetId',
          'indexIdentity', 'symbolKey', 'url', 'apiIdentity', 'language')
CONTEXT = FIELDS[3:]
FAILURE_STATES = frozenset(('unresolved', 'ambiguous', 'unavailable'))
NAVIGATION_KEYS = frozenset(('navigation', 'semanticNavigation'))
TYPE_KEYS = frozenset(('kind', 'spelling', 'nullable', 'arguments'))
SEMANTIC_KEYS = ('state', 'canonical', 'provider')
SEMANTIC_WIRE_KEYS = ('semanticState', 'semanticCanonical', 'semanticProvider')


def context_free_failure(value):
    return (isinstance(value, dict) and set(value) == set(FIELDS)
            and value['state'] in FAILURE_STATES and value['matchLevel'] == 'none'
            and all(value[key] == '' for key in CONTEXT))


def decode_navigation(value):
    if value is None:
        return None
    if isinstance(value, list):
        if (len(value) != 2 or not all(isinstance(item, str) for item in value)
                or value[0] not in FAILURE_STATES or not value[1].strip(' \t\r\n\v\f')):
            raise ValueError('navigation failure requires [non-resolved state, nonempty reason]')
        result = dict.fromkeys(FIELDS, '')
        result.update(state=value[0], matchLevel='none', reason=value[1])
        return result
    if not isinstance(value, dict) or set(value) != set(FIELDS):
        raise ValueError('navigation context object has missing or unknown fields')
    if not all(isinstance(value[key], str) for key in FIELDS):
        raise ValueError('navigation context fields must be strings')
    if context_free_failure(value):
        raise ValueError('context-free failure must use its canonical two-value wire')
    return value


def encode_navigation(value):
    if context_free_failure(value):
        return [value['state'], value['reason']]
    return value


def _transform(value, decode, flat_type_semantics):
    if isinstance(value, dict):
        result = {}
        for key, child in value.items():
            if key in NAVIGATION_KEYS:
                result[key] = decode_navigation(child) if decode else encode_navigation(child)
            else:
                result[key] = _transform(child, decode, flat_type_semantics)
        if flat_type_semantics and TYPE_KEYS.issubset(value):
            if decode:
                if 'semantic' in value or not set(SEMANTIC_WIRE_KEYS).issubset(value):
                    raise ValueError('Doc IR 16 requires exactly its three flat semantic facts')
                result['semantic'] = {key: result.pop(wire)
                                      for key, wire in zip(SEMANTIC_KEYS, SEMANTIC_WIRE_KEYS)}
            else:
                semantic = result.pop('semantic', None)
                if not isinstance(semantic, dict) or set(semantic) != set(SEMANTIC_KEYS):
                    raise ValueError('public TypeRef model requires all three semantic facts')
                if set(SEMANTIC_WIRE_KEYS).intersection(result):
                    raise ValueError('mixed public-model and flat semantic facts')
                result.update((wire, semantic[key])
                              for key, wire in zip(SEMANTIC_KEYS, SEMANTIC_WIRE_KEYS))
        return result
    if isinstance(value, list):
        return [_transform(child, decode, flat_type_semantics) for child in value]
    return value


def decode_document_navigation(value):
    current = isinstance(value, dict) and value.get('schemaVersion') == 'cjdoc.doc-ir/16'
    return _transform(value, True, current)


def encode_document_navigation(value):
    current = isinstance(value, dict) and value.get('schemaVersion') == 'cjdoc.doc-ir/16'
    return _transform(value, False, current)
