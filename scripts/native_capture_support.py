"""Source/tool identities and the previously reviewed diagnostic privacy rules."""
from __future__ import annotations
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import platform
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")

PRIVATE_CONTENT = re.compile(
    r"(?i)(?:[a-z]:[\\/]|(?<![a-z0-9_./:>])/[a-z0-9_.-]+(?:/[a-z0-9_.-]+)*|"
    r"gh[pousr]_[a-z0-9]{20,}|github_pat_[a-z0-9_]{20,}|"
    r"sk-[a-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|"
    r"\b(?:10|127)\.\d{1,3}\.\d{1,3}\.\d{1,3}\b|"
    r"\b192\.168\.\d{1,3}\.\d{1,3}\b|"
    r"\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b)"
)

LOCAL_NETWORKS = tuple(map(ipaddress.ip_network, (
    "0.0.0.0/32", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
    "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
    "::/128", "::1/128", "fc00::/7", "fe80::/10")))
IP_LITERAL = re.compile(r"(?<![A-Za-z0-9_.:])(?:(?:[0-9a-fA-F]*:){2,}[0-9a-fA-F:.]*"
                        r"(?:%[A-Za-z0-9_.-]+)?|(?:[0-9]{1,3}\.){3}[0-9]{1,3})(?![A-Za-z0-9_.:])")


def local_address_present(text):
    for match in IP_LITERAL.finditer(text):
        try:address=ipaddress.ip_address(match.group().split("%",1)[0])
        except ValueError:continue
        if isinstance(address,ipaddress.IPv6Address) and address.ipv4_mapped:
            address=address.ipv4_mapped
        if any(address.version==network.version and address in network for network in LOCAL_NETWORKS):
            return True
    return False


def system_mappings(environment):
    windows=environment.get("SystemRoot",environment.get("WINDIR",r"C:\Windows"))
    return [(Path(windows),"<system-files>"),(Path("/usr/lib"),"<system-libraries>"),
            (Path("/System"),"<system-files>")]


def private_reasons(text: str, environment: dict[str, str]) -> list[str]:
    reasons = ["absolute path or credential pattern"] if PRIVATE_CONTENT.search(text) else []
    if local_address_present(text):reasons.append("local network address")
    for key in ("USERNAME", "COMPUTERNAME", "HOSTNAME", "USERDNSDOMAIN"):
        value = environment.get(key, "")
        if len(value) >= 4 and value.casefold() in text.casefold():
            reasons.append("user or host identifier")
    return sorted(set(reasons))

def quoted_context(text, position):
    quote=None;escaped=False
    for character in text[text.rfind("\n",0,position)+1:position]:
        if escaped:escaped=False;continue
        if character=="\\":escaped=True;continue
        if quote is None and character in "\"'":quote=character
        elif character==quote:quote=None
    return quote


def replace_root(text, variant, label, *, llvm=False, windows=False):
    count=0
    def replace(match):
        nonlocal count
        tail=text[match.end():]
        boundary=not tail or tail.startswith("/") or bool(re.match(r"\\2[fF]",tail))
        if windows and re.match(r"\\5[cC]",tail):boundary=True
        if windows and not llvm and tail.startswith("\\") and not re.match(r"\\[0-9a-fA-F]{2}",tail):
            boundary=True
        quote=quoted_context(text,match.start())
        if quote and tail.startswith(quote):
            following=tail[1:2]
            boundary=not following or following.isspace() or following in ",;:)]}"
        if not llvm and quote is None and tail:
            if tail[0].isspace():boundary=True
            if tail.startswith(":") and (len(tail)==1 or tail[1].isspace()):boundary=True
        if boundary:count+=1;return label
        return match.group()
    result=re.sub(re.escape(variant),replace,text,flags=re.IGNORECASE)
    return result,count


