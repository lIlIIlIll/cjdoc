#!/usr/bin/env python3
"""Generate/replay real package fixtures against independent input identity oracles."""
import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
import shutil
import subprocess
from urllib.parse import unquote, urlsplit

ROOT = 'cjdoc:module:v1:root'
DEPENDENCY = 'cjdoc:module:v1:path:pocketkit_support'


def package_route(module, package='pocketkit'):
    # The fixture's independently prescribed module/package identity determines
    # the expected canonical route; no generated href participates in this oracle.
    key = f'{len(module.encode())}:{module}{package}'
    slug = key.encode().hex()
    if len(slug) > 96:
        first, second = 0, 0
        for byte in key.encode():
            first = (first * 131 + byte) % 2147483647
            second = (second * 257 + byte) % 2147483629
        slug = f'{slug[:64]}--{first}-{second}'
    return 'packages/package-' + slug + '.html'


class Page(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.ids = set()
        self.links = []
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'id' in attrs:
            self.ids.add(attrs['id'])
        if tag == 'a' and 'href' in attrs:
            self.links.append((attrs.get('class', ''), attrs['href']))


def reachable(page, href):
    route = urlsplit(href)
    assert not route.scheme and not route.netloc and route.path, href
    target = (page.parent / unquote(route.path)).resolve()
    assert target.is_file(), (page.name, href)
    if route.fragment:
        assert unquote(route.fragment) in Page(target.read_text()).ids, href
    return target


def config_page(id, source, route, kind='package'):
    return (f'\n[[docs.pages]]\nid="{id}"\nsource="docs/{source}.md"\n'
            f'route="{route}"\npackage="pocketkit"\nkind="{kind}"\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    binary, output = args.binary.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    fixture = Path(__file__).resolve().parents[1] / 'tests/fixtures/projects/package-overview'
    receipts = []

    def run(*command):
        result = subprocess.run([str(binary), *map(str, command)], text=True, capture_output=True)
        assert result.returncode == 0, f'{command[0]} failed ({result.returncode}): {result.stderr}'

    def expected(module=ROOT, *, version='1.0.0', locale='en', id='pocketkit-overview',
                 route='concepts/packages/pocketkit-guide.html', source=None):
        role = 'ROOT' if module == ROOT else 'DEPENDENCY'
        return {'moduleId': module, 'packageName': 'pocketkit', 'pageId': id,
                'route': route, 'source': source or ('docs/pocketkit-zh.md' if locale == 'zh-CN' else 'docs/pocketkit.md'),
                'summary': f'{role}_PURPOSE_{version}_{locale}', 'bodyMarker': f'{role}_BODY_{version}_{locale}',
                'forbiddenBodyMarkers': [f'{"DEPENDENCY" if role == "ROOT" else "ROOT"}_BODY_{version}_{locale}',
                                         f'{role}_BODY_{"2.0.0" if version == "1.0.0" else "1.0.0"}_{locale}',
                                         f'{role}_BODY_{version}_{"zh-CN" if locale == "en" else "en"}']}

    def body(expectation, binding=''):
        original = (fixture / ('docs/pocketkit-zh.md' if expectation['summary'].endswith('zh-CN') else 'docs/pocketkit.md')).read_text()
        heading, rest = original.split('\n\n', 1)
        marker = expectation['summary']
        text = heading + '\n\n' + marker + ' ' + rest + '\n\n' + expectation['bodyMarker'] + '\n'
        if binding:
            text += f'\n<!-- cjdoc-bind target="{binding}" -->\n'
        return text

    def generate(name, *, config=None, empty=None, locale='en', version='1.0.0',
                 multi=False, bindings=None, extra=()):
        project = output / 'projects' / name
        source_fixture = fixture.parent / 'package-overview-empty' if name in ('unconfigured', 'missing') else fixture
        shutil.copytree(source_fixture, project)
        if (project / 'docs').is_dir():
            for language, file in [('en', 'pocketkit'), ('zh-CN', 'pocketkit-zh')]:
                page_expect = expected(version=version, locale=language)
                (project / f'docs/{file}.md').write_text(empty if empty is not None else body(page_expect, (bindings or {}).get(file, '')))
        with (project / 'src/api.cj').open('a') as source:
            source.write(f'\n/** ROOT_API_{version} */\npublic class RootIdentity {{}}\n'
                         '\nprivate class RootSecret {}\n@When[feature == "extra"]\npublic class RootOptional {}\n')
        if config is not None:
            (project / 'cjdoc.toml').write_text(config)
        if multi:
            dep = project / 'deps/two'
            (dep / 'src').mkdir(parents=True)
            (dep / 'cjpm.toml').write_text('[package]\nname="pocketkit_support"\nversion="1.0.0"\noutput-type="static"\n')
            (dep / 'src/api.cj').write_text(f'package pocketkit\n/** DEPENDENCY_API_{version} */\npublic class Entry {{}}\npublic class DepIdentity {{}}\n')
            (dep / 'src/auxiliary').mkdir()
            (dep / 'src/auxiliary/api.cj').write_text('package auxiliary\npublic class Helper {}\n')
            with (project / 'cjpm.toml').open('a') as manifest:
                manifest.write('\n[dependencies]\npocketkit_support={path="deps/two"}\n')
            dep_expect = expected(DEPENDENCY, version=version, locale=locale, id='dependency-overview',
                                  route='concepts/dependency.html', source='docs/dependency.md')
            (project / 'docs/dependency.md').write_text(body(dep_expect, 'pocketkit.DepIdentity'))
            extra = (*extra, '--include-path-dependencies')
        site = output / name
        run('generate', '--project', project, '--format', 'html', '--format', 'json', '--format', 'markdown',
            '--locale', locale, '--doc-version', version, '--output', site, '--no-cache', *extra)
        return site

    def verify(name, site, module=ROOT, expectation=None, *, locale='en', version='1.0.0', aliases=()):
        package = site / 'html' / package_route(module)
        text = package.read_text()
        role = 'ROOT' if module == ROOT else 'DEPENDENCY'
        api_marker = f'{role}_API_{version}'
        other_api = f'{"DEPENDENCY" if role == "ROOT" else "ROOT"}_API_{version}'
        assert api_marker in text and other_api not in text, name
        assert ('class="package-overview"' in text) == (expectation is not None), name
        assert 'This page describes the conceptual role' not in text, name
        assert 'catalogue-workflow-full-text' not in text, name
        data = json.loads((site / 'docs.json').read_text()) if (site / 'docs.json').exists() else None
        if data:
            assert any(p['moduleId'] == module and p['name'] == 'pocketkit' for p in data['packages']), name
            identity = 'RootIdentity' if module == ROOT else 'DepIdentity'
            assert any(d['moduleId'] == module and d['packageName'] == 'pocketkit' and d['name'] == identity
                       for d in data['declarations']), name
        receipt = {'name': name, 'package': str(package.relative_to(output)), 'authored': expectation is not None,
                   'locale': locale, 'moduleId': module, 'packageName': 'pocketkit', 'apiMarker': api_marker,
                   'forbiddenApiMarker': other_api}
        if expectation:
            assert expectation['moduleId'] == module
            guide = site / 'html' / expectation['route']
            links = [href for cls, href in Page(text).links if cls == 'package-overview-link']
            assert len(links) == 1 and reachable(package, links[0]) == guide.resolve(), name
            assert expectation['summary'] in text, name
            guide_text = guide.read_text()
            assert expectation['bodyMarker'] in guide_text, name
            assert all(marker not in guide_text for marker in expectation['forbiddenBodyMarkers']), name
            back = [href for cls, href in Page(guide_text).links if href.endswith('#declarations')]
            assert len(back) == 1 and reachable(guide, back[0]) == package.resolve(), name
            assert expectation['bodyMarker'] not in text, name
            if data:
                assert any(p['id'] == expectation['pageId'] and p['route'] == expectation['route'] and
                           p['packageName'] == 'pocketkit' and p['source'] == expectation['source'] for p in data['pages']), name
            receipt.update({'guide': str(guide.relative_to(output)), **expectation})
            section = text.split('<section class="package-overview"', 1)[1].split('</section>', 1)[0]
            for alias in aliases:
                assert alias not in section, name
                alias_page = site / 'html' / alias
                alias_back = [href for _, href in Page(alias_page.read_text()).links if href.endswith('#declarations')]
                assert len(alias_back) == 1 and reachable(alias_page, alias_back[0]) == package.resolve(), name
        else:
            assert '_PURPOSE_' not in text, name
        receipts.append(receipt)

    def replay(name, site, checks):
        target = output / ('replay-' + name)
        run('render', '--input', site / 'docs.json', '--format', 'html', '--format', 'json', '--locale', 'en', '--output', target)
        for module, expectation, aliases in checks:
            verify('replay-' + name + '-' + ('root' if module == ROOT else 'dependency'), target, module, expectation, aliases=aliases)

    for locale in ['en', 'zh-CN']:
        site = generate('authored-' + locale, locale=locale)
        verify('authored-' + locale, site, expectation=expected(locale=locale), locale=locale)
    for name, config, empty in [('unconfigured', '', None), ('missing', '[docs.packages]\npocketkit="docs/absent.md"\n', None),
                                ('empty', None, ''), ('heading-only', None, '# Catalogue\n\n<!-- only a comment -->\n')]:
        verify(name, generate(name, config=config, empty=empty))

    auto = '[docs.packages]\npocketkit="docs/pocketkit.md"\n'
    explicit = config_page('root-overview', 'pocketkit', 'concepts/root')
    root_page = expected(id='root-overview', route='concepts/root.html')
    auto_page = expected(id='concepts/packages/pocketkit.html', route='concepts/packages/pocketkit.html')
    for name, config, page, aliases in [
        ('configured', auto, auto_page, ()),
        ('same-source-auto-explicit', auto + explicit, auto_page, ('concepts/root.html',)),
        ('same-source-two-guides', explicit + config_page('other', 'pocketkit', 'concepts/other', kind='guide'), root_page, ('concepts/other.html',)),
    ]:
        site = generate(name, config=config)
        verify(name, site, expectation=page, aliases=aliases)
        replay(name, site, [(ROOT, page, aliases)])

    for name, target, extra, present in [
        ('hidden', 'pocketkit.RootSecret', (), False), ('all-audience', 'pocketkit.RootSecret', ('--audience', 'all'), True),
        ('cfg-filtered', 'pocketkit.RootOptional', ('--cfg', 'feature=disabled'), False),
        ('cfg-enabled', 'pocketkit.RootOptional', ('--cfg', 'feature=extra'), True), ('missing-target', 'absent.Dependency', (), False),
    ]:
        site = generate(name, config=explicit, bindings={'pocketkit': target}, extra=extra)
        verify(name, site, expectation=root_page if present else None)

    dep_config = config_page('dependency-overview', 'dependency', 'concepts/dependency')
    dep_page = expected(DEPENDENCY, id='dependency-overview', route='concepts/dependency.html', source='docs/dependency.md')
    for name, binding, extra, root_present, dep_present in [
        ('multi-correct', 'pocketkit.RootIdentity', (), True, True),
        ('multi-cross-package', 'auxiliary.Helper', (), False, False),
        ('multi-unbound', '', (), False, False),
        ('multi-hidden', 'pocketkit.RootSecret', (), False, False),
        ('multi-cfg-filtered', 'pocketkit.RootOptional', ('--cfg', 'feature=disabled'), False, False),
        ('multi-cfg-enabled', 'pocketkit.RootOptional', ('--cfg', 'feature=extra'), True, False),
    ]:
        config = explicit + (dep_config if dep_present else '')
        site = generate(name, config=config, multi=True, bindings={'pocketkit': binding}, extra=extra)
        checks = [(ROOT, root_page if root_present else None, ()), (DEPENDENCY, dep_page if dep_present else None, ())]
        for module, page, aliases in checks:
            verify(name + ('-root' if module == ROOT else '-dependency'), site, module, page)
        replay(name, site, checks)

    v1 = generate('release-1', version='1.0.0')
    v2 = generate('release-2', version='2.0.0')
    verify('release-1', v1, expectation=expected())
    verify('release-2', v2, expectation=expected(version='2.0.0'), version='2.0.0')
    run('versions', 'compose', '--version', f'1.0.0={v1 / "html"}', '--version', f'2.0.0={v2 / "html"}',
        '--latest', '2.0.0', '--output', output / 'versions')
    for version in ['1.0.0', '2.0.0']:
        # Compose's documented version root and the fixture input determine identity.
        version_site = output / 'versions' / version
        package = version_site / package_route(ROOT)
        text = package.read_text()
        expectation = expected(version=version)
        guide = version_site / expectation['route']
        assert expectation['summary'] in text and expectation['bodyMarker'] in guide.read_text()
        assert all(marker not in guide.read_text() for marker in expectation['forbiddenBodyMarkers'])
        link = [h for cls, h in Page(text).links if cls == 'package-overview-link'][0]
        assert reachable(package, link) == guide.resolve()
        back = [h for _, h in Page(guide.read_text()).links if h.endswith('#declarations')][0]
        assert reachable(guide, back) == package.resolve()
        receipts.append({'name': 'version-' + version, 'package': str(package.relative_to(output)),
                         'guide': str(guide.relative_to(output)), 'authored': True, 'locale': 'en',
                         'apiMarker': 'ROOT_API_' + version, 'forbiddenApiMarker': 'DEPENDENCY_API_' + version, **expectation})

    (output / 'package-overview-receipt.json').write_text(json.dumps(receipts, ensure_ascii=False, indent=2) + '\n')
    print(f'PASS: {len(receipts)} independently specified package/page identity scenarios')


if __name__ == '__main__':
    main()
