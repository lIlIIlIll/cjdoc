"""Bounded backend observation contracts; mocked calls are not native proof."""
from dataclasses import replace
import hashlib
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import Mock

from native_backend_trace import FLAGS, TraceRequest, observed_profile, observations, trace_once
from native_codegen_capture import Attempt


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class BackendTraceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.tool=self.root/"sdk/llc";self.tool.parent.mkdir();self.tool.write_bytes(b"SDK mock tool")
        self.bc=self.root/"retained.opt.bc";self.bc.write_bytes(b"original mock IR")
        self.original=self.root/"compiler-tmp/yjson.opt.bc"

    def request(self,platform="macos-arm64",suffix="trace"):
        argv=[str(self.tool),str(self.original),*FLAGS[platform],
              str(self.original.parent/"yjson.o")]
        if platform=="windows-x64":
            line=" ".join('"'+part+'"' for part in argv)
            failure='error: "'+line+' ": command failed with exit code 3221225501 (use -V to see invocation)'
        else:
            line=" ".join("'"+part+"'" for part in argv)
            prefix="LD_LIBRARY_PATH="+shlex.quote(str(self.tool.parent/"../lib"))+":$DYLD_LIBRARY_PATH "
            failure="error: "+prefix+line+" : command failed with exit code 139 (use -V to see invocation)"
        return TraceRequest(platform,self.tool,sha(self.tool),self.bc,sha(self.bc),
                            self.original,failure,self.root/suffix,dict(os.environ))

    def runner(self,argv,**kwargs):
        self.assertEqual(kwargs["timeout"],600)
        self.assertEqual(argv[-1],"--debug-pass=Executions")
        self.assertEqual(argv.count("-O2"),1)
        self.assertNotIn("--filetype=asm",argv);self.assertNotIn("--save-temps",argv)
        kwargs["stderr"].write(b"Executing Pass 'Post-RA pseudo instruction expansion pass' on Function '_CN5yjson4testHv'...\nLLVM ERROR: mock failure\n")
        return subprocess.CompletedProcess(argv,7)

    def test_exact_native_profiles_one_backend_and_original_ir_unchanged(self):
        for platform in FLAGS:
            with self.subTest(platform=platform):
                request=self.request(platform,platform)
                result=trace_once(request,self.runner)
                self.assertEqual(result["backendInvocations"],1)
                self.assertEqual(result["exitCode"],7);self.assertTrue(result["inputsUnchanged"])
                self.assertEqual(result["observations"]["lastRecordedExecution"]["function"],"_CN5yjson4testHv")
                self.assertFalse(result["qualification"]);self.assertFalse(result["rawTracePublished"])
                self.assertEqual(sha(self.bc),request.expected_bitcode_sha256)

    def test_original_success_or_other_package_failure_never_starts_backend(self):
        for log in ["build succeeded",self.request().build_log.replace("yjson.opt.bc","markdown.opt.bc")]:
            runner=Mock()
            with self.assertRaisesRegex(ValueError,"no explicit yjson llc failure"):
                trace_once(replace(self.request(),build_log=log),runner)
            runner.assert_not_called()

    def test_changed_complete_profile_or_duplicate_failure_never_runs(self):
        request=self.request()
        for log in [request.build_log.replace("'-O2'","'-O1'"),
                    request.build_log.replace("'-O2'","'-O2' '--unknown-option'"),
                    request.build_log+"\n"+request.build_log]:
            runner=Mock()
            with self.assertRaises(ValueError):trace_once(replace(request,build_log=log),runner)
            runner.assert_not_called()

    def test_changed_input_output_tool_or_loader_never_runs(self):
        request=self.request()
        for log in [request.build_log.replace("yjson.o'", "other.o'"),
                    request.build_log.replace("/../lib", "/untrusted/lib"),
                    request.build_log.replace(" : command", " 'extra-operand' : command"),
                    request.build_log.replace("LD_LIBRARY_PATH=", "INJECTED=bad LD_LIBRARY_PATH=")]:
            runner=Mock()
            with self.assertRaises(ValueError):trace_once(replace(request,build_log=log),runner)
            runner.assert_not_called()

    def test_macos_loader_assignment_uses_inherited_value_without_shell_execution(self):
        request=replace(self.request(),environment={"DYLD_LIBRARY_PATH":"inherited value"})
        runner=Mock(side_effect=self.runner)
        result=trace_once(request,runner)
        self.assertEqual(runner.call_args.kwargs["env"]["LD_LIBRARY_PATH"],
                         str(self.tool.parent/"../lib")+":inherited value")
        self.assertEqual(request.environment,{"DYLD_LIBRARY_PATH":"inherited value"})
        self.assertEqual(result["originalFailureExitCode"],139)

    def test_windows_escaped_backslashes_and_outer_quotes_match_real_diagnostic_shape(self):
        request=self.request("windows-x64")
        tool=Path(r"D:\sdk\third_party\llvm\bin\llc.exe")
        original=Path(r"C:\Users\user\Temp\cangjie-tmp-x\yjson.opt.bc")
        argv=[str(tool),str(original),*FLAGS["windows-x64"],
              r"C:\Users\user\Temp\cangjie-tmp-x\yjson.o"]
        line='error: "'+" ".join('"'+part.replace('\\','\\\\')+'"' for part in argv)+' ": command failed with exit code 3221225501 (use -V to see invocation)'
        result=observed_profile(replace(request,tool=tool,original_bitcode_path=original,build_log=line))
        self.assertEqual(result["originalFailureExitCode"],3221225501)
        self.assertEqual(result["originalFlags"],list(FLAGS["windows-x64"]))

    def test_sdk_or_ir_identity_drift_stops_before_launch(self):
        for field in ["expected_tool_sha256","expected_bitcode_sha256"]:
            runner=Mock()
            with self.assertRaises(ValueError):trace_once(replace(self.request(),**{field:"0"*64}),runner)
            runner.assert_not_called()

    def test_exclusive_directory_prevents_second_backend_attempt(self):
        request=self.request();runner=Mock(side_effect=self.runner)
        trace_once(request,runner)
        with self.assertRaises(FileExistsError):trace_once(request,runner)
        self.assertEqual(runner.call_count,1)

    def test_timeout_is_not_retried_or_reported_as_a_child_exit_code(self):
        runner=Mock(side_effect=subprocess.TimeoutExpired("llc",600))
        result=trace_once(self.request(),runner)
        self.assertTrue(result["timedOut"]);self.assertIsNone(result["exitCode"])
        self.assertEqual(result["backendInvocations"],1);runner.assert_called_once()

    def test_spawn_failure_reports_zero_actual_backend_invocations(self):
        runner=Mock(side_effect=OSError("synthetic launch refusal"))
        result=trace_once(self.request(),runner)
        self.assertEqual(result["backendAttempts"],1);self.assertEqual(result["backendInvocations"],0)
        self.assertIn("launch refusal",result["launchError"]);runner.assert_called_once()

    def test_unparsed_later_execution_does_not_misidentify_the_previous_function(self):
        path=self.root/"stderr"
        path.write_text("Executing Pass 'First' on Function '_CNsafe'...\n"
                        "Executing Pass 'Module pass' on Module 'private module'...\n")
        result=observations(path)
        self.assertIsNone(result["lastRecordedExecution"])
        self.assertEqual(result["unparsedExecutionLines"],1)

    def test_large_trace_is_withheld_without_loading_or_parsing_it(self):
        path=self.root/"stderr"
        with path.open("wb") as stream:stream.truncate(128*1024*1024+1)
        self.assertEqual(observations(path)["status"],"TRACE_TOO_LARGE")

    def test_controller_preserves_original_product_exit_if_trace_unavailable(self):
        source=self.root/"source";source.mkdir();output=self.root/"output";output.mkdir()
        attempt=Attempt(source,output,"windows-x64")
        attempt.exit_code=9;attempt.evidence["processExitCode"]=9
        attempt.build_log="llc yjson.opt.bc command failed with exit code 139"
        attempt.backend_observation(subprocess.CompletedProcess([],9),self.root,
                                    {"retained":"retained.opt.bc","sha256":sha(self.bc),"sourceRelative":"yjson.opt.bc"})
        self.assertEqual(attempt.exit_code,9);self.assertEqual(attempt.evidence["processExitCode"],9)
        self.assertEqual(attempt.evidence["backendTrace"]["backendInvocations"],0)


if __name__=="__main__":unittest.main()
