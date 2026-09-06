#!/usr/bin/env python3
"""Exercise release packaging in isolated fixtures, never the real dist/release.

Swift, lipo, strip, and codesign are test doubles; macOS ditto, PlistBuddy, and shasum
run normally. This tests packaging policy, not compilation or code signing.
"""

import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile


SCRIPT_DIR = Path(__file__).resolve().parents[1]
STUB = """#!/usr/bin/python3
import os
from pathlib import Path
import sys

command = Path(sys.argv[0]).name
if command == "swift":
    args = sys.argv[1:]
    assert args[args.index("--arch") + 1] == "arm64"
    assert "-file-prefix-map" in args
    binary_dir = Path.cwd() / ".build" / "fake-arm64"
    if "--show-bin-path" in args:
        print(binary_dir)
    else:
        binary_dir.mkdir(parents=True, exist_ok=True)
        (binary_dir / "CodexTokenObserver").write_bytes(
            b"FAKE ARM64 EXECUTABLE|PRIVATE_DEBUG_PATH|" + os.fsencode(Path.cwd()))
elif command == "lipo":
    print(os.environ.get("OBSERVER_TEST_ARCH", "arm64"))
elif command == "strip":
    assert sys.argv[1] == "-S"
    executable = Path(sys.argv[2])
    executable.write_bytes(executable.read_bytes().split(b"|PRIVATE_DEBUG_PATH|")[0])
elif command == "codesign":
    if os.environ.get("OBSERVER_TEST_SIGN_FAIL"):
        sys.exit(1)
    executable = Path(sys.argv[-1]) / "Contents" / "MacOS" / "CodexTokenObserver"
    assert b"|PRIVATE_DEBUG_PATH|" not in executable.read_bytes(), "Strip must precede signing"
else:
    sys.exit(2)
"""


class PackageSmoke(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="observer-package-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "Project With Spaces"
        self.scripts = self.root / "desktop-observer"
        self.scripts.mkdir(parents=True)
        (self.root / "LICENSE").write_text("Fixture MIT license\n")
        (self.root / "PRIVACY.md").write_text("Fixture privacy policy\n")
        for name in ("build-app.sh", "package-release.sh"):
            shutil.copy2(SCRIPT_DIR / name, self.scripts / name)
        with (self.scripts / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleShortVersionString": "9.8.7"}, handle)
        self.package = self.root / "src" / "codex_token_counter"
        (self.package / "__pycache__").mkdir(parents=True)
        (self.package / "nested").mkdir()
        for relative, content in {
            "__init__.py": "# Safe source\n",
            "cli.py": "# Safe CLI\n",
            "nested/helper.py": "# Nested safe source\n",
            "__pycache__/cli.cpython-39.pyc": "private local source path",
            "token_counter.sqlite3": "private ledger",
            "auth.json": "private credential",
            ".env": "private environment",
            "debug.log": "private log",
        }.items():
            (self.package / relative).write_text(content)
        (self.root / "src" / "unrelated.py").write_text("# Not this package\n")
        stubs = self.root / "stubs"
        stubs.mkdir()
        for name in ("swift", "lipo", "strip", "codesign"):
            path = stubs / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(stubs) + os.pathsep + os.environ["PATH"])
        self.app = self.root / "dist" / "Codex Token Observer.app"
        self.release = self.root / "release"
        self.zip_name = "Codex Token Observer-9.8.7-macos-arm64.zip"

    def run_script(self, name, *arguments, success=True):
        result = subprocess.run(
            ["/bin/zsh", str(self.scripts / name), *arguments],
            env=self.env, text=True, capture_output=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def test_default_version_clean_sources_and_portable_checksum(self):
        self.run_script("package-release.sh")
        resources = self.app / "Contents" / "Resources"
        self.assertEqual((resources / "LICENSE").read_text(), "Fixture MIT license\n")
        self.assertEqual((resources / "PRIVACY.md").read_text(), "Fixture privacy policy\n")
        source = self.app / "Contents" / "Resources" / "counter" / "src"
        bundled_files = {
            str(path.relative_to(source)) for path in source.rglob("*") if path.is_file()
        }
        self.assertEqual(bundled_files, {
            "codex_token_counter/__init__.py", "codex_token_counter/cli.py",
            "codex_token_counter/nested/helper.py",
        })
        checksum = self.release / (self.zip_name + ".sha256")
        self.assertTrue(checksum.read_text().endswith("  " + self.zip_name + "\n"))
        self.assertNotIn(str(self.root), checksum.read_text())
        result = subprocess.run(
            ["shasum", "-a", "256", "-c", checksum.name],
            cwd=self.release, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(self.release / self.zip_name) as archive:
            executable = archive.read("Codex Token Observer.app/Contents/MacOS/CodexTokenObserver")
            self.assertNotIn(b"|PRIVATE_DEBUG_PATH|", executable)
            self.assertNotIn(os.fsencode(self.root), executable)
            for name in archive.namelist():
                self.assertNotIn("__pycache__", name)
                self.assertFalse(name.endswith((".pyc", ".sqlite3", ".json", ".env", ".log")), name)
        self.assertEqual(sorted(path.name for path in self.release.iterdir()),
                         [self.zip_name, self.zip_name + ".sha256"])

    def test_explicit_matching_version(self):
        self.run_script("package-release.sh", "9.8.7")
        self.assertTrue((self.release / self.zip_name).is_file())

    def test_mismatch_fails_before_build(self):
        self.run_script("package-release.sh", "0.1.0", success=False)
        self.assertFalse((self.scripts / ".build").exists())
        self.assertFalse(self.app.exists())

    def test_invalid_version_fails_before_build(self):
        self.run_script("package-release.sh", "../unsafe", success=False)
        self.assertFalse((self.scripts / ".build").exists())

    def test_existing_release_is_not_overwritten(self):
        self.run_script("package-release.sh")
        originals = {path.name: path.read_bytes() for path in self.release.iterdir()}
        self.run_script("package-release.sh", success=False)
        self.assertEqual(originals, {path.name: path.read_bytes() for path in self.release.iterdir()})

    def test_architecture_mismatch_preserves_existing_app(self):
        self.app.mkdir(parents=True)
        marker = self.app / "existing-app"
        marker.write_text("keep")
        self.env["OBSERVER_TEST_ARCH"] = "x86_64"
        self.run_script("build-app.sh", success=False)
        self.assertEqual(marker.read_text(), "keep")

    def test_signing_failure_preserves_app_and_cleans_staging(self):
        self.app.mkdir(parents=True)
        marker = self.app / "existing-app"
        marker.write_text("keep")
        self.env["OBSERVER_TEST_SIGN_FAIL"] = "1"
        self.run_script("package-release.sh", success=False)
        self.assertEqual(marker.read_text(), "keep")
        self.assertEqual(list(self.release.iterdir()), [])
        self.assertEqual(list(self.app.parent.iterdir()), [self.app])


if __name__ == "__main__":
    unittest.main(verbosity=2)
