"""Two isolated showcase branches with first-error subprocess cancellation."""
from __future__ import annotations

from concurrent.futures import CancelledError, ThreadPoolExecutor
import os
import signal
import subprocess
from threading import RLock


class BranchRunner:
    """A private subprocess facade; never patch the shared subprocess module.

    The API and PocketKit branches own separate output roots. Only cancellation
    state and their live child handles are shared, under one lock. On POSIX each
    command owns a process group so cancellation also stops native compilers.
    """

    def __init__(self) -> None:
        # Reentrant: the signal handler runs on whichever thread received the
        # signal (including the main thread inside `with self._lock`), and a
        # non-reentrant lock would deadlock there instead of cancelling.
        self._lock = RLock()
        self._processes: set[subprocess.Popen] = set()
        self._error: BaseException | None = None
        self._traceback = None
        # Set by the signal handler and by `fail()`; `run()` refuses to launch once
        # it is set.
        self.cancelled = False
        # A cancelled or SIGTERMed stage runs no `finally` and no `fail()`, and each
        # command owns its own POSIX session here, so the active cjdoc/compiler
        # groups would outlive their coordinator and keep holding pipes and
        # temporary outputs. Install handlers that kill every registered group
        # before the default disposition runs.
        self._previous_handlers: dict[int, object] = {}
        for signum in (signal.SIGTERM, signal.SIGINT):
            try:
                self._previous_handlers[signum] = signal.signal(signum, self._on_signal)
            except (ValueError, OSError):
                # Not the main thread, or the platform refuses the handler; the
                # explicit `pair()` cleanup still covers ordinary failures.
                pass

    def _on_signal(self, signum, frame) -> None:
        with self._lock:
            # Mark cancellation under the same lock `run()` checks, so a worker that
            # is between two commands cannot slip in a new detached session after the
            # registered groups were killed but before this handler re-raises.
            self.cancelled = True
            for process in list(self._processes):
                self._kill(process)
        previous = self._previous_handlers.get(signum, signal.SIG_DFL)
        if previous == signal.SIG_IGN:
            # Python preserves an inherited ignored SIGINT (a background job, for
            # example). Turning that into a fatal default here would kill a process
            # whose environment explicitly asked to ignore the signal, so stop after
            # the group cleanup and leave the disposition ignored.
            return
        if callable(previous):
            previous(signum, frame)
            return
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    def __getattr__(self, name):
        # reproduce.py also uses subprocess.CalledProcessError. Give its private
        # module the usual constants/exceptions without changing archived bytes.
        return getattr(subprocess, name)

    @staticmethod
    def _kill(process: subprocess.Popen) -> None:
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            elif os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               check=False)
                if process.poll() is None:
                    process.kill()
            else:
                process.kill()
        except OSError:
            # A process may exit between registration and cancellation.
            pass

    def fail(self, error: BaseException) -> None:
        with self._lock:
            if self._error is not None:
                return
            self._error = error
            self.cancelled = True
            self._traceback = error.__traceback__
            for process in self._processes:
                self._kill(process)

    def run(self, command, *, check=False, capture_output=False, timeout=None, **kwargs):
        """The subprocess.run surface used by these two generation branches."""
        if capture_output:
            if kwargs.get("stdout") is not None or kwargs.get("stderr") is not None:
                raise ValueError("stdout/stderr cannot be combined with capture_output")
            kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        with self._lock:
            if self._error is not None or self.cancelled:
                raise CancelledError("showcase sibling branch failed")
            process = subprocess.Popen(command, start_new_session=os.name == "posix", **kwargs)
            self._processes.add(process)
        try:
            try:
                stdout, stderr = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                self._kill(process)
                process.communicate()
                raise
            result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
            if check:
                result.check_returncode()
            return result
        finally:
            with self._lock:
                self._processes.remove(process)

    def pair(self, api, pocketkit):
        """Run exactly two workers; join before any publication or re-raise."""
        def guarded(branch):
            try:
                return branch(self)
            except BaseException as error:
                self.fail(error)
                raise

        try:
            with ThreadPoolExecutor(max_workers=2, thread_name_prefix="showcase") as executor:
                api_result = executor.submit(guarded, api)
                pocketkit_result = executor.submit(guarded, pocketkit)
                # Failure is registered and kills siblings inside guarded(), not
                # by this wait order or by diagnostic phase timing.
                api_result.result()
                result = pocketkit_result.result()
        except BaseException as error:
            self.fail(error)
            assert self._error is not None
            raise self._error.with_traceback(self._traceback)
        return result
