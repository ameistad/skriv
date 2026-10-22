#!/usr/bin/env python3
"""Compare headless Neovim file loading/navigation with Skriv's identical fixtures.

This isolates file operations after startup, not visible GUI readiness. Neovim
runs without user configuration, swap, persistent undo, plugins or highlighting.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import time

from benchmark import summarize

LUA = r'''
local input, output, shape, repetitions = unpack(arg)
local uv = vim.uv
local function measure(work)
  local start = uv.hrtime()
  work()
  return (uv.hrtime() - start) / 1000000
end
vim.o.swapfile = false
vim.o.undofile = false
vim.o.wrap = false
vim.cmd('syntax off')
vim.cmd('filetype off')
local result = {memory = {baselineResidentBytes = uv.resident_set_memory()}, timings = {}}
result.timings.loadMilliseconds = measure(function() vim.cmd.edit(vim.fn.fnameescape(input)) end)
assert(vim.api.nvim_buf_line_count(0) == (shape == 'singleLine' and 1 or tonumber(repetitions)))
result.memory.loadedResidentBytes = uv.resident_set_memory()
result.timings.firstMotionMilliseconds = measure(function() vim.cmd('normal! l') end)
assert(vim.api.nvim_win_get_cursor(0)[2] == (shape == 'denseLines' and 0 or 1))
result.timings.lastLineJumpMilliseconds = measure(function() vim.cmd('normal! G') end)
assert(vim.api.nvim_win_get_cursor(0)[1] == vim.api.nvim_buf_line_count(0))
result.memory.afterMotionResidentBytes = uv.resident_set_memory()
vim.fn.writefile({vim.json.encode(result)}, output)
vim.cmd('qa!')
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error('--runs must be positive')
    workloads = [('unicode', 100_000), ('unicode', 1_000_000),
                 ('singleLine', 10_000_000), ('denseLines', 1_000_000)]
    units = {'unicode': 'En norsk notatlinje: blåbær, øl, ål, ærlig arbeid og 👩🏽‍💻.\n',
             'singleLine': 'a', 'denseLines': 'a\n'}
    reports = []
    startup = []
    with tempfile.TemporaryDirectory(prefix='skriv-neovim-') as directory:
        work = Path(directory)
        script = work / 'benchmark.lua'
        script.write_text(LUA)
        for _ in range(args.runs):
            start = time.perf_counter()
            subprocess.run(['nvim', '--headless', '-u', 'NONE', '-i', 'NONE', '--noplugin',
                            '-n', '+qa'], check=True, capture_output=True, timeout=30)
            startup.append((time.perf_counter() - start) * 1000)
        for run in range(args.runs):
            for shape, repetitions in workloads:
                source = work / 'input.txt'
                digest = hashlib.sha256()
                unit = units[shape].encode()
                block = unit * 1000
                with source.open('wb') as file:
                    for _ in range(repetitions // 1000):
                        file.write(block)
                        digest.update(block)
                output = work / 'result.json'
                result = subprocess.run(['/usr/bin/time', '-l', 'nvim', '--headless', '-u', 'NONE',
                                         '-i', 'NONE', '--noplugin', '-n', '-l', str(script),
                                         str(source), str(output), shape, str(repetitions)],
                                        check=False, capture_output=True, text=True, timeout=300)
                if result.returncode:
                    raise RuntimeError(result.stderr)
                report = json.loads(output.read_text())
                peak = re.search(r'(\d+)\s+maximum resident set size', result.stderr)
                if not peak:
                    raise RuntimeError('Missing macOS time peak RSS measurement')
                report.update(shape=shape, repetitions=repetitions, run=run,
                              sha256=digest.hexdigest(), utf8Bytes=len(unit) * repetitions)
                report['memory']['peakResidentBytes'] = int(peak[1])
                reports.append(report)
                print(json.dumps(report), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({
        'metadata': {'recordedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                     'os': platform.platform(),
                     'neovim': subprocess.check_output(['nvim', '--version'], text=True).splitlines()[0],
                     'startupDefinition': 'fresh empty headless process through immediate exit; no file load',
                     'configuration': 'No config/plugins/swap/persistent undo/highlighting; wrap disabled; headless'},
        'emptyProcessMilliseconds': startup, 'emptyProcessSummary': summarize(startup),
        'workloads': reports}, indent=2) + '\n')


if __name__ == '__main__':
    main()
