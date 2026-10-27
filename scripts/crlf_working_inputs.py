"""Frozen Windows checkout bytes for one diagnostic; strict defaults stay intact."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path

CATALOG_SHA256='fb555d6af3465d14fdfac3d5be5a4d316663bb2f2643469052453245b2f9e48b'
PROFILE='windows-crlf-fixed-pins'
PINS={'yjson':'54b4965dee0f0b96710cbc678ec5ec9a126b055c',
      'markdown':'db4f9527944b589db8436669f1d255192388cee2',
      'yjson_macros':'fec0adce41f73d037d876cbac7a28aee8108bb5c'}
SOURCE_ATTRIBUTES_SHA256='9a637c582c1156757d3d401fd463b448ebc7c877f46cb875d5fef8f84c50892c'


def load_catalog(path):
    data=path.read_bytes()
    if hashlib.sha256(data).hexdigest()!=CATALOG_SHA256:raise ValueError('working catalog bytes differ from frozen identity')
    note=json.loads(data)
    if note['schema']!='cjdoc.windows-crlf-working-inputs/1' or note['profile']!=PROFILE:
        raise ValueError('working catalog schema/profile differs')
    if set(note['repositories'])!=set(PINS):raise ValueError('working catalog repository set differs')
    for name,repo in note['repositories'].items():
        if repo['commit']!=PINS[name]:raise ValueError('working catalog commit differs')
        paths=[row['path'] for row in repo['files']]
        if len(paths)!=len(set(paths)):raise ValueError('working catalog contains duplicate paths')
        repo['_name']=name;repo['_catalogSha256']=CATALOG_SHA256
    return note['repositories']


def closed_git_environment(environment, private):
    # Only this child environment changes. No installed SDK or caller config changes.
    result={key:value for key,value in environment.items() if not key.startswith('GIT_')}
    config=private/'crlf-private.gitconfig';attributes=private/'crlf-empty.attributes'
    template=private/'crlf-empty-template';template.mkdir(mode=0o700)
    for path in (config,attributes):
        with path.open('x'):pass
        path.chmod(0o600)
    overrides={'core.autocrlf':'true','core.eol':'crlf','core.attributesfile':str(attributes),
               'init.templateDir':str(template),'core.fsmonitor':'false','core.untrackedCache':'false'}
    result.update({'GIT_CONFIG_GLOBAL':str(config),'GIT_CONFIG_NOSYSTEM':'1',
                   'GIT_ATTR_NOSYSTEM':'1','GIT_TEMPLATE_DIR':str(template),
                   'GIT_CONFIG_COUNT':str(len(overrides)),'GIT_OPTIONAL_LOCKS':'0','GIT_TERMINAL_PROMPT':'0'})
    for index,(key,value) in enumerate(overrides.items()):
        result['GIT_CONFIG_KEY_'+str(index)]=key;result['GIT_CONFIG_VALUE_'+str(index)]=value
    return result,{'profile':PROFILE,'overrides':overrides,
                   'globalAndSystemAttributesDisabled':True,'emptyTemplateSelectedBeforeResolver':True,
                   'inheritedGitVariablesRemoved':sum(key.startswith('GIT_') for key in environment),
                   'scope':'Diagnostic CRLF working bytes; original failed CI working bytes were not captured'}


def guard_attributes(git,root,allow_source=False):
    environment=git.environment
    attributes=Path(environment['GIT_CONFIG_VALUE_2'])
    template=Path(environment['GIT_TEMPLATE_DIR'])
    config=Path(environment['GIT_CONFIG_GLOBAL'])
    if attributes.is_symlink() or attributes.read_bytes()!=b'':raise ValueError('controlled empty attributes changed')
    if template.is_symlink() or any(template.iterdir()):raise ValueError('controlled empty Git template changed')
    lines=[line.strip() for line in config.read_text().splitlines() if line.strip()]
    if config.is_symlink() or lines not in ([],['[core]','longpaths = true']):
        raise ValueError('controlled private global Git config changed')
    # Reject untracked/ignored attribute files too, before a diff can invoke filters.
    for path in root.rglob('.gitattributes'):
        if (not allow_source or path!=root/'.gitattributes' or path.is_symlink()
                or hashlib.sha256(path.read_bytes()).hexdigest()!=SOURCE_ATTRIBUTES_SHA256):
            raise ValueError('unexpected Git attribute file; conversion/diff not started')
    info=Path(git.read(root,'rev-parse','--git-path','info/attributes').stdout.strip())
    if not info.is_absolute():info=root/info
    if info.exists() or info.is_symlink():raise ValueError('Git info attributes must be absent')
    configured=git.read(root,'config','--local','--get-regexp',
                        r'^(include\.|includeif\.|filter\.|core\.(attributesfile|hookspath|fsmonitor)|diff\..*textconv)',check=False)
    if configured.returncode!=1 or configured.stdout:
        raise ValueError('unexpected local Git filter/helper configuration')


def verify_expected_working(snapshot, expected_blobs, expected):
    name=expected.get('_name')
    if (name not in PINS or expected.get('_catalogSha256')!=CATALOG_SHA256
            or snapshot['commit']!=PINS[name] or expected['commit']!=snapshot['commit']
            or expected['tree']!=snapshot['tree']):raise ValueError('working catalog does not bind this fixed repository')
    rows={row['path']:row for row in expected['files']}
    if len(rows)!=len(expected['files']) or set(rows)!=set(expected_blobs):
        raise ValueError('working catalog file set differs from Git tree')
    actual={row['path']:row for row in snapshot['files']}
    if len(actual)!=len(snapshot['files']) or set(actual)!=set(rows):
        raise ValueError('working inventory file set differs from catalog')
    for path,row in rows.items():
        mode,oid=expected_blobs[path]
        if row['canonicalGitBlobSha1']!=oid or row['gitMode']!=mode:
            raise ValueError('working catalog canonical Git entry differs: '+path)
        found=actual[path]
        if (found['sha256'],found['gitBlobSha1'],found['size'])!=(row['workingSha256'],row['workingGitBlobSha1'],row['workingSize']):
            raise ValueError('raw working bytes differ from frozen checkout catalog: '+path)
    snapshot['workingCheckoutVerified']=True
    snapshot['workingCheckoutVerification']={'profile':PROFILE,'catalogSha256':CATALOG_SHA256,
                                           'repository':name,'exactWorkingFiles':len(rows)}
    # This profile never presents transformed working bytes as canonical Git bytes.
    snapshot['rawGitBlobsVerified']=False
