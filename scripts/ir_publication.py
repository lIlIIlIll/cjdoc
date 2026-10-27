"""Fail-closed, derived-text-only publication. Raw bitcode stays private."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import re
from native_capture_support import normalize, private_reasons, sanitize, replace_root, PRIVATE_CONTENT


def sha(data):
    return hashlib.sha256(data).hexdigest()


def structured_private_reasons(value,environment):
    """Scan JSON string semantics, including keys, rather than JSON escapes."""
    reasons=[]
    def inspect(item):
        if isinstance(item,str):reasons.extend(private_reasons(item,environment))
        elif isinstance(item,dict):
            for key,child in item.items():inspect(str(key));inspect(child)
        elif isinstance(item,(list,tuple)):
            for child in item:inspect(child)
        elif item is not None and not isinstance(item,(int,float,bool)):
            raise TypeError('unsupported structured publication value')
    inspect(value)
    return sorted(set(reasons))


CONTROLLER_STATUSES={"BUILD_NOT_STARTED","CAPTURED_BUILD_FAILED","CAPTURED_BUILD_SUCCEEDED",
                     "CAPTURE_MISSED","PRECONDITION_OR_CAPTURE_FAILED","INPUT_CHANGED"}
INTEGRITY_PHASES={"TEMP","CONTROLLER","SOURCE","DEPENDENCIES","TOOLS","COMPLETE"}


def failure_summary(evidence):
    status=evidence.get('status')
    note={'controllerStatus':status if isinstance(status,str) and status in CONTROLLER_STATUSES else 'UNKNOWN'}
    code=evidence.get('controllerExitCode')
    if type(code) is int:note['controllerExitCode']=code
    phase=evidence.get('integrityPhase')
    if isinstance(phase,str) and phase in INTEGRITY_PHASES:note['integrityPhase']=phase
    for key in ('error','integrityError','publicationError'):
        text=evidence.get(key)
        if isinstance(text,str):note[key+'TextSha256']=sha(text.encode('utf-8','replace'))
    return note


def refusal_locations(value, environment, location="receipt"):
    """Report bounded locations and hashes; never export offending contents."""
    found=[]
    def inspect(item,where):
        if len(found)>=32:return
        if isinstance(item,dict):
            for key,child in item.items():
                spelling=str(key)
                inspect(spelling,where+".<key-"+sha(spelling.encode())[:16]+">")
                safe_key=spelling if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,63}",spelling) and not private_reasons(spelling,environment) else "key-"+sha(spelling.encode())[:16]
                inspect(child,where+"."+safe_key)
        elif isinstance(item,(list,tuple)):
            for index,child in enumerate(item):inspect(child,where+"["+str(index)+"]")
        elif isinstance(item,str):
            reasons=private_reasons(item,environment)
            if reasons:
                matches=list(PRIVATE_CONTENT.finditer(item))[:8]
                found.append({"location":where,"reasons":reasons,"valueSha256":sha(item.encode()),
                    "patternMatches":[{"sha256":sha(match.group().encode()),"characters":len(match.group())}
                                      for match in matches]})
    inspect(value,location)
    return found


def derived_ir(text, mappings, environment):
    replacements = []
    result = text
    for path, label in sorted(mappings, key=lambda pair: len(str(pair[0])), reverse=True):
        variants = set()
        for plain in (str(path), path.as_posix(), str(path).replace("\\", "\\\\")):
            variants.add(plain)
            # LLVM quoted strings encode backslashes/non-ASCII as hex bytes.
            variants.add("".join(chr(b) if 32 <= b < 127 and b not in (34,92)
                                 else "\\%02X" % b for b in plain.encode("utf-8")))
        for variant in sorted(variants, key=len, reverse=True):
            windows=bool(re.match(r"^[A-Za-z]:[\\/]|^\\\\",str(path)))
            result,count = replace_root(result,variant,label,llvm=True,windows=windows)
            if count:
                replacements.append({"originalSpellingSha256": sha(variant.encode()),
                                     "replacement": label, "count": count})
    reasons = private_reasons(result, environment)
    # Check every LLVM quoted byte string after decoding hex escapes. Unknown
    # encodings are withheld rather than assumed to be safe source metadata.
    for match in re.finditer(r'"((?:\\.|[^"\\])*)"', result):
        value = match.group(1)
        try:
            if re.search(r'\\(?![0-9a-fA-F]{2})', value):
                raise ValueError("unknown LLVM escape")
            data = bytearray(); index = 0
            while index < len(value):
                if value[index] == "\\":
                    data.append(int(value[index+1:index+3],16)); index += 3
                else:
                    data.extend(value[index].encode()); index += 1
            if 0 in data.rstrip(b"\0"):
                raise ValueError("internal NUL makes string encoding unreviewable")
            decoded = data.decode("utf-8")
            reasons.extend(private_reasons(decoded, environment))
        except (ValueError, UnicodeError):
            reasons.append("unreviewable quoted LLVM byte string")
    for key in ("USER", "USERNAME", "COMPUTERNAME", "HOSTNAME", "USERDNSDOMAIN"):
        value = environment.get(key, "")
        if len(value) >= 3 and re.search(r'(?<![A-Za-z0-9_])'+re.escape(value)+r'(?![A-Za-z0-9_])',
                                       result, re.IGNORECASE):
            reasons.append("user or host identifier")
    receipt = {"kind":"derived normalized LLVM text; NOT original bitcode",
               "originalDisassemblySha256":sha(text.encode()),
               "derivedSha256":sha(result.encode()), "replacements":replacements,
               "privacyBlocked":sorted(set(reasons))}
    return (None if reasons else result), receipt


def publish(public, evidence, build_log, disassemblies, mappings, environment, validate=None):
    """Only these three allowlisted files may be exported; no raw IR/logs."""
    public.mkdir(mode=0o700)
    log = normalize(build_log, mappings)
    outputs = []; notes = []
    for raw_sha, text in disassemblies:
        derived, note = derived_ir(text, mappings, environment)
        note["rawBitcodeSha256"] = raw_sha
        notes.append(note)
        if derived is not None and len(disassemblies) == 1:
            check = validate(derived) if validate is not None else {"accepted":False,"reason":"not available"}
            note["sameSdkLlvmAsCheck"] = check
            note["sameSdkLlvmAsAccepted"] = check["accepted"]
            if check["accepted"]:
                outputs.append(("yjson.derived.ll", derived))
            else:
                note["privacyBlocked"].append("derived text not accepted by same-SDK llvm-as")
    clean = sanitize(evidence, mappings)
    clean["publicTextNormalization"] = ("Known path mappings and unquoted standalone short token redaction "
        "(slash-C, slash-V, slash-V-ON); lossy text only, no command-switch classification; "
        "consult existing original-byte hashes")
    if notes:clean["derivedIr"] = sanitize(notes, mappings)
    log_bytes=log.encode("utf-8")
    log_reasons=private_reasons(log,environment)
    reasons = structured_private_reasons(clean, environment)
    if reasons:
        # A minimal refusal is safe even if arbitrary subprocess output is not.
        locations=refusal_locations(clean,environment)+refusal_locations(log,environment,"buildLog")
        clean = {"status":"PRIVACY_BLOCKED", "privacyBlocked":sorted(set(reasons+log_reasons)),
                 "privacyLocations":locations[:32],
                 "targetInvocations":evidence.get("targetInvocations",0),
                 "processExitCode":evidence.get("processExitCode"),
                 "rawBitcodePublished":False}
        clean.update(failure_summary(evidence))
        outputs = []
    elif log_reasons:
        # A private aggregate log does not invalidate independently safe fields.
        # Withhold it entirely; publication metadata also passes the final scan.
        clean["buildLogPublication"]={"status":"WITHHELD","reasons":log_reasons,
            "inputTextUtf8Sha256":sha(build_log.encode("utf-8")),
            "normalizedUtf8Sha256":sha(log_bytes),"normalizedUtf8Bytes":len(log_bytes)}
    else:
        outputs.append(("build.sanitized.log", log))
    outputs.append(("receipt.json", json.dumps(clean,indent=2)+"\n"))
    for name, text in outputs:
        reasons=(structured_private_reasons(json.loads(text),environment) if name=="receipt.json"
                 else private_reasons(text,environment))
        if reasons:raise ValueError("publication failed its final privacy scan")
        (public/name).write_text(text,encoding="utf-8")
    return clean
