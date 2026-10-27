#!/usr/bin/env python3
"""One native diagnostic attempt. Not a CI qualification or an automatic retry."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform as host
import re
import shlex
import shutil
import subprocess
import sys
import tomllib

from ir_events import EventWatch
from ir_hardlinks import CaptureMissed, IrLinks
from ir_publication import publish
from native_backend_trace import TraceRequest, trace_once
from native_capture_support import GitEvidence, digest, inventory, stack_observation, tools_for_sdk, system_mappings, output_bytes, controller_identity, canonical_checkout_environment

SOURCE = "4dc5f81e8ff03086f914e3721eb566e9e5007f75"
TREE = "9cb68ff6e92e96f5ded3bbe43cfdbe70867f8461"
PINS = {"yjson":"54b4965dee0f0b96710cbc678ec5ec9a126b055c",
        "markdown":"db4f9527944b589db8436669f1d255192388cee2",
        "yjson_macros":"fec0adce41f73d037d876cbac7a28aee8108bb5c"}
EXPECTED = {
    "windows-x64":("x86_64-w64-mingw32",
        "24630a9317c38facebcdcd0772dde08d5cdb7e4eefdf95aee0fa30944b0c87f6",
        "5bbad497b41afb1dfd793023609c2ae71b883bca81f30f1bb0d83719d47245d0"),
    "macos-arm64":("aarch64-apple-darwin",
        "d94d51eec0f20cce7f9bdbcebf3dabe808107141843072ce3ba3cd5b32471bcb",
        "fac66aa4b4d3092c3579e7e281377707e9effc0bf803c89319c8f5c55d41ecf1")}
PROVIDER = Path("tests/fixtures/projects/provider_plugin")
BOUNDARY = ["cjpm.toml","cjpm.lock",str(PROVIDER/"cjpm.toml"),str(PROVIDER/"cjpm.lock")]


class ChildFailed(ValueError):
    def __init__(self, phase, code):
        super().__init__(phase+" failed (exit "+str(code)+")")
        self.code = code


class Attempt:
    def __init__(self, source, output, selected, runner=subprocess.run, watcher=EventWatch):
        self.source=source.resolve(strict=True); self.output=output.resolve(strict=True)
        self.selected=selected; self.runner=runner; self.watcher=watcher
        self.environment=os.environ.copy(); self.git=GitEvidence(runner,self.environment)
        if os.name!="nt":
            import resource
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        self.evidence={"sourceCommit":SOURCE,"sourceTree":TREE,"platform":selected,
                       "status":"BUILD_NOT_STARTED","targetInvocations":0,
                       "argvObservation":"verbose-command-log; not OS execve",
                       "diagnosticOnly":True,"rawBitcodePublished":False,"calls":[],
                       "logEncoding":"UTF-8 with replacement for public text; original stdout/stderr bytes retained privately"}
        self.disassemblies=[];self.build_log="";self.exit_code=2
        self.private=self.output/"private";self.private.mkdir(mode=0o700)
        self.temporary=self.private/"tmp";self.temporary.mkdir(mode=0o700)
        self.retained=self.private/"retained";self.retained.mkdir(mode=0o700)
        self.environment.update({"TMPDIR":str(self.temporary),"TMP":str(self.temporary),
            "TEMP":str(self.temporary),"PYTHONDONTWRITEBYTECODE":"1","PYTHONUTF8":"1",
            "GITHUB_WORKSPACE":str(self.source),"RUNNER_TEMP":str(self.private),
            "CJDOC_PYTHON":sys.executable,
            "CJDOC_STS_INVOCATION_LOG":str(self.private/"sts-invocations.jsonl")})
        self.mappings=system_mappings(self.environment)+[(self.source,"<source>"),(self.output,"<diagnostic>"),
                       (Path.home(),"<home>"),(Path(__file__).resolve().parents[1],"<controller>"),
                       (Path(sys.executable).resolve().parent,"<python>")]

    def call(self, phase, argv, cwd=None, checked=True):
        process=self.runner(argv,cwd=cwd or self.source,env=self.environment,
                            capture_output=True,text=False,check=False)
        stdout=output_bytes(process.stdout);stderr=output_bytes(process.stderr)
        (self.private/(phase+".stdout")).write_bytes(stdout)
        (self.private/(phase+".stderr")).write_bytes(stderr)
        result=subprocess.CompletedProcess(argv,process.returncode,stdout.decode("utf-8","replace"),
                                           stderr.decode("utf-8","replace"))
        row={"phase":phase,"argv":list(map(str,argv)),"cwd":str(cwd or self.source),
             "exitCode":result.returncode,"stdout":result.stdout,"stderr":result.stderr,
             "stdoutSha256":hashlib.sha256(stdout).hexdigest(),
             "stderrSha256":hashlib.sha256(stderr).hexdigest()}
        self.evidence["calls"].append(row)
        (self.private/(phase+".log")).write_text(result.stdout+result.stderr,encoding="utf-8")
        if checked and result.returncode:raise ChildFailed(phase,result.returncode)
        return result

    def authenticate(self):
        version=self.call("stdx",[sys.executable,str(self.source/"scripts/with_stdx.py"),
                                  "--variant","static","--print-env","--"])
        values=dict(line.split("=",1) for line in version.stdout.splitlines() if "=" in line)
        target,stdx,fingerprint=EXPECTED[self.selected]
        expected={"CJDOC_TOOLCHAIN_VERSION":"1.2.0 (cjnative)","CJDOC_TOOLCHAIN_TARGET":target,
                  "CJDOC_STDX_VARIANT":"static","CJDOC_STDX_DIGEST":stdx,
                  "CJDOC_TOOLCHAIN_FINGERPRINT":fingerprint,"CJDOC_STDX_DEPENDENCY_DIGEST":""}
        if any(values.get(k)!=v for k,v in expected.items()):raise ValueError("SDK/stdx fingerprint differs")
        self.environment.update(values);self.evidence["sdkEnvironment"]=values
        self.sdk,self.tools=tools_for_sdk(self.environment)
        if self.selected=="macos-arm64":
            # The previous receipt identified this exact spelling by its SHA.
            # Hashing the file does not prove which delegated tool it executes.
            archiver=Path("/usr/bin/ar")
            self.tools["platform-ar"]=archiver.resolve(strict=True)
            self.mappings.extend([(archiver,"<platform-archiver>"),
                                  (self.tools["platform-ar"],"<platform-archiver>")])
        self.mappings.append((self.sdk,"<sdk>"))
        for name in ("RUNNER_TEMP","GITHUB_WORKSPACE"):
            original=os.environ.get(name)
            if original:self.mappings.append((Path(original),"<temporary>" if name=="RUNNER_TEMP" else "<workspace>"))
        self.mappings.append((Path(values["CJDOC_STDX_PATH"]),"<stdx>"))
        platform_sdk=self.environment.get("SDKROOT")
        if platform_sdk:
            path=Path(platform_sdk)
            if not path.is_absolute() or not path.is_dir() or path.parent==path:
                raise ValueError("selected platform SDK path is not an existing absolute directory")
            self.mappings.append((path,"<platform-sdk>"))
            self.evidence["selectedPlatformSdkPath"]=str(path)
        self.evidence["toolsBefore"]=self.tool_hashes()
        self.evidence["stack"]=stack_observation(self.tools)
        if os.name!="nt":
            import resource
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            self.evidence["coreDump"]="disabled: RLIMIT_CORE soft/hard zero inherited by children"
        else:self.evidence["coreDump"]="POSIX core dumps not applicable; no WER configuration changed"

    def tool_hashes(self):
        return {name:{"path":str(path),"sha256":digest(path),"size":path.stat().st_size}
                for name,path in self.tools.items()}

    def captured_call(self, phase, argv, cwd=None):
        temporary=self.temporary/phase;temporary.mkdir(mode=0o700)
        retained=self.retained/phase;retained.mkdir(mode=0o700)
        links=IrLinks(temporary,retained);watch=self.watcher(links,self.selected)
        old={key:self.environment[key] for key in ("TMPDIR","TMP","TEMP")}
        self.environment.update(dict.fromkeys(old,str(temporary)))
        result=None
        try:
            watch.start()
            try:
                result=self.call(phase,argv,cwd,checked=False)
                if phase=="target":
                    self.evidence["targetInvocations"]=1
                    self.evidence["processExitCode"]=result.returncode
                    self.build_log=result.stdout+result.stderr
                    self.exit_code=result.returncode
                elif result.returncode:
                    self.exit_code=result.returncode
                    self.evidence["firstChildFailureExitCode"]=result.returncode
            finally:watch.stop()
            rows=links.finish()
            self.evidence[phase+"Captured"]=rows
            return result,rows,temporary,retained
        finally:
            self.environment.update(old)
            self.evidence[phase+"CaptureIssues"]=links.issues

    def disassemble(self, phase, retained, row):
        source=retained/row["retained"];out=self.private/(phase+".ll")
        self.call(phase+"-dis",[str(self.tools["llvm-dis"]),str(source),"-o",str(out)])
        if digest(source)!=row["sha256"]:raise ValueError("raw IR changed during read-only disassembly")
        return out.read_text(encoding="utf-8",errors="strict")

    def preflight(self):
        model=self.private/"preflight.cj"
        model.write_text("package capture_preflight\npublic func token(): Int64 { 7 }\n")
        archive=self.private/("preflight.lib" if os.name=="nt" else "libpreflight.a")
        argv=[str(self.tools["cjc"]),str(model),"--output-type","staticlib","-O2",
              "--fno-chir-function-inlining","-V","-o",str(archive)]
        shell=shutil.which("bash",path=self.environment["PATH"])
        if shell is None:raise ValueError("native preflight requires the same Bash entry as the target")
        self.mappings.extend([(Path(shell),"<bash>"),(Path(shell).resolve(),"<bash>")])
        argv=[shell,"-c",'set -euo pipefail; . "$GITHUB_WORKSPACE/scripts/with_sts_cjpm.sh"; exec "$@"',
              "native-cjc-preflight",*argv]
        result,rows,temporary,retained=self.captured_call("preflight",argv,self.private)
        if result.returncode:raise ChildFailed("preflight",result.returncode)
        if len(rows)!=1 or rows[0]["originalPresent"] or rows[0]["linkCountAfterCompiler"]!=1:
            raise CaptureMissed("native preflight did not retain exactly one fully cleaned-up IR")
        if list(temporary.iterdir()):raise CaptureMissed("native CJC left its original temporary tree")
        if not archive.is_file():raise CaptureMissed("preflight compiler output missing")
        log=result.stdout+result.stderr
        llc=[line for line in log.splitlines() if re.search(r"[/\\]llc(?:\.exe)?['\"\s]",line)]
        if len(llc)!=1 or "--filetype=obj" not in llc[0] or "-O2" not in llc[0] or "--filetype=asm" in log:
            raise CaptureMissed("preflight must observe one object llc and no added assembly pass")
        self.disassemble("preflight",retained,rows[0])
        self.evidence["preflightCleanup"]={"controlledTempEmpty":True,"originalRemoved":True,
            "hardLinkCount":1,"oneObjectLlc":True,"sameSdkDisassembly":True}

    def boundary(self):
        return inventory(self.source,BOUNDARY)

    def lock_pins(self):
        for relative in ("cjpm.lock",str(PROVIDER/"cjpm.lock")):
            locks=tomllib.loads((self.source/relative).read_text())["requires"]
            actual={name:item["commitId"] for name,item in locks.items() if "git" in item}
            if actual!=PINS:raise ValueError("root/provider lock differs from the three frozen Git pins")

    def resolve_sources(self):
        if self.selected=="windows-x64":
            environment,note=canonical_checkout_environment(self.environment)
            self.environment.update(environment)
            self.evidence["dependencyCheckoutPolicy"]=note
            observed={}
            for key,expected in note["overrides"].items():
                value=self.git.read(self.source,"config","--get",key).stdout.strip()
                observed[key]=value
                if value!=expected:raise ValueError("effective diagnostic Git checkout config differs: "+key)
            note["effectiveValues"]=observed
        # Prove skip-script on this native tool before using it to resolve sources.
        proof=self.private/"resolver-proof";proof.mkdir(mode=0o700);(proof/"src").mkdir()
        (proof/"src/probe.cj").write_text("package capture_resolver_probe\n")
        (proof/"cjpm.toml").write_text('[package]\nname="capture_resolver_probe"\nversion="0.0.0"\n'
            'cjc-version="1.3.0"\noutput-type="static"\nsrc-dir="src"\n')
        (proof/"build.cj").write_text("INVALID_BUILD_SCRIPT_MUST_NOT_PARSE_OR_EXECUTE\n")
        names=["cjpm.toml","build.cj","src/probe.cj"]
        before=inventory(proof,names)
        self.call("resolver-proof",[str(self.tools["cjpm"]),"update","--skip-script"],proof)
        if inventory(proof,names)!=before or (proof/"target").exists():
            raise ValueError("skip-script proof changed inputs or built a target")
        self.evidence["resolverProof"]={"unparsableBuildScriptSkipped":True,"inputFiles":before}
        before=self.boundary();self.evidence["boundaryBeforeResolve"]=before
        entry=self.source if self.selected=="windows-x64" else self.source/PROVIDER
        self.call("resolve",[str(self.tools["cjpm"]),"update","--skip-script"],entry)
        after=self.boundary();self.evidence["boundaryAfterResolve"]=after
        if before!=after:raise ValueError("resolve changed a root/provider manifest or lock; target stopped")
        self.lock_pins()

    def dependencies(self, allow_missing=False):
        cache=Path.home()/".cjpm/git"
        result={}
        for name,commit in PINS.items():
            root=cache/name/commit
            if not root.is_dir():
                if allow_missing:
                    result[name]={"present":False,"expectedCommit":commit};continue
                raise ValueError("resolved Git dependency cache missing: "+name)
            note=self.git.snapshot(root,commit)
            result[name]=note
        return result

    def target(self):
        for path in (self.source/"target",self.source/PROVIDER/"target"):
            if path.exists():raise ValueError("diagnostic source must have fresh root/provider targets")
        shell=shutil.which("bash",path=self.environment["PATH"])
        if shell is None:raise ValueError("Git Bash/POSIX bash unavailable")
        self.mappings.extend([(Path(shell),"<bash>"),(Path(shell).resolve(),"<bash>")])
        script=self.private/"target.sh"
        command=(["cjpm","build","--verbose","--jobs","1"] if self.selected=="windows-x64"
                 else ["cjpm","run","--build-args","--jobs 1 --verbose"])
        entry=self.source if self.selected=="windows-x64" else self.source/PROVIDER
        script.write_text('set -euo pipefail\n. "$GITHUB_WORKSPACE/scripts/with_sts_cjpm.sh"\n'
                          'cd '+shlex.quote(str(entry))+'\n'+shlex.join(command)+'\n')
        (self.output/"target-attempt.marker").open("x").close()
        self.evidence["targetCommand"]=command
        result,rows,_,retained=self.captured_call("target",[shell,str(script)],entry)
        yjson=[row for row in rows if row["name"]=="yjson.opt.bc"]
        if len(yjson)!=1:raise CaptureMissed("expected exactly one yjson.opt.bc; target not retried")
        text=self.disassemble("yjson",retained,yjson[0])
        self.disassemblies=[(yjson[0]["sha256"],text)]
        log=self.build_log
        commands=[line for line in log.splitlines() if re.search(r"(?:^|[ /\\'\"])cjc(?:\.exe)?['\"\s]",line)]
        self.evidence["verboseCjcCommands"]=commands
        yjson_commands=[line for line in commands if PINS["yjson"] in line and
                        ("Compiling package `yjson`:" in line)]
        if len(yjson_commands)!=1:raise CaptureMissed("unique verbose yjson CJC argv unavailable")
        expected=(Path.home()/".cjpm/git/yjson"/PINS["yjson"]/"src").as_posix()
        observed=yjson_commands[0].replace("\\","/")
        if not re.search(re.escape(expected)+r"(?=[\"'\s]|$)",observed,re.IGNORECASE):
            raise ValueError("verbose yjson source path differs from inventoried Git working tree")
        levels=re.findall(r"(?<![A-Za-z0-9_])-O[0-3s](?![A-Za-z0-9_])", yjson_commands[0])
        if not levels or levels[-1]!="-O2" or "--fno-chir-function-inlining" not in yjson_commands[0]:
            raise ValueError("verbose yjson command lacks unchanged product policy")
        self.evidence["status"]="CAPTURED_BUILD_FAILED" if result.returncode else "CAPTURED_BUILD_SUCCEEDED"
        self.evidence["failurePhase"]="UNKNOWN until logs are inspected; provider command also executes its fixture"
        self.evidence["qualification"]="diagnostic only; controlled temporary paths and event observer change timing"
        self.backend_observation(result,retained,yjson[0])

    def backend_observation(self, result, retained, row):
        if result.returncode==0 or not any("yjson.opt.bc" in line and "llc" in line and
                "command failed with exit code" in line for line in self.build_log.splitlines()):
            self.evidence["backendTrace"]={"backendInvocations":0,
                "reason":"Original command did not report a yjson llc failure"}
            return
        directory=self.private/"backend-trace"
        try:
            request=TraceRequest(self.selected,self.tools["llc"],
                self.evidence["toolsBefore"]["llc"]["sha256"],retained/row["retained"],row["sha256"],
                self.temporary/"target"/row["sourceRelative"],self.build_log,directory,self.environment)
            note=trace_once(request)
            self.evidence["backendTrace"]=note
            if not note["inputsUnchanged"]:
                self.evidence["integrityError"]="retained IR or llc changed during backend observation"
                self.evidence["status"]="INPUT_CHANGED"
        except Exception as error:
            # The original product exit is authoritative even if this optional
            # diagnostic cannot establish its own observation boundary.
            self.evidence["backendTrace"]={"status":"UNAVAILABLE",
                "backendAttempts":int(directory.exists()),
                "backendInvocations":"UNKNOWN" if directory.exists() else 0,
                "reason":type(error).__name__+": "+str(error)}

    def validate_derived(self, text):
        source=self.private/"derived.ll";source.write_text(text,encoding="utf-8")
        result=self.call("derived-as",[str(self.tools["llvm-as"]),str(source),
                                      "-o",str(self.private/"derived.bc")],checked=False)
        note=self.evidence["calls"][-1]
        after=self.tool_hashes();self.evidence["toolsAfterDerivedValidation"]=after
        if after!=self.evidence["toolsBefore"]:raise ValueError("SDK tool bytes changed during derived validation")
        return {"accepted":result.returncode==0,"argv":note["argv"],"exitCode":result.returncode,
                "toolSha256":after["llvm-as"]["sha256"],
                "logSha256":digest(self.private/"derived-as.log"),
                "stdoutSha256":note["stdoutSha256"],"stderrSha256":note["stderrSha256"]}

    def identity(self):
        names=("ir_events","ir_hardlinks","ir_publication","native_capture_support","native_backend_trace")
        paths=[Path(__file__),*(Path(sys.modules[name].__file__) for name in names)]
        result=controller_identity(paths,self.environment)
        root=Path(__file__).resolve().parents[1]
        names=["scripts/"+path.name for path in paths]
        names += ["scripts/test_native_codegen_capture.py","scripts/test_native_backend_trace.py",
                  ".github/workflows/ci.yml"]
        result["candidateFiles"]=inventory(root,names)
        return result

    def execute(self):
        initial=None;dependencies=None
        try:
            self.evidence["controllerBefore"]=self.identity()
            if (self.output/"attempt.marker").exists():raise ValueError("attempt already exists")
            (self.output/"attempt.marker").open("x").close()
            if self.selected=="windows-x64":
                self.git.read(self.source,"config","--global","core.longpaths","true")
            initial=self.git.snapshot(self.source,SOURCE,TREE)
            self.evidence["sourceBefore"]=initial
            self.authenticate();self.lock_pins();self.preflight()
            prior=self.dependencies(allow_missing=True)
            self.evidence["dependenciesBeforeResolve"]=prior
            self.resolve_sources()
            dependencies=self.dependencies();self.evidence["dependenciesBefore"]=dependencies
            for name,row in prior.items():
                if row.get("present") is not False and dependencies[name]!=row:
                    raise ValueError("resolve changed existing dependency working input: "+name)
            self.target()
        except Exception as error:
            if isinstance(error,ChildFailed):
                self.exit_code=error.code;self.evidence["firstChildFailureExitCode"]=error.code
            elif not (self.evidence.get("processExitCode") or
                        self.evidence.get("firstChildFailureExitCode")):self.exit_code=2
            self.evidence["status"]="CAPTURE_MISSED" if isinstance(error,CaptureMissed) else "PRECONDITION_OR_CAPTURE_FAILED"
            self.evidence["error"]=type(error).__name__+": "+str(error)
            self.evidence["lastRejectedWorkingSnapshot"]=getattr(self.git,"last_snapshot",None)
        finally:
            try:
                identity=self.identity();self.evidence["controllerAfter"]=identity
                if identity!=self.evidence.get("controllerBefore"):
                    raise ValueError("diagnostic controller or interpreter identity changed")
                if initial is not None:
                    after=self.git.snapshot(self.source,SOURCE,TREE);self.evidence["sourceAfter"]=after
                    if after!=initial:raise ValueError("source working bytes or modes changed")
                if dependencies is not None:
                    after=self.dependencies();self.evidence["dependenciesAfter"]=after
                    if after!=dependencies:raise ValueError("dependency working bytes or modes changed")
                if hasattr(self,"tools"):
                    after=self.tool_hashes();self.evidence["toolsAfter"]=after
                    if after!=self.evidence["toolsBefore"]:raise ValueError("SDK tool bytes changed")
            except Exception as error:
                self.evidence["integrityError"]=str(error);self.evidence["status"]="INPUT_CHANGED"
                self.evidence["lastRejectedWorkingSnapshot"]=getattr(self.git,"last_snapshot",None)
                if not (self.evidence.get("processExitCode") or
                        self.evidence.get("firstChildFailureExitCode")):self.exit_code=2
            self.evidence["gitCalls"]=self.git.calls
            self.evidence["gitNormalizedObservations"]=self.git.normalized_observations
            for index,(stdout,stderr) in enumerate(self.git.raw_calls):
                (self.private/("git-"+str(index)+".stdout")).write_bytes(stdout)
                (self.private/("git-"+str(index)+".stderr")).write_bytes(stderr)
            self.evidence["controllerExitCode"]=self.exit_code
            try:
                public=publish(self.output/"public",self.evidence,self.build_log,self.disassemblies,
                               self.mappings,self.environment,self.validate_derived if hasattr(self,"tools") else None)
                self.evidence["derivedIr"]=public.get("derivedIr",[])
            except Exception as error:
                self.evidence["publicationError"]=str(error)
                if not (self.evidence.get("processExitCode") or
                        self.evidence.get("firstChildFailureExitCode")):self.exit_code=2
            self.evidence["controllerExitCode"]=self.exit_code
            (self.private/"receipt.raw.json").write_text(json.dumps(self.evidence,indent=2)+"\n")
        return self.exit_code


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True,help="must not exist")
    parser.add_argument("--platform",choices=tuple(EXPECTED),required=True)
    args=parser.parse_args()
    native=(os.name=="nt" and host.machine().lower() in {"amd64","x86_64"}) if args.platform=="windows-x64" else (
        sys.platform=="darwin" and host.machine().lower()=="arm64")
    if not native:parser.error("requested native OS/architecture is not available; no build started")
    if args.output.exists():parser.error("output already exists; an attempt is never retried")
    args.output.mkdir(mode=0o700)
    return Attempt(args.source,args.output,args.platform).execute()


if __name__=="__main__":raise SystemExit(main())
