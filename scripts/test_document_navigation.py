"""Public navigation wire normalization, without dependency or URL inference."""
import unittest

from document_navigation import (CONTEXT, FIELDS, decode_document_navigation,
                                 decode_navigation, encode_document_navigation,
                                 encode_navigation)


class DocumentNavigationWireTest(unittest.TestCase):
    def test_all_failure_states_keep_unicode_control_and_public_fields(self):
        reason = '中文\n\t"quoted"\\tail\0'
        for state in ('unresolved', 'ambiguous', 'unavailable'):
            with self.subTest(state=state):
                original = {'types': [{'navigation': [state, reason]}],
                            'markdown': {'semanticNavigation': [state, reason]}}
                decoded = decode_document_navigation(original)
                navigation = decoded['types'][0]['navigation']
                self.assertEqual(set(navigation), set(FIELDS))
                self.assertEqual(navigation['matchLevel'], 'none')
                self.assertTrue(all(navigation[field] == '' for field in CONTEXT))
                self.assertEqual(navigation['reason'], reason)
                self.assertEqual(encode_document_navigation(decoded), original)
                self.assertIsInstance(original['types'][0]['navigation'], list)

    def test_each_context_field_and_non_none_grade_stay_complete_objects(self):
        for field in (*CONTEXT, 'matchLevel'):
            with self.subTest(field=field):
                value = dict.fromkeys(FIELDS, '')
                value.update(state='unavailable', matchLevel='none', reason='context')
                value[field] = 'manual' if field == 'matchLevel' else 'retained-context'
                self.assertEqual(decode_navigation(encode_navigation(value)), value)
                self.assertIsInstance(encode_navigation(value), dict)

    def test_malformed_tuples_and_ambiguous_object_shape_are_rejected(self):
        for value in ([], ['unavailable'], ['resolved', 'reason'], ['other', 'reason'],
                      ['unavailable', 1], [False, 'reason'], ['unavailable', ''],
                      ['unavailable', 'reason', 'context']):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    decode_navigation(value)
        value = dict.fromkeys(FIELDS, '')
        value.update(state='unavailable', matchLevel='none', reason='explanation')
        with self.assertRaises(ValueError):
            decode_navigation(value)

    def test_none_is_preserved_and_malformed_mutations_are_not_repaired(self):
        self.assertIsNone(decode_navigation(None))
        bad = {'navigation': {'state': 'unavailable', 'unexpected': 'must reach decoder'}}
        self.assertEqual(encode_document_navigation(bad), bad)

    def test_current_type_semantic_facts_are_flat_and_lossless_recursively(self):
        semantics = [
            {'state': 'resolved', 'canonical': '库.类型', 'provider': 'types'},
            {'state': 'partial', 'canonical': '库.类型\n"\\', 'provider': None},
            {'state': 'ambiguous', 'canonical': None, 'provider': 'types'},
            {'state': 'unavailable', 'canonical': None, 'provider': None},
        ]
        def reference(semantic, children=()):
            return {'kind': 'generic', 'spelling': '类型', 'nullable': True,
                    'arguments': list(children), 'semantic': semantic, 'navigation': None}
        model = {'schemaVersion': 'cjdoc.doc-ir/15', 'types': [
            reference(semantics[0], [reference(value) for value in semantics[1:]])]}
        wire = encode_document_navigation(model)
        self.assertNotIn('semantic', wire['types'][0])
        self.assertEqual(wire['types'][0]['semanticCanonical'], '库.类型')
        self.assertIsNone(wire['types'][0]['arguments'][0]['semanticProvider'])
        self.assertEqual(decode_document_navigation(wire), model)
        for version in ('cjdoc.doc-ir/6', 'cjdoc.doc-ir/14',
                        'cjdoc.symbol-index/1', 'provider-spi/1', 'cjdoc.api-surface/1'):
            with self.subTest(version=version):
                legacy = {**model, 'schemaVersion': version}
                self.assertEqual(encode_document_navigation(legacy), legacy)

    def test_current_nested_mixed_and_incomplete_semantics_are_not_repaired(self):
        nested = {'schemaVersion': 'cjdoc.doc-ir/15', 'types': [{
            'kind': 'named', 'spelling': 'Token', 'nullable': False, 'arguments': [],
            'semantic': {'state': 'partial', 'canonical': None, 'provider': None},
            'navigation': None}]}
        with self.assertRaises(ValueError):
            decode_document_navigation(nested)
        wire = encode_document_navigation(nested)
        for field in ('semanticState', 'semanticCanonical', 'semanticProvider'):
            incomplete = {**wire, 'types': [{key: value for key, value in wire['types'][0].items()
                                           if key != field}]}
            with self.subTest(field=field), self.assertRaises(ValueError):
                decode_document_navigation(incomplete)
        mixed = {**wire, 'types': [{**wire['types'][0], 'semantic': nested['types'][0]['semantic']}]}
        with self.assertRaises(ValueError):
            decode_document_navigation(mixed)


if __name__ == '__main__':
    unittest.main()
