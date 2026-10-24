#!/usr/bin/env python3
"""Exercise the launcher with a temporary bundle and a recording `open` command."""

import os
from pathlib import Path
import plistlib
import pty
import select
import shutil
import subprocess
import tempfile
import time
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
        self.completion = self.app / "Contents/Resources/completions/_skriv"
        self.completion.parent.mkdir()
        shutil.copy2(LAUNCHER.with_name("_skriv"), self.completion)
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

    def test_install_completion_default_custom_and_repeat(self):
        for directory in [None, self.root / "custom completions"]:
            arguments = [] if directory is None else [directory]
            result = self.run_cli("--install-completion", *arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
            destination = (directory or self.root / ".local/share/zsh/site-functions") / "_skriv"
            self.assertEqual(destination.resolve(), self.completion.resolve())
            self.assertIn("Already installed", self.run_cli("--install-completion", *arguments).stdout)
            self.assertFalse((self.root / ".zshrc").exists())
            self.assertFalse(self.log.exists())

    def test_completion_install_refuses_conflicts_and_missing_bundle_rule(self):
        for kind in ["file", "directory", "broken-link"]:
            directory = self.root / kind
            directory.mkdir()
            destination = directory / "_skriv"
            if kind == "file":
                destination.write_text("keep me")
            elif kind == "directory":
                destination.mkdir()
            else:
                destination.symlink_to("missing")
            result = self.run_cli("--install-completion", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing to replace", result.stderr)
            if kind == "file":
                self.assertEqual(destination.read_text(), "keep me")
            elif kind == "directory":
                self.assertTrue(destination.is_dir())
            else:
                self.assertEqual(os.readlink(destination), "missing")
        self.completion.unlink()
        self.assertNotEqual(self.run_cli("--install-completion").returncode, 0)
        self.assertNotEqual(self.run_cli("--install-completion", "one", "two").returncode, 0)

    @unittest.skipUnless(shutil.which("zsh"), "zsh is required for completion tests")
    def test_real_zsh_tab_completion(self):
        (self.root / "note.txt").touch()
        (self.root / "notes-dir").mkdir()
        (self.root / "notes-dir/nested.txt").touch()
        (self.root / "space name.txt").touch()
        (self.root / "file-link").symlink_to("note.txt")
        (self.root / "dir-link").symlink_to("notes-dir")
        (self.root / "--dash.txt").touch()
        (self.root / ".hidden.txt").touch()
        capture = self.root / "capture"
        (self.root / ".zshrc").write_text('''
fpath=("$COMPLETION_DIRECTORY" $fpath)
autoload -Uz compinit
compinit -D
_capture() { print -rn -- "$BUFFER" > "$CAPTURE"; BUFFER=""; zle redisplay; }
zle -N _capture
bindkey '^X' _capture
bindkey '^I' complete-word
PS1='READY> '
''')
        master, slave = pty.openpty()
        process = subprocess.Popen(
            [shutil.which("zsh"), "-d", "-i"], stdin=slave, stdout=slave, stderr=slave,
            cwd=self.root, env={**self.env, "ZDOTDIR": str(self.root), "TERM": "xterm",
                               "COMPLETION_DIRECTORY": str(self.completion.parent),
                               "CAPTURE": str(capture)})
        os.close(slave)

        def wait_for(predicate):
            output = b""
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.05)[0]:
                    output += os.read(master, 65536)
                if predicate(output):
                    return
            self.fail(f"Timed out waiting for zsh: {output!r}")

        try:
            wait_for(lambda output: b"READY> " in output)
            cases = {
                "skriv no": "skriv note.txt ",
                "skriv notes-d": "skriv notes-d",
                "skriv notes-dir/ne": "skriv notes-dir/nested.txt ",
                "skriv sp": "skriv space\\ name.txt ",
                "skriv file-l": "skriv file-link ",
                "skriv dir-l": "skriv dir-l",
                "skriv note.txt sp": "skriv note.txt space\\ name.txt ",
                "skriv -- --da": "skriv -- --dash.txt ",
                "skriv .hi": "skriv .hidden.txt ",
                "skriv --install notes-d": "skriv --install notes-dir/",
                "skriv --install-completion notes-d": "skriv --install-completion notes-dir/",
                "skriv --ver": "skriv --version ",
                "cat notes-d": "cat notes-dir/",
            }
            for line, expected in cases.items():
                with self.subTest(line=line):
                    capture.unlink(missing_ok=True)
                    os.write(master, (line + "\t\x18").encode())
                    wait_for(lambda output: capture.exists() and capture.stat().st_size > 0)
                    self.assertEqual(capture.read_text(), expected)
        finally:
            process.kill()
            process.wait(timeout=5)
            os.close(master)

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
