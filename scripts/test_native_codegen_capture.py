"""Local boundaries. Mocked native events do not qualify Windows/macOS capture."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from ir_hardlinks import CaptureMissed, IrLinks
from ir_events import windows_notifications
from ir_publication import derived_ir, publish
from native_capture_support import GitEvidence, inventory, private_reasons, system_mappings, controller_identity, normalize, path_descriptor_mismatches, canonical_checkout_environment
from native_codegen_capture import Attempt, ChildFailed, PINS, SOURCE, TREE


class HardLinksTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory();self.addCleanup(self.directory.cleanup)
        self.root=Path(self.directory.name);self.temp=self.root/"tmp";self.keep=self.root/"keep"
        self.temp.mkdir();self.keep.mkdir();self.links=IrLinks(self.temp,self.keep)

    def test_real_link_survives_writer_unlink_and_directory_cleanup(self):
        directory=self.temp/"cangjie-tmp-public";directory.mkdir();source=directory/"model.opt.bc"
        with source.open("wb") as writer:
            writer.write(b"prefix");writer.flush();self.links.accept(source)
            writer.write(b"-complete");writer.flush()
        self.links.accept(source) # modification notification is deduplicated
        source.unlink();directory.rmdir();self.links.accept(source) # late notification
        result=self.links.finish()
        self.assertEqual(len(result),1);self.assertFalse(result[0]["originalPresent"])
        self.assertEqual(result[0]["linkCountAfterLink"],2)
        self.assertEqual(result[0]["linkCountAfterCompiler"],1)
        self.assertEqual(result[0]["sha256"],hashlib.sha256(b"prefix-complete").hexdigest())
        self.assertEqual(list(self.temp.iterdir()),[])

    def test_first_event_after_unlink_is_capture_missed(self):
        self.links.accept(self.temp/"gone.opt.bc")
        with self.assertRaises(CaptureMissed):self.links.finish()

    def test_no_notification_and_no_remaining_file_is_capture_missed(self):
        with self.assertRaisesRegex(CaptureMissed,"no optimized bitcode"):self.links.finish()

    def test_cannot_link_outside_owned_temporary(self):
        path=self.root/"outside.opt.bc";path.write_bytes(b"IR");self.links.accept(path)
        with self.assertRaises(CaptureMissed):self.links.finish()
        self.assertEqual(path.read_bytes(),b"IR")

    def test_cannot_link_symlink(self):
        path=self.root/"outside";path.write_bytes(b"IR")
        try:(self.temp/"escape.opt.bc").symlink_to(path)
        except OSError:self.skipTest("symlink creation unavailable")
        self.links.accept(self.temp/"escape.opt.bc")
        with self.assertRaises(CaptureMissed):self.links.finish()

    def test_cannot_follow_symlink_parent(self):
        directory=self.root/"outside";directory.mkdir();(directory/"x.opt.bc").write_bytes(b"IR")
        try:(self.temp/"escape").symlink_to(directory,target_is_directory=True)
        except OSError:self.skipTest("symlink creation unavailable")
        self.links.accept(self.temp/"escape/x.opt.bc")
        with self.assertRaises(CaptureMissed):self.links.finish()

    def test_cross_volume_and_link_error_are_not_silenced(self):
        path=self.temp/"x.opt.bc";path.write_bytes(b"IR")
        with patch("ir_hardlinks.os.link",side_effect=OSError("cross-volume link")):
            self.links.accept(path)
        with self.assertRaisesRegex(CaptureMissed,"cross-volume"):self.links.finish()

    def test_replaced_source_between_stat_and_link_is_rejected(self):
        path=self.temp/"x.opt.bc";path.write_bytes(b"old");link=os.link
        def replace(source,destination,**kw):
            replacement=self.temp/"replacement";replacement.write_bytes(b"new")
            replacement.replace(source);link(source,destination,**kw)
        with patch("ir_hardlinks.os.link",side_effect=replace):self.links.accept(path)
        with self.assertRaisesRegex(CaptureMissed,"identity changed"):self.links.finish()
        self.assertEqual(list(self.keep.iterdir()),[])

    def test_existing_destination_not_overwritten(self):
        source=self.temp/"x.opt.bc";source.write_bytes(b"IR")
        (self.keep/"0-x.opt.bc").write_bytes(b"owned earlier")
        self.links.accept(source)
        with self.assertRaises(CaptureMissed):self.links.finish()
        self.assertEqual((self.keep/"0-x.opt.bc").read_bytes(),b"owned earlier")

    def test_final_path_replacement_is_rejected(self):
        source=self.temp/"x.opt.bc";source.write_bytes(b"IR");self.links.accept(source)
        alias=self.keep/"0-x.opt.bc";alias.unlink();alias.write_bytes(b"other")
        with self.assertRaisesRegex(CaptureMissed,"identity changed"):self.links.finish()

    def test_file_budget_is_not_relaxed(self):
        source=self.temp/"x.opt.bc"
        with source.open("wb") as stream:stream.truncate(64*1024*1024+1)
        self.links.accept(source)
        with self.assertRaisesRegex(CaptureMissed,"per-file budget"):self.links.finish()

    def test_retention_inside_temporary_is_rejected(self):
        inside=self.temp/"keep";inside.mkdir()
        with self.assertRaises(CaptureMissed):IrLinks(self.temp,inside)

    def test_non_opt_bc_ignored(self):
        path=self.temp/"x.bc";path.write_bytes(b"IR");self.links.accept(path)
        self.assertEqual(self.links.entries,[])


class PublicationTests(unittest.TestCase):
    def test_standalone_unquoted_short_tokens_are_redacted_without_exempting_paths(self):
        cases={'cmd /C /V:ON task':'cmd <redacted-slash-C> <redacted-slash-V-ON> task',
               '/V':'<redacted-slash-V>', 'cmd /C\n':'cmd <redacted-slash-C>\n'}
        for original,expected in cases.items():
            with self.subTest(original=original):
                self.assertTrue(private_reasons(original,{}))
                self.assertEqual(normalize(original,[]),expected)
                self.assertEqual(normalize(expected,[]),expected)
                self.assertEqual(private_reasons(expected,{}),[])

    def test_short_token_redaction_never_normalizes_unknown_path_extensions(self):
        for text in ['/C/private','/C'+chr(92)+'private','/Config','/C-other','/C:secret',
                     '/V:ON/private','/V:ON_EXTRA','/C'+chr(92)+'2Fprivate','/c','/v']:
            with self.subTest(text=text):
                self.assertEqual(normalize(text,[]),text)
                self.assertTrue(private_reasons(text,{}))

    def test_short_token_redaction_refuses_quoted_or_ambiguous_lines(self):
        slash=chr(92)
        for text in ['"/C"','"/C private"',"'/V secret'",'cmd "unterminated /C',
                     'cmd /C "unterminated','cmd '+slash+'" /C '+slash+'"']:
            with self.subTest(text=text):
                self.assertEqual(normalize(text,[]),text)
                self.assertTrue(private_reasons(text,{}))

    def test_short_token_redaction_refuses_multiline_quoted_contents(self):
        for text in ['cmd "prefix\n/C\nsuffix"',"cmd 'prefix\n/V\nsuffix'",'cmd "prefix\n/C\nunterminated']:
            with self.subTest(text=text):
                self.assertEqual(normalize(text,[]),text)
                self.assertTrue(private_reasons(text,{}))

    def test_short_token_redaction_does_not_hide_other_private_content(self):
        for private in ['/private/unknown','ghp_'+'a'*24,'192.168.1.2']:
            with self.subTest(private=private),tempfile.TemporaryDirectory() as directory:
                result=publish(Path(directory)/'public',{'stdout':'cmd /C '+private},'',[],[],{})
                self.assertEqual(result['status'],'PRIVACY_BLOCKED')
                self.assertEqual({x.name for x in (Path(directory)/'public').iterdir()},{'receipt.json'})

    def test_short_token_redaction_never_applies_to_llvm_derived_text(self):
        for token in ['/C','/V','/V:ON']:
            with self.subTest(token=token):
                self.assertIsNone(derived_ir('!0 = !{!"'+token+'"}',[],{})[0])

    def test_published_short_token_text_is_explicitly_lossy_and_retains_input_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            log='cmd /C /V:ON cjc -O2 --fno-chir-function-inlining'
            raw_sha=hashlib.sha256(log.encode()).hexdigest()
            output=Path(directory)/'public'
            result=publish(output,{'status':'CAPTURED_BUILD_SUCCEEDED','stdout':log,
                                  'stdoutSha256':raw_sha},log,[],[],{})
            self.assertNotEqual(result.get('status'),'PRIVACY_BLOCKED')
            self.assertEqual(result['stdoutSha256'],raw_sha)
            self.assertIn('short token',result['publicTextNormalization'])
            self.assertIn('-O2 --fno-chir-function-inlining',(output/'build.sanitized.log').read_text())
            for file in output.iterdir():self.assertEqual(private_reasons(file.read_text(),{}),[])

    def test_observed_platform_archiver_is_exact_and_same_prefix_unknown_is_refused(self):
        for path,accepted in [('/usr/bin/ar',True),('/usr/bin/ar-other',False)]:
            with self.subTest(path=path),tempfile.TemporaryDirectory() as directory:
                result=publish(Path(directory)/'public',{'argv':[path]},'',[],
                               [(Path('/usr/bin/ar'),'<platform-archiver>')],{})
                self.assertEqual(result.get('status')!='PRIVACY_BLOCKED',accepted)

    def test_exact_observed_bash_and_platform_sdk_paths_can_be_published(self):
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/'public'
            sdk=Path('/Applications/Example.app/Contents/SDKs/Platform.sdk')
            result=publish(output,{'calls':[{'argv':['/bin/bash',str(sdk/'usr/include')]}]},'',[],
                           [(Path('/bin/bash'),'<bash>'),(sdk,'<platform-sdk>')],{})
            self.assertNotEqual(result.get('status'),'PRIVACY_BLOCKED')
            self.assertEqual(result['calls'][0]['argv'],['<bash>','<platform-sdk>/usr/include'])

    def test_unknown_same_prefix_shell_is_withheld_with_only_location_and_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/'public';unknown='/bin/bash-other'
            result=publish(output,{'calls':[{'argv':[unknown]}]},'',[],
                           [(Path('/bin/bash'),'<bash>')],{})
            self.assertEqual(result['status'],'PRIVACY_BLOCKED')
            location=result['privacyLocations'][0]
            self.assertEqual(location['location'],'receipt.calls[0].argv[0]')
            self.assertEqual(location['valueSha256'],hashlib.sha256(unknown.encode()).hexdigest())
            self.assertNotIn(unknown,json.dumps(result))
            self.assertEqual({f.name for f in output.iterdir()},{'receipt.json'})

    def test_refusal_location_does_not_echo_arbitrary_dictionary_keys_or_log_content(self):
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/'public'
            result=publish(output,{'/private/unknown-key':'/private/unknown-value'},
                           '/private/unknown-log',[],[],{})
            self.assertEqual(result['status'],'PRIVACY_BLOCKED')
            self.assertNotIn('/private/',json.dumps(result))
            self.assertTrue(any(x['location']=='buildLog' for x in result['privacyLocations']))
            self.assertEqual(private_reasons(json.dumps(result),{}),[])

    def test_known_path_replacements_are_bound_and_marked_derived(self):
        path=Path("/private/capture-public")
        text='; ModuleID = "/private/capture-public/x.bc"\n!0 = !DIFile(filename: "x.cj", directory: "/private/capture-public")\n'
        result,note=derived_ir(text,[(path,"<source>")],{})
        self.assertIsNotNone(result);self.assertNotIn(str(path),result)
        self.assertTrue(note["replacements"]);self.assertIn("NOT original",note["kind"])
        self.assertNotEqual(note["originalDisassemblySha256"],note["derivedSha256"])

    def test_unknown_same_prefix_directory_is_not_normalized_or_published(self):
        text='!0 = !DIFile(filename: "x.cj", directory: "/Users/alice-other/private.cj")\n'
        mappings=[(Path("/Users/alice"),"<home>")]
        self.assertEqual(normalize(text,mappings),text)
        result,note=derived_ir(text,mappings,{})
        self.assertIsNone(result);self.assertTrue(note["privacyBlocked"])

    def test_unknown_hex_same_prefix_directory_is_not_normalized_or_published(self):
        text='!0 = !DIFile(filename: "x.cj", directory: "/Users/alice\\2Dother/private.cj")\n'
        mappings=[(Path("/Users/alice"),"<home>")]
        self.assertEqual(normalize(text,mappings),text)
        result,note=derived_ir(text,mappings,{})
        self.assertIsNone(result);self.assertTrue(note["privacyBlocked"])

    def test_known_root_literal_and_hex_path_separators_still_normalize(self):
        mappings=[(Path("/Users/alice"),"<home>")]
        for path in ["/Users/alice", "/Users/alice/private.cj",r"/Users/alice\2Fprivate.cj"]:
            text='!0 = !DIFile(filename: "x.cj", directory: "'+path+'")\n'
            with self.subTest(path=path):
                self.assertIn("<home>",normalize(text,mappings))
                self.assertIsNotNone(derived_ir(text,mappings,{})[0])

    def test_unknown_hex_encoded_path_is_blocked(self):
        result,note=derived_ir('!0 = !{!"\\2Fprivate\\2Funknown\\2Fsource.cj"}\n',[],{})
        self.assertIsNone(result);self.assertTrue(note["privacyBlocked"])

    def test_known_hex_encoded_windows_path_is_replaced(self):
        # Path itself is a literal native spelling here, even when tested on POSIX.
        path=Path(r"C:\capture-public")
        result,note=derived_ir('!0 = !{!"C:\\5Ccapture-public\\5Cx.cj"}\n',[(path,"<source>")],{})
        self.assertIsNotNone(result);self.assertNotIn("capture-public",result)
        self.assertTrue(note["replacements"])

    def test_local_ipv6_and_ipv4_ranges_are_blocked_but_documentation_allowed(self):
        for address in ["fc00::42","fd12:3456::9","::1","fe80::42","169.254.2.9",
                        "10.1.2.3","172.31.2.4","192.168.1.2","127.0.0.1","100.64.2.3",
                        "::ffff:192.168.1.2","::"]:
            with self.subTest(address=address):
                self.assertIsNone(derived_ir('!0 = !{!"'+address+'"}',[],{})[0])
        for address in ["2001:db8::1","192.0.2.1","198.51.100.4","203.0.113.9","2001:4860:4860::8888"]:
            with self.subTest(address=address):
                self.assertIsNotNone(derived_ir('!0 = !{!"'+address+'"}',[],{})[0])

    def test_system_error_stack_paths_are_sanitized_without_blocking_specific_error(self):
        with tempfile.TemporaryDirectory() as directory:
            log='LLVM ERROR: Cannot emit physreg copy instruction\nC:\\Windows\\System32\\ucrtbase.dll\n/usr/lib/system/libsystem_kernel.dylib\n/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation\n'
            output=Path(directory)/"public"
            result=publish(output,{"status":"CAPTURED_BUILD_FAILED"},log,[],system_mappings({}),{})
            self.assertEqual(result["status"],"CAPTURED_BUILD_FAILED")
            self.assertIn("Cannot emit physreg copy instruction",(output/"build.sanitized.log").read_text())
            self.assertNotIn("C:\\Windows",(output/"build.sanitized.log").read_text())

    def test_real_llvm_namespace_shapes_are_not_ipv6_literals(self):
        for value in ["llvm::report_fatal_error", "llvm::X86InstrInfo::copyPhysReg",
                      "llvm::FPPassManager::runOnModule", "std::__1::string"]:
            with self.subTest(value=value):self.assertEqual(private_reasons(value,{}),[])
        for value in ["[fd12:3456::9]", '"::1"', "address=fe80::42%en0"]:
            with self.subTest(value=value):self.assertTrue(private_reasons(value,{}))

    def test_embedded_nul_utf16_and_utf32_private_paths_are_withheld(self):
        path="C:"+chr(92)+"Users"+chr(92)+"alice"+chr(92)+"private.cj"
        for encoding in ["utf-16-le","utf-32-le"]:
            encoded="".join("\\%02X"%byte for byte in path.encode(encoding))
            with self.subTest(encoding=encoding):
                result,note=derived_ir('!0 = !{!"'+encoded+'"}',[],{})
                self.assertIsNone(result);self.assertTrue(note["privacyBlocked"])

    def test_ordinary_public_string_with_trailing_nul_is_reviewable(self):
        result,note=derived_ir('!0 = !{!"public text\\00"}',[],{})
        self.assertIsNotNone(result);self.assertEqual(note["privacyBlocked"],[])

    def test_unknown_non_utf8_string_is_withheld(self):
        result,note=derived_ir('!0 = !{!"\\FF\\FE"}\n',[],{})
        self.assertIsNone(result);self.assertTrue(note["privacyBlocked"])

    def test_credentials_username_and_private_addresses_are_blocked(self):
        cases=[('!0 = !{!"ghp_'+"a"*24+'"}',{}),('!0 = !{!"192.168.2.4"}',{}),
               ('!0 = !{!"example-local-user"}',{"USERNAME":"example-local-user"})]
        for text,environment in cases:
            with self.subTest(text=text):self.assertIsNone(derived_ir(text,[],environment)[0])

    def test_raw_bitcode_is_never_published_and_assembler_is_required(self):
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/"public"
            result=publish(output,{"targetInvocations":1},"",[("a"*64,"; public IR\n")],[],{})
            self.assertEqual({p.name for p in output.iterdir()},{"receipt.json","build.sanitized.log"})
            self.assertFalse(result["derivedIr"][0]["sameSdkLlvmAsAccepted"])

    def test_derived_ir_only_after_same_sdk_syntax_acceptance(self):
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/"public";validator=Mock(return_value={"accepted":True,"argv":["llvm-as"],"exitCode":0,"logSha256":"a"*64})
            publish(output,{},"",[("a"*64,"; public IR\n")],[],{},validator)
            validator.assert_called_once_with("; public IR\n")
            self.assertTrue((output/"yjson.derived.ll").is_file())
            self.assertFalse(any(p.suffix==".bc" for p in output.iterdir()))

    def test_length_invalid_replacement_is_withheld_on_assembler_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/"public"
            result=publish(output,{},"",[("a"*64,'@x = private constant [17 x i8] c"/private/public\\00"\n')],
                           [(Path("/private"),"<source>")],{},lambda text:{"accepted":False,"exitCode":1})
            self.assertFalse((output/"yjson.derived.ll").exists())
            self.assertTrue(result["derivedIr"][0]["privacyBlocked"])

    def test_unknown_git_stderr_blocks_log_instead_of_leaking(self):
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/"public"
            result=publish(output,{"gitCalls":[{"stderr":"fatal: /private/unknown/repo"}]},"",[],[],{})
            self.assertEqual(result["status"],"PRIVACY_BLOCKED")
            self.assertEqual({p.name for p in output.iterdir()},{"receipt.json"})

    def test_sanitized_specific_git_stderr_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/"public"
            result=publish(output,{"gitCalls":[{"argv":["git","-C","/private/known","rev-parse","HEAD"],
                "exitCode":128,"stderr":"fatal: /private/known: not a git repository"}]},"",[],
                [(Path("/private/known"),"<source>")],{})
            self.assertEqual(result["gitCalls"][0]["exitCode"],128)
            self.assertIn("not a git repository",result["gitCalls"][0]["stderr"])


class IdentityTests(unittest.TestCase):
    def test_git_first_failure_keeps_exact_subcommand_exit_and_stderr(self):
        runner=Mock(return_value=subprocess.CompletedProcess([],128,"","fatal: missing object public-sha"))
        evidence=GitEvidence(runner)
        with self.assertRaisesRegex(ValueError,"rev-parse HEAD.*128"):
            evidence.read(Path("source"),"rev-parse","HEAD")
        self.assertEqual(evidence.calls[0]["stderr"],"fatal: missing object public-sha")
        self.assertEqual(evidence.calls[0]["argv"][-2:],["rev-parse","HEAD"])

    def test_controller_identity_binds_observed_workflow_python_and_module_bytes(self):
        module=Path(__file__).resolve()
        env={"GITHUB_SHA":"a"*40,"GITHUB_RUN_ID":"42","GITHUB_RUN_ATTEMPT":"1",
             "GITHUB_JOB":"capture","ImageOS":"example-os","ImageVersion":"1"}
        before=controller_identity([module],env);after=controller_identity([module],env)
        self.assertEqual(before,after);self.assertEqual(before["workflow"]["GITHUB_RUN_ID"],"42")
        self.assertIsNone(before["workflow"]["RUNNER_OS"])
        self.assertEqual(before["modules"][0]["sha256"],hashlib.sha256(module.read_bytes()).hexdigest())
        self.assertEqual(len(before["python"]["sha256"]),64)

    def test_inventory_records_working_bytes_and_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);path=root/"cjpm.toml";path.write_bytes(b"compile-option=-O0")
            row=inventory(root,["cjpm.toml"])[0]
            self.assertEqual(row["sha256"],hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(row["mode"],path.stat().st_mode&0o777)

    def test_inventory_rejects_a_different_open_file_even_when_its_bytes_match(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'source.cj';other=root/'other.cj'
            source.write_bytes(b'same bytes');other.write_bytes(b'same bytes')
            real_open=Path.open
            def swapped(path,*args,**kwargs):
                return real_open(other if path==source else path,*args,**kwargs)
            with patch.object(Path,'open',swapped):
                with self.assertRaisesRegex(ValueError,'opened source input differs'):
                    inventory(root,['source.cj'])

    def test_inventory_still_rejects_same_fd_ctime_change_during_read(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'source.cj';source.write_bytes(b'original')
            with source.open('rb') as stream:info=os.fstat(stream.fileno())
            fields=('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns','st_mode','st_birthtime_ns')
            values={key:getattr(info,key) for key in fields if hasattr(info,key)}
            changed=SimpleNamespace(**(values|{'st_ctime_ns':info.st_ctime_ns+1}))
            with patch('native_capture_support.os.fstat',side_effect=[info,changed]):
                with self.assertRaisesRegex(ValueError,'opened source input changed'):
                    inventory(root,['source.cj'])


class WindowsStatBoundaryTests(unittest.TestCase):
    def stats(self):
        common=dict(st_dev=41,st_ino=123456789,st_size=19,st_mtime_ns=100,
                    st_birthtime_ns=10,st_ctime_ns=10,st_mode=0o100666)
        return SimpleNamespace(**common),SimpleNamespace(**(common|{'st_ctime_ns':20}))

    def test_windows_path_creation_time_and_fd_change_time_are_distinct_apis(self):
        path,fd=self.stats()
        self.assertEqual(path_descriptor_mismatches(path,fd,windows=True),[])
        self.assertEqual(path_descriptor_mismatches(path,fd,windows=False),['st_ctime_ns'])

    def test_windows_suffix_execute_bits_do_not_hide_readonly_or_type_changes(self):
        path,fd=self.stats();path.st_mode|=0o111
        self.assertEqual(path_descriptor_mismatches(path,fd,windows=True),[])
        for mode in [0o100444,0o040666]:
            with self.subTest(mode=mode):
                fd.st_mode=mode
                self.assertIn('st_mode',path_descriptor_mismatches(path,fd,windows=True))

    def test_windows_identity_size_write_and_creation_changes_remain_rejected(self):
        for field in ['st_dev','st_ino','st_size','st_mtime_ns','st_birthtime_ns']:
            with self.subTest(field=field):
                path,fd=self.stats();setattr(fd,field,getattr(fd,field)+1)
                self.assertIn(field,path_descriptor_mismatches(path,fd,windows=True))


class CheckoutEnvironmentTests(unittest.TestCase):
    def test_empty_config_count_follows_git_zero_entry_semantics(self):
        original={'GIT_CONFIG_COUNT':''}
        configured,note=canonical_checkout_environment(original)
        self.assertEqual(configured['GIT_CONFIG_COUNT'],'2')
        self.assertEqual(note['inheritedConfigCount'],0)
        self.assertEqual(original,{'GIT_CONFIG_COUNT':''})

    def test_append_preserves_inherited_config_and_does_not_mutate_caller(self):
        original={'GIT_CONFIG_COUNT':'2','GIT_CONFIG_KEY_0':'example.first','GIT_CONFIG_VALUE_0':'value',
                  'GIT_CONFIG_KEY_1':'core.autocrlf','GIT_CONFIG_VALUE_1':'true','TMPDIR':'controlled'}
        configured,note=canonical_checkout_environment(original)
        self.assertEqual(configured['GIT_CONFIG_COUNT'],'4')
        self.assertEqual(configured['GIT_CONFIG_KEY_2'],'core.autocrlf')
        self.assertEqual(configured['GIT_CONFIG_VALUE_2'],'false')
        self.assertEqual(configured['GIT_CONFIG_KEY_3'],'core.eol')
        self.assertEqual(configured['GIT_CONFIG_VALUE_3'],'lf')
        self.assertTrue(all(configured[key]==value for key,value in original.items() if key!='GIT_CONFIG_COUNT'))
        self.assertEqual(original['GIT_CONFIG_COUNT'],'2');self.assertEqual(note['inheritedConfigCount'],2)

    def test_missing_invalid_or_incomplete_inherited_config_is_not_silently_replaced(self):
        for environment in [{'GIT_CONFIG_COUNT':'-1'},{'GIT_CONFIG_COUNT':'bad'},
                            {'GIT_CONFIG_COUNT':'1','GIT_CONFIG_KEY_0':'example.key'}]:
            with self.subTest(environment=environment):
                with self.assertRaises(ValueError):canonical_checkout_environment(environment)


class RawGitSnapshotTests(unittest.TestCase):
    """Blob oracles below were independently obtained with git hash-object."""
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        (self.root/"fixture.cj").write_bytes(b"line\r\n")
        (self.root/"tool.sh").write_bytes(b"#!/bin/sh\nexit 0\n")
        (self.root/"tool.sh").chmod(0o755)
        self.head="a"*40;self.tree="b"*40
        self.entries=["100644 blob 0e7d2a27f5d40d534cd366dd2c9b60ecb3fa7437\tfixture.cj",
                      "100755 blob 039e4d0069c5c26909f86c505b9de66182e6d1f3\ttool.sh",
                      "160000 commit "+"c"*40+"\tcomponent"]
        self.index=[row.replace(" blob "," ").replace(" commit "," ").replace("\t"," 0\t",1)
                    for row in self.entries]

    def evidence(self,diff_code=0,status="",index=None):
        responses={('rev-parse','HEAD'):(0,self.head+'\n'),
                   ('rev-parse','HEAD^{tree}'):(0,self.tree+'\n'),
                   ('ls-tree','-rz','--full-tree','HEAD'):(0,'\0'.join(self.entries)+'\0'),
                   ('ls-files','--stage','-z'):(0,'\0'.join(self.index if index is None else index)+'\0'),
                   ('diff','--exit-code','HEAD','--'):(diff_code,'CRLF clean-filter difference\n' if diff_code else ''),
                   ('status','--porcelain=v1','--untracked-files=all'):(0,status.replace('\0','\n')),
                   ('status','--porcelain=v1','-z','--untracked-files=all'):(0,status)}
        def runner(argv,**kwargs):
            self.assertEqual(kwargs['env']['GIT_OPTIONAL_LOCKS'],'0')
            code,stdout=responses[tuple(argv[3:])]
            return subprocess.CompletedProcess(argv,code,stdout.encode(),b'')
        return GitEvidence(runner,{'GIT_OPTIONAL_LOCKS':'0'})

    def test_git_observations_disable_optional_index_writes_without_mutating_caller_env(self):
        environment={'EXAMPLE':'value'}
        runner=Mock(return_value=subprocess.CompletedProcess([],0,b'',b''))
        evidence=GitEvidence(runner,environment)
        # Attempt installs controlled temp variables after creating GitEvidence.
        environment['TMPDIR']='controlled-temp'
        evidence.read(self.root,'rev-parse','HEAD')
        observed=runner.call_args.kwargs['env']
        self.assertEqual(observed['GIT_OPTIONAL_LOCKS'],'0')
        self.assertEqual(observed['TMPDIR'],'controlled-temp')
        self.assertEqual(environment,{'EXAMPLE':'value','TMPDIR':'controlled-temp'})

    def test_exact_raw_crlf_blob_accepted_without_hiding_normalized_git_difference(self):
        evidence=self.evidence(1,' M fixture.cj\0')
        result=evidence.snapshot(self.root,self.head,self.tree)
        self.assertTrue(result['rawGitBlobsVerified']);self.assertTrue(result['indexMatchesHead'])
        self.assertEqual((self.root/'fixture.cj').read_bytes(),b'line\r\n')
        note=evidence.normalized_observations[0]
        self.assertEqual(note['diffExitCode'],1);self.assertEqual(note['porcelainStatus'],' M fixture.cj\0')
        self.assertFalse(result['gitlinks'][0]['followed'])

    def test_git_clean_filter_cannot_hide_changed_raw_bytes(self):
        (self.root/'fixture.cj').write_bytes(b'line\n')
        with self.assertRaisesRegex(ValueError,'raw working bytes differ'):
            self.evidence().snapshot(self.root,self.head,self.tree)

    def test_index_modes_oids_stages_duplicates_and_extra_paths_are_rejected(self):
        variants=[self.index[1:],self.index+[self.index[0]],
                  [self.index[0].replace('100644','100755'),*self.index[1:]],
                  [self.index[0].replace(' 0\t',' 2\t'),*self.index[1:]],
                  [self.index[0].replace('0e7d2a27','12345678'),*self.index[1:]],
                  self.index+['100644 '+'d'*40+' 0\tuntracked-in-index']]
        for index in variants:
            with self.subTest(index=index):
                with self.assertRaisesRegex(ValueError,'Git index differs'):
                    self.evidence(index=index).snapshot(self.root,self.head,self.tree)

    def test_untracked_and_unsupported_status_remain_failures(self):
        for status in ['?? extra.cj\0','M  fixture.cj\0',' R fixture.cj\0old.cj\0']:
            with self.subTest(status=status):
                with self.assertRaisesRegex(ValueError,'untracked, staged, or unsupported'):
                    self.evidence(status=status).snapshot(self.root,self.head,self.tree)

    def test_git_diff_operational_failure_is_not_an_accepted_normalization(self):
        with self.assertRaisesRegex(ValueError,'normalized diff failed'):
            self.evidence(diff_code=128).snapshot(self.root,self.head,self.tree)

    @unittest.skipIf(os.name=='nt','POSIX executable mode only')
    def test_working_execute_mode_drift_is_rejected(self):
        (self.root/'tool.sh').chmod(0o644)
        with self.assertRaisesRegex(ValueError,'execute mode differs'):
            self.evidence().snapshot(self.root,self.head,self.tree)

    @unittest.skipIf(os.name=='nt','POSIX Git owner executable mode only')
    def test_group_execute_bit_does_not_change_git_owner_execute_mode(self):
        (self.root/'fixture.cj').chmod(0o654)
        self.assertTrue(self.evidence().snapshot(self.root,self.head,self.tree)['rawGitBlobsVerified'])


class NotificationTests(unittest.TestCase):
    def test_real_windows_notification_layout(self):
        import struct
        name="child\\model.opt.bc".encode("utf-16-le")
        raw=struct.pack("<III",0,1,len(name))+name
        self.assertEqual(list(windows_notifications(raw)),[(1,"child\\model.opt.bc")])

    def test_empty_overflow_and_truncated_events_are_not_silenced(self):
        for raw in [b"",b"short"]:
            with self.subTest(raw=raw):
                with self.assertRaises(ValueError):list(windows_notifications(raw))

    def test_odd_utf16_and_invalid_offset_rejected(self):
        import struct
        for raw in [struct.pack("<III",0,1,3)+b"abc",struct.pack("<III",4,1,0)+b"padding"]:
            with self.assertRaises(ValueError):list(windows_notifications(raw))


class FakeWatch:
    active=None
    def __init__(self,links,selected):self.links=links
    def start(self):FakeWatch.active=self
    def stop(self):pass


class ControlledAttempt(Attempt):
    def __init__(self,*args,child_code=0,capture=True,preflight_error=None,**kwargs):
        self.child_code=child_code;self.capture=capture;self.preflight_error=preflight_error
        self.target_calls=0;self.resolve_calls=0
        super().__init__(*args,runner=self.run_child,watcher=FakeWatch,**kwargs)
        self.git.read=lambda *args:None
        self.git.snapshot=lambda *args:{"commit":SOURCE,"tree":TREE,"files":[]}
    def run_child(self,argv,**kwargs):
        self.target_calls+=1
        temp=Path(kwargs["env"]["TMPDIR"]);directory=temp/"cangjie-tmp-public";directory.mkdir()
        path=directory/"yjson.opt.bc";path.write_bytes(b"private original bitcode")
        if self.capture:FakeWatch.active.links.accept(path)
        path.unlink();directory.rmdir()
        log="Compiling package `yjson`: cjc -p "+str(Path.home()/".cjpm/git/yjson"/PINS["yjson"]/"src")+" -O0 -O2 --fno-chir-function-inlining --output-type=staticlib\n"
        return subprocess.CompletedProcess(argv,self.child_code,log,"public backend failure" if self.child_code else "")
    def authenticate(self):pass
    def preflight(self):
        if self.preflight_error:raise self.preflight_error
    def lock_pins(self):pass
    def resolve_sources(self):self.resolve_calls+=1
    def dependencies(self, allow_missing=False):return {}
    def disassemble(self,*args):return "; public test disassembly\n"


class ExecutionTests(unittest.TestCase):
    def make(self,directory,**kwargs):
        root=Path(directory);source=root/"source";source.mkdir();output=root/"output";output.mkdir()
        return ControlledAttempt(source,output,"windows-x64",**kwargs)

    def test_preflight_failure_stops_resolution_and_target(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt=self.make(directory,preflight_error=ChildFailed("preflight",13))
            self.assertEqual(attempt.execute(),13);self.assertEqual(attempt.target_calls,0)
            self.assertEqual(attempt.resolve_calls,0);self.assertEqual(attempt.evidence["targetInvocations"],0)

    def test_preflight_capture_miss_stops_target(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt=self.make(directory,preflight_error=CaptureMissed("controlled tmp not used"))
            self.assertEqual(attempt.execute(),2);self.assertEqual(attempt.target_calls,0)
            self.assertEqual(attempt.evidence["status"],"CAPTURE_MISSED")

    def test_one_target_and_original_exit_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt=self.make(directory,child_code=7)
            self.assertEqual(attempt.execute(),7);self.assertEqual(attempt.target_calls,1)
            self.assertEqual(attempt.evidence["status"],"CAPTURED_BUILD_FAILED")
            self.assertEqual(attempt.evidence["processExitCode"],7)

    def test_target_capture_miss_does_not_mean_non_reproduction(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt=self.make(directory,capture=False)
            self.assertEqual(attempt.execute(),2);self.assertEqual(attempt.target_calls,1)
            self.assertEqual(attempt.evidence["status"],"CAPTURE_MISSED")
            self.assertNotIn("NOT_REPRODUCED",json.dumps(attempt.evidence))

    def test_target_failure_and_capture_miss_keep_original_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt=self.make(directory,child_code=9,capture=False)
            self.assertEqual(attempt.execute(),9);self.assertEqual(attempt.target_calls,1)
            self.assertEqual(attempt.evidence["status"],"CAPTURE_MISSED")

    def test_existing_attempt_marker_stops_without_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt=self.make(directory);(attempt.output/"attempt.marker").write_text("")
            self.assertEqual(attempt.execute(),2);self.assertEqual(attempt.target_calls,0)

    def test_initial_snapshot_failure_keeps_rejected_working_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt=self.make(directory)
            attempt.git.last_snapshot={'rawGitBlobsVerified':False,'files':[{'path':'fixture.cj','sha256':'a'*64}]}
            attempt.git.snapshot=Mock(side_effect=ValueError('raw working bytes differ'))
            self.assertEqual(attempt.execute(),2);self.assertEqual(attempt.target_calls,0)
            self.assertIn('lastRejectedWorkingSnapshot',attempt.evidence)
            self.assertEqual(attempt.evidence['lastRejectedWorkingSnapshot'],attempt.git.last_snapshot)

    def test_publication_error_cannot_replace_original_target_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt=self.make(directory,child_code=7)
            with patch("native_codegen_capture.publish",side_effect=ValueError("publication refused")):
                self.assertEqual(attempt.execute(),7)
            self.assertEqual(attempt.target_calls,1)
            self.assertIn("publication refused",attempt.evidence["publicationError"])

    def test_success_is_diagnostic_only(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt=self.make(directory)
            self.assertEqual(attempt.execute(),0);self.assertEqual(attempt.target_calls,1)
            self.assertTrue(attempt.evidence["diagnosticOnly"])
            self.assertIn("not OS execve",attempt.evidence["argvObservation"])


class ResolverTests(unittest.TestCase):
    def prepare(self,directory,mutate=False,bad_config=False):
        from native_codegen_capture import PROVIDER, BOUNDARY
        root=Path(directory);source=root/"source";source.mkdir();output=root/"output";output.mkdir()
        (source/PROVIDER).mkdir(parents=True)
        lock="version = 0\n[requires]\n"+"".join(name+' = {git="https://example.test/'+name+'", commitId="'+pin+'"}\n' for name,pin in PINS.items())
        for name in BOUNDARY:(source/name).write_text(lock if name.endswith("lock") else "[package]\ncjc-version='1.3.0'\n")
        calls=[]
        def runner(argv,**kwargs):
            if argv[0]=='git':
                self.assertEqual(argv[-3:-1],['config','--get'])
                value='true' if bad_config else {'core.autocrlf':'false','core.eol':'lf'}[argv[-1]]
                return subprocess.CompletedProcess(argv,0,(value+'\n').encode(),b'')
            calls.append(argv)
            self.assertEqual(argv[-2:],["update","--skip-script"])
            if Path(kwargs["cwd"]).name=="resolver-proof":
                self.assertIn('cjc-version="1.3.0"',(Path(kwargs["cwd"])/"cjpm.toml").read_text())
                self.assertIn("INVALID_BUILD_SCRIPT",(Path(kwargs["cwd"])/"build.cj").read_text())
            elif mutate:(source/"cjpm.lock").write_text("changed")
            return subprocess.CompletedProcess(argv,0,b"update completed\n",b"")
        attempt=Attempt(source,output,"windows-x64",runner=runner)
        attempt.tools={"cjpm":Path("cjpm")}
        return attempt,calls

    def test_native_skip_script_proof_precedes_single_actual_resolution(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt,calls=self.prepare(directory)
            attempt.resolve_sources()
            self.assertEqual(len(calls),2) # tiny proof, then one actual source resolution
            self.assertEqual(attempt.evidence["boundaryBeforeResolve"],attempt.evidence["boundaryAfterResolve"])
            self.assertEqual(attempt.evidence["targetInvocations"],0)

    def test_effective_git_config_mismatch_stops_before_resolver_or_target(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt,calls=self.prepare(directory,bad_config=True)
            with self.assertRaisesRegex(ValueError,'effective diagnostic Git checkout config differs'):
                attempt.resolve_sources()
            self.assertEqual(calls,[]);self.assertEqual(attempt.evidence['targetInvocations'],0)

    def test_canonical_git_policy_is_windows_only(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt,calls=self.prepare(directory)
            attempt.selected='macos-arm64';attempt.git.read=Mock(side_effect=AssertionError('unexpected Git override'))
            attempt.resolve_sources()
            self.assertNotIn('dependencyCheckoutPolicy',attempt.evidence);self.assertEqual(len(calls),2)

    def test_resolution_lock_drift_stops_before_any_target(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt,calls=self.prepare(directory,mutate=True)
            with self.assertRaisesRegex(ValueError,"resolve changed"):attempt.resolve_sources()
            self.assertEqual(len(calls),2);self.assertEqual(attempt.evidence["targetInvocations"],0)


class NativePreflightTests(unittest.TestCase):
    def prepare(self,directory,leave_temp=False,assembly=False):
        root=Path(directory);source=root/"source";source.mkdir();output=root/"output";output.mkdir()
        def runner(argv,**kwargs):
            self.assertNotIn("--save-temps",argv)
            self.assertEqual(Path(kwargs["cwd"]),output/"private")
            temp=Path(kwargs["env"]["TMPDIR"]);child=temp/"cangjie-tmp-public";child.mkdir()
            original=child/"preflight.opt.bc";original.write_bytes(b"public mock IR")
            FakeWatch.active.links.accept(original)
            if not leave_temp:original.unlink();child.rmdir()
            Path(argv[-1]).write_bytes(b"public mock static library")
            text="'<sdk>/llc' '-O2' '--filetype=obj'\n"+ ("'<sdk>/llc' '--filetype=asm'\n" if assembly else "")
            return subprocess.CompletedProcess(argv,0,text,"")
        attempt=Attempt(source,output,"windows-x64",runner=runner,watcher=FakeWatch)
        attempt.tools={"cjc":Path("cjc")};attempt.disassemble=lambda *args:"public mock disassembly"
        return attempt

    def test_preflight_checks_real_cleanup_shape_and_one_object_backend(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt=self.prepare(directory);attempt.preflight()
            self.assertTrue(attempt.evidence["preflightCleanup"]["controlledTempEmpty"])
            self.assertEqual(attempt.evidence["targetInvocations"],0)
            shell=attempt.evidence['calls'][0]['argv'][0]
            self.assertEqual(normalize(shell,attempt.mappings),'<bash>')

    def test_preflight_leftover_original_stops_target(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt=self.prepare(directory,leave_temp=True)
            with self.assertRaises(CaptureMissed):attempt.preflight()
            self.assertEqual(attempt.evidence["targetInvocations"],0)

    def test_preflight_extra_assembly_backend_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt=self.prepare(directory,assembly=True)
            with self.assertRaisesRegex(CaptureMissed,"no added assembly"):attempt.preflight()
            self.assertEqual(attempt.evidence["targetInvocations"],0)


class WorkflowTests(unittest.TestCase):
    def test_manual_native_matrix_separate_checkouts_and_explicit_allowlist(self):
        workflow=(Path(__file__).resolve().parents[1]/".github/workflows/ci.yml").read_text()
        self.assertIn("workflow_dispatch:",workflow)
        self.assertNotIn("pull_request:",workflow);self.assertNotIn("  push:",workflow)
        self.assertIn("contents: read",workflow);self.assertIn("retention-days: 3",workflow)
        self.assertIn("runner: windows-2022",workflow);self.assertIn("runner: macos-15",workflow)
        self.assertIn("ref: "+SOURCE,workflow);self.assertIn("path: controller",workflow)
        self.assertIn("path: product",workflow);self.assertNotIn("--save-temps",workflow)
        self.assertNotIn("public/*",workflow);self.assertNotIn("private/",workflow)
        self.assertNotIn(".opt.bc",workflow);self.assertIn("/public/yjson.derived.ll",workflow)


if __name__=="__main__":unittest.main()
