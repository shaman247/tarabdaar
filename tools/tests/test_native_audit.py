"""The numerical audit must build fresh inputs and fail closed on compiler errors."""

from contextlib import redirect_stderr
import hashlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "native_audit", ROOT / "tools/live_research_port/audit.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class NativeAuditBuildTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        for relative in audit.NATIVE_INPUTS + audit.MODEL_INPUTS:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(str(relative))
        self.builds = []
        platform = patch.object(audit.platform, "platform", return_value="macOS fixture")
        platform.start()
        self.addCleanup(platform.stop)

    def compiler(self, command, **kwargs):
        if "--version" in command:
            return subprocess.CompletedProcess(command, 0, stdout="Fixture clang\n")
        if "--show-sdk-path" in command:
            return subprocess.CompletedProcess(command, 0, stdout="/fixture/SDK\n")
        work = kwargs["cwd"]
        self.builds.append(work)
        # Stand in for compilation: the bytes must come from this run's snapshot.
        output = b"".join((work / relative).read_bytes() for relative in audit.NATIVE_INPUTS)
        (work / "native-fit.dylib").write_bytes(output)
        return subprocess.CompletedProcess(command, 0)

    @patch.object(audit.sys, "platform", "darwin")
    def test_each_run_builds_current_inputs_in_an_isolated_snapshot(self):
        source = self.root / audit.NATIVE_INPUTS[0]
        with patch.object(audit.subprocess, "run", side_effect=self.compiler), \
                redirect_stderr(io.StringIO()):
            with audit.native_inputs(self.root) as (library, resources, first):
                first_library = library.read_bytes()
                source.write_text("changed current source")
                # Editing the checkout cannot change a library/model already under audit.
                self.assertNotEqual((self.builds[-1] / audit.NATIVE_INPUTS[0]).read_bytes(),
                                    source.read_bytes())
                self.assertTrue((resources / "sarangi_fit.json").is_file())
            self.assertFalse(library.exists())
            with audit.native_inputs(self.root) as (library, _, second):
                self.assertNotEqual(first_library, library.read_bytes())
                self.assertEqual(second["source_sha256"][str(audit.NATIVE_INPUTS[0])],
                                 hashlib.sha256(source.read_bytes()).hexdigest())
                self.assertNotEqual(first["library_sha256"], second["library_sha256"])
        self.assertEqual(len(self.builds), 2)
        self.assertNotEqual(self.builds[0], self.builds[1])
        self.assertTrue(all(not work.exists() for work in self.builds))

    @patch.object(audit.sys, "platform", "darwin")
    def test_failed_compile_never_loads_a_previous_library(self):
        def fail_build(command, **kwargs):
            result = self.compiler(command, **kwargs)
            if "cwd" in kwargs:
                raise subprocess.CalledProcessError(1, command)
            return result

        with patch.object(audit.subprocess, "run", side_effect=fail_build), \
                redirect_stderr(io.StringIO()):
            with self.assertRaises(subprocess.CalledProcessError):
                with audit.native_inputs(self.root):
                    self.fail("A failed build must not yield an audit library")
        self.assertEqual(len(self.builds), 1)
        self.assertFalse(self.builds[0].exists())


if __name__ == "__main__":
    unittest.main()
