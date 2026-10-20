#!/usr/bin/env python3
"""Optional differential check of Skriv's supported native Vim command subset.

Requires Swift and Neovim; does not run Neovim's user configuration or use the
system clipboard. Run from anywhere: python3 scripts/check-vim-conformance.py

The oracle enables 'startofline', matching Skriv's first-nonblank behavior for
G/gg and line deletions. Fixtures are ASCII: Skriv deliberately edits complete
extended graphemes, while Neovim's character operations can split emoji.

We compare resulting text, normal-mode cursor offsets, and register contents
and types. Insert-mode caret offsets are excluded: feedkeys() exits insert mode
when its input is exhausted, whereas Skriv leaves the user in insert mode.
Typed non-remapped input also continues after a blocked Visual motion, unlike
:normal!, which aborts the rest of that sequence on a motion error.
This corpus validates the supported subset, not complete Vim compatibility.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
DOCUMENTS = [
    "one two three", "one\ntwo\nthree", "  one\n  two\nthree",
    "one\n\nthree", "one\n", "a b c", "one, two!", "one  \ntwo", "\n", "",
]
COMMANDS = [
    "h", "j", "k", "l", "0", "^", "$", "gg", "G", "w", "b", "e", "W", "B", "E",
    "2w", "2e", "x", "X", "dd", "cc", "yy", "dw", "cw", "yw", "db", "yb", "de",
    "ce", "d$", "dj", "dk", "dG", "dgg", "2dd", "d2w", "c2w", "y2w", "D", "C",
    "Y", "yj", "yk", "yG", "ygg", "d0", "d^", "dh", "dl", "d2j", "3dd", "2cc",
    "2yy", "yyp", "yyP", "ylp", "ylP",
    "vy", "vly", "vhy", "vwy", "vey", "vby", "v0y", "v$y", "vjy", "vky",
    "vggd", "vGd", "v2ld", "vhd", "vjc", "vody", "Vd", "Vjd", "Vkd",
    "Vy", "Vjy", "Vky", "Vc", "Vjc", "vVjd", "Vvld",
]
ORACLE = r'''
set nocompatible nomore startofline
let cases = json_decode(join(readfile('cases.json'), "\n"))
let results = []
for item in cases
  enew!
  call setline(1, split(item.text, "\n", 1))
  call setreg('"', '', 'v')
  let prefix = strpart(item.text, 0, item.caret)
  let parts = split(prefix, "\n", 1)
  call cursor(len(parts), strlen(parts[-1]) + 1)
  call feedkeys(item.keys, 'nxt')
  let before = line('.') > 1 ? join(getline(1, line('.') - 1), "\n") . "\n" : ''
  call add(results, {'text': join(getline(1, '$'), "\n"), 'caret': strlen(before) + col('.') - 1, 'reg': getreg('"'), 'type': getregtype('"')})
endfor
call writefile([json_encode(results)], 'neovim.json')
qa!
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--nvim", help="Path to Neovim (otherwise PATH or the standard Homebrew location).")
    args = parser.parse_args()
    nvim = args.nvim or shutil.which("nvim")
    if not nvim and Path("/opt/homebrew/bin/nvim").is_file():
        nvim = "/opt/homebrew/bin/nvim"
    swiftc = shutil.which("swiftc")
    if not nvim or not swiftc:
        parser.error("This optional check requires both swiftc and Neovim; pass --nvim if needed.")
    nvim = str(Path(nvim).resolve())
    cases = [
        {"text": text, "caret": caret, "keys": keys}
        for text in DOCUMENTS
        for caret in sorted({0, max(0, len(text) // 2), max(0, len(text) - 1)})
        for keys in COMMANDS
    ]
    with tempfile.TemporaryDirectory(prefix="skriv-vim-conformance-") as directory:
        work = Path(directory)
        (work / "cases.json").write_text(json.dumps(cases), encoding="utf-8")
        (work / "oracle.vim").write_text(ORACLE, encoding="utf-8")
        shutil.copyfile(ROOT / "scripts/fixtures/VimConformanceMain.swift", work / "main.swift")
        subprocess.run([
            swiftc, str(ROOT / "Sources/SkrivCore/VimEngine.swift"), str(work / "main.swift"),
            "-o", str(work / "engine"),
        ], check=True)
        native = json.loads(subprocess.check_output([str(work / "engine"), str(work / "cases.json")]))
        subprocess.run(
            [nvim, "--clean", "-n", "--headless", "-S", "oracle.vim"],
            cwd=work, check=True, capture_output=True, timeout=30,
        )
        expected = json.loads((work / "neovim.json").read_text(encoding="utf-8"))
        if len(native) != len(cases) or len(expected) != len(cases):
            raise RuntimeError("Oracle returned an incomplete result set")
        failures = []
        for case, actual, oracle in zip(cases, native, expected):
            fields = ["text", "reg", "type"]
            if "c" not in case["keys"] and case["keys"] != "C":
                fields.append("caret")
            mismatches = [field for field in fields if actual[field] != oracle[field]]
            if mismatches:
                failures.append({"case": case, "fields": mismatches, "native": actual, "neovim": oracle})
        print(f"{len(cases)} cases; {len(failures)} differences (Neovim with startofline).")
        for failure in failures:
            print(json.dumps(failure, ensure_ascii=False))
        return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.SubprocessError, RuntimeError) as error:
        print(f"Conformance check failed: {error}", file=sys.stderr)
        sys.exit(1)