def normalize(text: str, mappings: list[tuple[Path, str]]) -> str:
    result = ANSI.sub("", text)
    for path, label in sorted(mappings, key=lambda pair: len(str(pair[0])), reverse=True):
        for variant in sorted({str(path), path.as_posix(), str(path).replace("\\", "\\\\")},
                              key=len, reverse=True):
            windows=bool(re.match(r"^[A-Za-z]:[\\/]|^\\\\",str(path)))
            result,_ = replace_root(result,variant,label,windows=windows)
    return result

def sanitize(value, mappings):
    if isinstance(value, dict):
        return {k: sanitize(v, mappings) for k, v in value.items()}
    if isinstance(value, list):
        return [sanitize(v, mappings) for v in value]
    return normalize(value, mappings) if isinstance(value, str) else value


def output_bytes(value):
    return value if isinstance(value,bytes) else value.encode("utf-8")


def digest(path):
    h=hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda:stream.read(65536),b""):
            h.update(block)
    return h.hexdigest()


def path_descriptor_mismatches(path_info, fd_info, *, windows):
    fields=("st_dev","st_ino","st_size","st_mtime_ns")
    fields+=("st_birthtime_ns",) if windows else ("st_ctime_ns",)
    differences=[name for name in fields if getattr(path_info,name)!=getattr(fd_info,name)]
    # CPython 3.12 Windows path stat uses birthtime for ctime and derives
    # execute bits from the suffix. fstat has ChangeTime and no suffix.
    mask=~0o111 if windows else -1
    if path_info.st_mode & mask != fd_info.st_mode & mask:differences.append("st_mode")
    return differences


def canonical_checkout_environment(environment):
    """Append diagnostic-only Git checkout options without replacing inherited config."""
    result=dict(environment)
    spelling=result.get("GIT_CONFIG_COUNT") or "0"
    if not re.fullmatch(r"[0-9]+",spelling):raise ValueError("invalid inherited GIT_CONFIG_COUNT")
    count=int(spelling)
    for index in range(count):
        if any(prefix+str(index) not in result for prefix in ("GIT_CONFIG_KEY_","GIT_CONFIG_VALUE_")):
            raise ValueError("incomplete inherited Git environment config")
    overrides={"core.autocrlf":"false","core.eol":"lf"}
    for index,(key,value) in enumerate(overrides.items(),count):
        result["GIT_CONFIG_KEY_"+str(index)]=key
        result["GIT_CONFIG_VALUE_"+str(index)]=value
    result["GIT_CONFIG_COUNT"]=str(count+len(overrides))
    return result,{"inheritedConfigCount":count,"overrides":overrides,
        "scope":"Windows diagnostic canonical Git bytes; differs from original CRLF working input"}


def inventory(root, paths):
    result=[]
    for name in sorted(paths):
        path=root/name
        if path.is_symlink() or (hasattr(path,"is_junction") and path.is_junction()):
            raise ValueError("source inventory includes a symlink or junction")
        if not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError("source inventory includes an external/nonregular file")
        before=path.lstat()
        fields=("st_dev","st_ino","st_size","st_mtime_ns","st_ctime_ns","st_mode")
        if os.name=="nt":fields+=("st_birthtime_ns",)
        content=hashlib.sha256()
        with path.open("rb") as stream:
            opened=os.fstat(stream.fileno())
            differences=path_descriptor_mismatches(before,opened,windows=os.name=="nt")
            if differences:
                raise ValueError("opened source input differs from inventoried path: "+name+
                                 " (fields: "+", ".join(differences)+")")
            blob=hashlib.sha1(b"blob "+str(opened.st_size).encode()+b"\0")
            size=0
            for block in iter(lambda:stream.read(65536),b""):
                content.update(block);blob.update(block);size+=len(block)
            finished=os.fstat(stream.fileno())
            if size!=opened.st_size or any(getattr(opened,key)!=getattr(finished,key) for key in fields):
                raise ValueError("opened source input changed during inventory: "+name)
        after=path.lstat()
        if any(getattr(before,key)!=getattr(after,key) for key in fields):
            raise ValueError("source input changed during inventory: "+name)
        result.append({"path":name,"sha256":content.hexdigest(),"gitBlobSha1":blob.hexdigest(),
                       "size":after.st_size,"mode":after.st_mode & 0o777})
    return result


