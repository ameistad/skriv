#!/usr/bin/env python3
"""Exercise the launcher with a temporary bundle and a recording `open` command."""

import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


LAUNCHER = Path(__file__).resolve().with_name("skriv")


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="skriv cli ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / "Skriv App.app"
        self.launcher = self.app / "Contents/Resources/bin/skriv"
        self.launcher.parent.mkdir(parents=True)
        shutil.copy2(LAUNCHER, self.launcher)
        executable = self.app / "Contents/MacOS/Skriv"
        executable.parent.mkdir()
        executable.touch(mode=0o755)
        (self.app / "Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleShortVersionString": "1.2.3"})
        )
        self.fake_bin = self.root / "tools"
        self.fake_bin.mkdir()
        fake_open = self.fake_bin / "open"
        fake_open.write_text('#!/bin/bash\nprintf "%s\\0" "$@" > "$OPEN_LOG"\nexit "${OPEN_STATUS:-0}"\n')
        fake_open.chmod(0o755)
        self.log = self.root / "opened"
        self.env = dict(os.environ, HOME=str(self.root),
                        PATH=f"{self.fake_bin}:/usr/bin:/bin", OPEN_LOG=str(self.log))

    def run_cli(self, *arguments, launcher=None):
        return subprocess.run([str(launcher or self.launcher), *map(str, arguments)],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def opened_arguments(self):
        return self.log.read_bytes().decode().rstrip("\0").split("\0")

    def test_no_arguments_focuses_own_bundle(self):
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertEqual(self.opened_arguments(), ["-a", str(self.app)])

    def test_multiple_paths_are_literal_and_relative_to_callers_directory(self):
        names = ["notes with spaces.txt", "æøå\nnotes.txt", "$(touch BAD);'quote.txt"]
        for name in names:
            (self.root / name).touch()
        absolute = self.root / "absolute.txt"
        absolute.touch()
        result = self.run_cli(*names, absolute)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.opened_arguments(),
                         ["-a", str(self.app), "--"] + [str(self.root / name) for name in names] + [str(absolute)])
        self.assertFalse((self.root / "BAD").exists())

    def test_dash_filename_requires_end_of_options(self):
        (self.root / "--help").touch()
        result = self.run_cli("--", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.opened_arguments()[-1], str(self.root / "--help"))

    def test_invalid_batch_does_not_open_any_files(self):
        (self.root / "valid.txt").touch()
        for invalid in ["missing.txt", str(self.root), "--unknown", ""]:
            with self.subTest(invalid=invalid):
                result = self.run_cli("valid.txt", invalid)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("skriv:", result.stderr)
                self.assertFalse(self.log.exists())

    def test_install_and_launch_through_relative_symlink_chain(self):
        result = self.run_cli("--install")
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = self.root / ".local/bin/skriv"
        self.assertEqual(installed.resolve(), self.launcher.resolve())
        self.assertIn("Already installed", self.run_cli("--install").stdout)
        alias = self.root / "alias"
        alias.symlink_to(".local/bin/skriv")
        (self.root / "note.txt").touch()
        result = self.run_cli("note.txt", launcher=alias)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.opened_arguments(), ["-a", str(self.app), "--", str(self.root / "note.txt")])

    def test_install_refuses_existing_files_directories_and_broken_links(self):
        for kind in ["file", "directory", "broken-link"]:
            with self.subTest(kind=kind):
                directory = self.root / kind
                directory.mkdir()
                destination = directory / "skriv"
                if kind == "file":
                    destination.write_text("keep me")
                elif kind == "directory":
                    destination.mkdir()
                else:
                    destination.symlink_to("missing")
                result = self.run_cli("--install", directory)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Refusing to replace", result.stderr)
                if kind == "file":
                    self.assertEqual(destination.read_text(), "keep me")
                elif kind == "directory":
                    self.assertTrue(destination.is_dir())
                else:
                    self.assertEqual(os.readlink(destination), "missing")

    def test_help_version_and_missing_app(self):
        self.assertEqual(self.run_cli("--version").stdout, "Skriv 1.2.3\n")
        (self.app / "Contents/MacOS/Skriv").unlink()
        self.assertEqual(self.run_cli("--help").returncode, 0)
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Skriv.app was not found", result.stderr)
        self.assertFalse(self.log.exists())

    def test_launch_failure_is_returned(self):
        self.env["OPEN_STATUS"] = "7"
        self.assertEqual(self.run_cli().returncode, 7)


if __name__ == "__main__":
    unittest.main()
