"""Instrument warm-sample lifetime and timing independently of real archive runs."""

from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import measure_sdk_install as measure


class WarmMeasurementTests(unittest.TestCase):
    def test_measures_preparation_and_cleanup_but_excludes_identity_check(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory).resolve()
            paths = []
            clock = [0.0]
            real_temporary_directory = tempfile.TemporaryDirectory

            class ObservedScratch(real_temporary_directory):
                def __exit__(self, *exc_info):
                    super().__exit__(*exc_info)
                    clock[0] += 0.02

            def prepare(scratch):
                self.assertEqual(scratch.parent, work)
                self.assertTrue(all(not previous.exists() for previous in paths))
                paths.append(scratch)
                sdk = scratch / "sdk"
                stdx = scratch / "stdx"
                sdk.mkdir()
                stdx.mkdir()
                clock[0] += 0.03
                return {"clock": measure.Clock(), "sdkRoot": str(sdk), "stdxRoot": str(stdx)}

            def observe(sdk, stdx):
                self.assertTrue(sdk.is_dir() and stdx.is_dir())
                clock[0] += 0.20
                return {"matched": True}

            with (patch.object(measure.tempfile, "TemporaryDirectory", ObservedScratch),
                  patch.object(measure.time, "perf_counter", side_effect=lambda: clock[0]),
                  patch.object(measure, "identity", side_effect=observe)):
                for _ in range(2):
                    sample = measure.measure_warm_sample(work, prepare, {"matched": True})
                    self.assertEqual(sample["totalMs"], 50.0)
                    self.assertEqual(list(work.iterdir()), [])

    def test_failure_removes_partial_extraction_before_next_sample(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory).resolve()

            def fail_during_preparation(scratch):
                (scratch / "partial-sdk").mkdir()
                raise OSError("interrupted extraction")

            with self.assertRaisesRegex(OSError, "interrupted extraction"):
                measure.measure_warm_sample(work, fail_during_preparation, {})
            self.assertEqual(list(work.iterdir()), [])