class GitEvidence:
    def __init__(self, runner=subprocess.run, environment=None):
        self.calls=[];self.raw_calls=[];self.normalized_observations=[];self.runner=runner
        self.environment=os.environ if environment is None else environment

    def read(self,root,*args,check=True):
        command=["git","-C",str(root),*args]
        environment=dict(self.environment)
        environment["GIT_OPTIONAL_LOCKS"]="0"
        process=self.runner(command,capture_output=True,text=False,check=False,env=environment)
        stdout=output_bytes(process.stdout);stderr=output_bytes(process.stderr)
        self.raw_calls.append((stdout,stderr))
        r=subprocess.CompletedProcess(command,process.returncode,stdout.decode("utf-8","replace"),
                                      stderr.decode("utf-8","replace"))
        self.calls.append({"argv":command,"exitCode":r.returncode,
                           "stdout":r.stdout,"stderr":r.stderr,
                           "stdoutSha256":hashlib.sha256(stdout).hexdigest(),
                           "stderrSha256":hashlib.sha256(stderr).hexdigest()})
        if check and r.returncode:
            raise ValueError("Git boundary failed: "+" ".join(args)+" (exit "+str(r.returncode)+")")
        return r

    def snapshot(self,root,commit,tree=None):
        head=self.read(root,"rev-parse","HEAD").stdout.strip()
        actual_tree=self.read(root,"rev-parse","HEAD^{tree}").stdout.strip()
        if head!=commit or (tree and actual_tree!=tree):
            raise ValueError("source commit/tree does not match frozen input")
        listing=self.read(root,"ls-tree","-rz","--full-tree","HEAD").stdout
        blobs=[];gitlinks=[];expected_index=[];expected_blobs={}
        for record in listing.rstrip("\0").split("\0"):
            if not record:continue
            metadata,name=record.split("\t",1);mode,kind,oid=metadata.split(" ")
            if not re.fullmatch(r"[0-9a-f]{40}",oid):raise ValueError("expected SHA-1 Git object identity")
            expected_index.append(mode+" "+oid+" 0\t"+name)
            if kind=="commit" and mode=="160000":
                gitlinks.append({"path":name,"commit":oid,"workingExists":(root/name).exists(),
                                 "followed":False})
            elif kind=="blob" and mode in {"100644","100755"}:
                blobs.append(name);expected_blobs[name]=(mode,oid)
            else:raise ValueError("source Git tree includes unsupported nonregular entry")
        self.last_snapshot={"commit":head,"tree":actual_tree,"files":inventory(root,blobs),
                            "gitTreeEntries":listing,"gitlinks":gitlinks,
                            "rawGitBlobsVerified":False,"indexMatchesHead":False,
                            "workingExecuteBitCheck":"POSIX executable bit" if os.name!="nt" else
                                "Windows mode observed; tracked execute mode verified in index"}
        for row in self.last_snapshot["files"]:
            mode,oid=expected_blobs[row["path"]]
            if row["gitBlobSha1"]!=oid:
                raise ValueError("raw working bytes differ from Git blob: "+row["path"])
            if os.name!="nt" and bool(row["mode"] & 0o100)!=(mode=="100755"):
                raise ValueError("working execute mode differs from Git tree: "+row["path"])
        self.last_snapshot["rawGitBlobsVerified"]=True
        index=self.read(root,"ls-files","--stage","-z").stdout
        actual_index=index.rstrip("\0").split("\0") if index else []
        if sorted(actual_index)!=sorted(expected_index):
            raise ValueError("Git index differs from frozen HEAD entries or modes")
        self.last_snapshot["indexMatchesHead"]=True
        diff=self.read(root,"diff","--exit-code","HEAD","--",check=False)
        if diff.returncode not in (0,1):raise ValueError("Git normalized diff failed")
        status=self.read(root,"status","--porcelain=v1","-z","--untracked-files=all").stdout
        self.normalized_observations.append({"root":str(root),"commit":head,
            "diffExitCode":diff.returncode,"porcelainStatus":status,
            "meaning":"Git clean-filter observation; source identity uses exact raw blobs and index"})
        for record in status.rstrip("\0").split("\0") if status else []:
            # A raw-verified file may be shown as modified because the committed
            # CRLF blob is normalized by Git's text clean filter. Preserve that
            # observation without calling it clean or changing the source.
            if not record.startswith(" M ") or record[3:] not in expected_blobs:
                raise ValueError("source has an untracked, staged, or unsupported status entry")
        return self.last_snapshot



