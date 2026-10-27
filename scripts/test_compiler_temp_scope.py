"""CJC temporary namespace boundaries; mocked events are not native proof."""
from __future__ import annotations
from contextlib import ExitStack
import hashlib
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock,patch
import full_gate_codegen_capture as full
import ir_events
from ir_hardlinks import CaptureMissed,IrLinks


class CompilerTemporaryScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.compiler=self.root/'temporary';self.compiler.mkdir()
        self.retained=self.root/'retained';self.retained.mkdir()
        self.tool=self.root/'cjc';self.tool.write_bytes(b'fixture cangjie-tmp- and .opt.bc')
        self.attempt=object.__new__(full.FullGateAttempt)
        self.attempt.temporary=self.compiler;self.attempt.pipeline_retained=self.retained
        self.attempt.selected='macos-arm64';self.attempt.tools={'cjc':self.tool}
        self.attempt.evidence={'toolsBefore':{'cjc':{'sha256':hashlib.sha256(self.tool.read_bytes()).hexdigest(),'size':self.tool.stat().st_size}}}

    def links(self):return self.attempt.retention_links()

    def directory(self,name='cangjie-tmp-fixture'):
        path=self.compiler/name;path.mkdir();return path

    def observe(self,links,deny=None,late_create=None):
        real_open=os.open;opened=[];root_fd=[]
        def opening(path,flags,*args,**kwargs):
            opened.append(Path(path))
            if deny is not None and Path(path)==deny:raise PermissionError(13,'fixture directory denied')
            fd=real_open(path,flags,*args,**kwargs)
            if Path(path)==self.compiler:root_fd.append(fd)
            return fd
        queue=Mock();backend=None;late=[False]
        def control(changes,*args):
            if changes is not None:return []
            if late_create is not None and not late[0]:
                late[0]=True;late_create()
                return [SimpleNamespace(ident=root_fd[0],flags=0,fflags=1,data=0)]
            return [SimpleNamespace(ident=backend.reader.fileno(),flags=0,fflags=0,data=0)]
        queue.control.side_effect=control
        constants={'KQ_FILTER_READ':1,'KQ_FILTER_VNODE':2,'KQ_EV_ADD':1,'KQ_EV_CLEAR':2,
                   'KQ_NOTE_WRITE':1,'KQ_NOTE_DELETE':2,'KQ_NOTE_RENAME':4,'KQ_EV_ERROR':8}
        with ExitStack() as stack:
            for key,value in constants.items():stack.enter_context(patch.object(ir_events.select,key,value,create=True))
            stack.enter_context(patch.object(ir_events.select,'kqueue',return_value=queue,create=True))
            stack.enter_context(patch.object(ir_events.select,'kevent',return_value=object(),create=True))
            stack.enter_context(patch.object(ir_events.os,'open',side_effect=opening))
            backend=ir_events.MacEvents(links);backend.run(Mock())
        return opened

    def test_unrelated_denied_directory_is_neither_subscribed_nor_scanned(self):
        unrelated=self.directory('system-service');directory=self.directory();(directory/'yjson.opt.bc').write_bytes(b'IR')
        links=self.links();real_scandir=os.scandir
        def scanning(path):
            if Path(path)==unrelated:raise AssertionError('unrelated directory was scanned')
            return real_scandir(path)
        with patch.object(os,'scandir',side_effect=scanning):opened=self.observe(links,deny=unrelated)
        self.assertIn(self.compiler,opened);self.assertIn(directory,opened);self.assertNotIn(unrelated,opened)
        self.assertEqual(len(links.entries),1)

    def test_compiler_namespace_enumeration_permission_failure_is_not_skipped(self):
        directory=self.directory();links=self.links();real_scandir=os.scandir
        def scanning(path):
            if Path(path)==directory:raise PermissionError(13,'fixture compiler directory denied')
            return real_scandir(path)
        with patch.object(os,'scandir',side_effect=scanning),self.assertRaises(PermissionError):links.scan()

    def test_compiler_namespace_subscription_permission_failure_is_not_skipped(self):
        directory=self.directory()
        with self.assertRaises(PermissionError):self.observe(self.links(),deny=directory)

    def test_symbolic_link_in_compiler_namespace_is_refused(self):
        (self.compiler/'cangjie-tmp-link').symlink_to(self.retained,target_is_directory=True)
        with self.assertRaises(CaptureMissed):self.links().scan()

    def test_nested_symbolic_link_in_compiler_namespace_is_refused(self):
        directory=self.directory();(directory/'nested').symlink_to(self.retained,target_is_directory=True)
        with self.assertRaises(CaptureMissed):self.links().scan()

    def test_matching_regular_file_is_not_treated_as_a_compiler_directory(self):
        (self.compiler/'cangjie-tmp-file').write_bytes(b'fixture')
        with self.assertRaises(CaptureMissed):self.links().scan()

    def test_dependency_ir_at_temp_root_is_protocol_drift(self):
        (self.compiler/'yjson.opt.bc').write_bytes(b'IR')
        with self.assertRaises(CaptureMissed):self.links().scan()

    def test_compiler_outputs_are_linked_but_other_package_is_not(self):
        directory=self.directory();files=[]
        for name in ['yjson.opt.bc','markdown.opt.bc','cjdoc.opt.bc']:
            path=directory/name;path.write_bytes(name.encode());files.append(path)
        links=self.links();links.scan()
        for path in files:path.unlink()
        directory.rmdir();rows=links.finish()
        self.assertEqual({r['name'] for r in rows},{'yjson.opt.bc','markdown.opt.bc'})
        self.assertTrue(all(r['linkCountAfterCompiler']==1 and not r['originalPresent'] for r in rows))

    def test_root_event_discovers_compiler_directory_created_after_startup(self):
        paths=[]
        def create():
            directory=self.directory();path=directory/'yjson.opt.bc';path.write_bytes(b'IR');paths.extend([path,directory])
        links=self.links();opened=self.observe(links,late_create=create)
        self.assertIn(self.compiler,opened);self.assertIn(paths[1],opened)
        paths[0].unlink();paths[1].rmdir();self.assertEqual(len(links.finish()),1)

    def test_directory_removed_during_enumeration_cannot_create_success_without_ir(self):
        directory=self.directory();links=self.links();real_walk=os.walk
        def walking(top,**options):
            directory.rmdir()
            return real_walk(top,**options)
        with patch.object(os,'walk',side_effect=walking):links.scan()
        with self.assertRaises(CaptureMissed):links.finish()

    def test_default_links_keep_the_original_unrestricted_scope(self):
        directory=self.directory('other');(directory/'fixture.opt.bc').write_bytes(b'IR')
        links=IrLinks(self.compiler,self.retained);links.scan();self.assertEqual(len(links.entries),1)

    def test_missing_sdk_prefix_is_refused_before_observation(self):
        self.tool.write_bytes(b'fixture .opt.bc')
        self.attempt.evidence['toolsBefore']['cjc']['sha256']=hashlib.sha256(self.tool.read_bytes()).hexdigest()
        self.attempt.evidence['toolsBefore']['cjc']['size']=self.tool.stat().st_size
        with self.assertRaises(ValueError):self.links()

    def test_changed_sdk_bytes_are_refused_before_observation(self):
        self.tool.write_bytes(b'changed fixture cangjie-tmp- and .opt.bc')
        with self.assertRaises(ValueError):self.links()


if __name__=='__main__':unittest.main()