def controller_identity(module_paths, environment):
    interpreter=Path(sys.executable).resolve(strict=True)
    return {"workflow":{key:environment.get(key) for key in (
                "GITHUB_SHA","GITHUB_RUN_ID","GITHUB_RUN_ATTEMPT","GITHUB_JOB","GITHUB_REF",
                "RUNNER_OS","RUNNER_ARCH","ImageOS","ImageVersion")},
            "host":{"platform":platform.platform(),"machine":platform.machine(),"osName":os.name},
            "python":{"executable":str(interpreter),"sha256":digest(interpreter),"version":sys.version},
            "modules":[{"path":str(path.resolve(strict=True)),"sha256":digest(path.resolve(strict=True))}
                       for path in module_paths]}


def stack_observation(tools):
    if os.name!="nt":
        import resource
        soft,hard=resource.getrlimit(resource.RLIMIT_STACK)
        return {"kind":"actual process RLIMIT_STACK","softBytes":soft,"hardBytes":hard,
                "changedByController":False}
    headers={}
    for name,path in tools.items():
        if name not in {"cjc","cjc-frontend","llc"}:continue
        b=path.read_bytes();offset=struct.unpack_from("<I",b,0x3c)[0]
        if b[offset:offset+4]!=b"PE\0\0":raise ValueError("SDK executable is not PE")
        optional=offset+24;magic=struct.unpack_from("<H",b,optional)[0]
        fmt="<QQ" if magic==0x20b else "<II" if magic==0x10b else None
        if fmt is None:raise ValueError("unknown SDK PE optional header")
        reserve,commit=struct.unpack_from(fmt,b,optional+72)
        headers[name]={"sizeOfStackReserve":reserve,"sizeOfStackCommit":commit}
    return {"kind":"Windows SDK PE header observation","executables":headers,
            "actualThreadRuntimeStack":"UNKNOWN; PE defaults are not a live stack measurement",
            "changedByController":False}


def tools_for_sdk(environment):
    sdk=Path(environment["CANGJIE_HOME"]).resolve(strict=True)
    suffix=".exe" if os.name=="nt" else ""
    tools={}
    for name in ("cjc","cjc-frontend"):
        path=(sdk/"bin"/(name+suffix)).resolve(strict=True)
        if not path.is_relative_to(sdk) or not path.is_file():raise ValueError("SDK tool outside selected SDK")
        tools[name]=path
    found=shutil.which("cjpm"+suffix,path=environment["PATH"])
    if found is None:raise ValueError("cjpm unavailable")
    path=Path(found).resolve(strict=True)
    if not path.is_relative_to(sdk):raise ValueError("cjpm outside selected SDK")
    tools["cjpm"]=path
    llvm=sdk/"third_party/llvm/bin"
    for name in ("opt","llc","llvm-dis","llvm-as"):
        path=(llvm/(name+suffix)).resolve(strict=True)
        if not path.is_relative_to(sdk) or not path.is_file():raise ValueError("same-SDK LLVM tool unavailable")
        tools[name]=path
    for directory in [llvm,llvm.parent/"lib"]:
        for pattern in ("*.dll","*.dylib"):
            for path in sorted(directory.glob(pattern)):
                real=path.resolve(strict=True)
                if not real.is_relative_to(sdk):raise ValueError("LLVM library outside selected SDK")
                tools["llvm-library/"+path.name]=real
    return sdk,tools
