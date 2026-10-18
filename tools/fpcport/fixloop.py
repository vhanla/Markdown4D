#!/usr/bin/env python3
"""
fixloop.py -- correct fpcport.py's type guesses using FPC's own diagnostics.

fpcport.py cannot infer types: FPC has no `var X := Expr` type inference, so
every hoisted declaration needs an explicit type.  The tool guesses, and this
loop asks the compiler what the guess should have been.

FPC reports the error precisely enough to work with:

    Error: Incompatible types: got "TLineOrigin" expected "LongInt"

`got` names the type of the expression being assigned, which is exactly the
type the hoisted declaration needs.  Corrections are only accepted when the
offending line is an assignment that fpcport.py created (recorded in
linemap.json), so a diagnostic on an unrelated use of the same variable can
never corrupt the declared type.

Usage:
    python3 fixloop.py --src <unit dir> --unit Markdown4D.Something
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional

GOT_RE = re.compile(r'got\s+"([^"]+)"\s+expected\s+"([^"]+)"', re.I)
DIAG_RE = re.compile(r'^(?P<file>[^(\s][^()]*)\((?P<line>\d+),(?P<col>\d+)\)\s+'
                     r'(?P<sev>Error|Warning|Note|Hint|Fatal):\s*(?P<msg>.*)$')

# FPC names its internal types; map the ones that differ from a usable
# source-level spelling.
TYPE_ALIASES = {
    'AnsiString': 'string',
    'UnicodeString': 'string',
    'ShortString': 'string',
    'RawByteString': 'string',
    'WideString': 'string',
    'UTF8String': 'string',
    'LongInt': 'Integer',
    'SmallInt': 'Integer',
    'Int64': 'Int64',
    'Extended': 'Double',
    'Real': 'Double',
    'Currency': 'Currency',
    'Pointer': 'Pointer',
    'PChar': 'PChar',
}

# `got "String"` and friends are not declarable; these need a human.
UNUSABLE = {'Constant', 'Open Array', 'Array of Const', '<procedure variable>',
            'untyped', 'Void'}


def override_key(path, routine: str, name: str) -> str:
    """Name a corrected declaration so the name does not depend on the build.

    Corrections are keyed by the unit's directory inside the ported tree
    (`Core`, `Layout`, `Lcl`, `Fpc`) plus its file name, rather than by the path
    the file happened to be ported to.  That is what lets the accumulated
    corrections live in the repository and travel between build directories,
    instead of being trapped inside one build tree's sidecars.
    """
    p = Path(path)
    return f'{p.parent.name}/{p.name}:{routine}:{name}'


def publish_corrections(working: Path, seed: Path) -> bool:
    """Copy a finished build's corrections over the repository's copy.

    Returns True when the repository's file changed, so a caller can say so.
    """
    if not working.exists():
        return False
    data = working.read_text()
    if seed.exists() and seed.read_text() == data:
        return False
    seed.parent.mkdir(parents=True, exist_ok=True)
    seed.write_text(data)
    return True


def find_fpc(explicit: Optional[str]) -> str:
    if explicit:
        return explicit
    for cand in ('fpc', str(Path.home() / 'fpcupdeluxe/fpc/bin/x86_64-linux/fpc')):
        try:
            subprocess.run([cand, '-iV'], capture_output=True, check=True)
            return cand
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue
    raise SystemExit('fpc not found; pass --fpc')


def collect_unit_dirs(base: Path) -> List[Path]:
    """Every directory under `base` that holds compiled units.

    FPC will not expand a `-Fu.../*` wildcard itself, so the globs are resolved
    here instead of being handed to the compiler.
    """
    dirs: List[Path] = []
    if not base.is_dir():
        return dirs
    for ppu in base.rglob('*.ppu'):
        d = ppu.parent
        if d not in dirs:
            dirs.append(d)
    return dirs


def compile_unit(fpc: str, unit_path: Path, unit_dirs: List[Path],
                 out_dir: Path, extra: List[str]) -> List[str]:
    out_dir.mkdir(parents=True, exist_ok=True)
    cmd = [fpc, '-n', '-viwn', '-vn', '-vw', f'-FU{out_dir}', f'-Fi{out_dir}']
    for d in unit_dirs:
        cmd.append(f'-Fu{d}')
    cmd += extra
    cmd.append(str(unit_path))
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return (proc.stdout + proc.stderr).splitlines()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--fpc', default=None)
    ap.add_argument('--unit', required=True, help='unit source file to compile')
    ap.add_argument('--build', default='.fpcbuild')
    ap.add_argument('--rounds', type=int, default=6)
    ap.add_argument('--overrides', default='overrides.json')
    ap.add_argument('--rtl', default=str(Path.home() / 'fpcupdeluxe/fpc/units/x86_64-linux'),
                    help='root of the FPC unit tree to search for dependencies')
    ap.add_argument('--unitdir', action='append', default=[],
                    help='extra unit search directory (repeatable)')
    args = ap.parse_args()

    fpc = find_fpc(args.fpc)
    name = Path(args.unit).stem
    root = Path(args.unit).parent
    build = Path(args.build)
    build.mkdir(parents=True, exist_ok=True)

    unit_dirs = collect_unit_dirs(Path(args.rtl))
    unit_dirs.append(root)
    unit_dirs.extend(Path(d) for d in args.unitdir)
    print(f'dependency path: {len(unit_dirs)} directories')

    overrides: Dict[str, str] = {}
    if Path(args.overrides).exists():
        overrides = json.loads(Path(args.overrides).read_text())

    # Always regenerate from an untouched copy.  Transforming the working file
    # again would compound the namespace rewrites and invalidate every line
    # number recorded in linemap.json.
    pristine = build / 'pristine'
    pristine.mkdir(parents=True, exist_ok=True)
    source = root / f'{name}.pas'
    keeper = pristine / f'{name}.pas'
    if not keeper.exists():
        keeper.write_bytes(source.read_bytes())

    for round_no in range(1, args.rounds + 1):
        # 1. regenerate from the pristine source with the current overrides
        working = root / f'{name}.pas'
        working.write_bytes(keeper.read_bytes())
        subprocess.run([
            sys.executable, str(Path(__file__).with_name('fpcport.py')),
            '--types', str(build / f'{name}.types.json'),
            '--manifest', str(build / f'{name}.manifest.json'),
            '--linemap', str(build / f'{name}.linemap.json'),
            '--overrides', str(args.overrides),
            '--in-place', str(root / f'{name}.pas'),
        ], check=True, capture_output=True)

        # 2. ask the compiler
        log = compile_unit(fpc, root / f'{name}.pas', unit_dirs,
                           build / 'out', [])
        errors = [l for l in log if re.search(r'\bError:|\bFatal:', l)]
        linemap = json.loads((build / f'{name}.linemap.json').read_text()) \
            if (build / f'{name}.linemap.json').exists() else {}

        if not errors:
            print(f'round {round_no}: {name}.pas compiles clean')
            return 0

        # 3. turn `got "T" expected "U"` diagnostics into type corrections
        fixed = 0
        unresolved: List[str] = []
        for line in log:
            m = DIAG_RE.match(line)
            if not m or m.group('sev') not in ('Error', 'Fatal'):
                continue
            gm = GOT_RE.search(m.group('msg'))
            if not gm:
                unresolved.append(line)
                continue
            got = gm.group(1)
            key = linemap.get(f'{root / (name + ".pas")}:{m.group("line")}')
            if not key or key.get('role') != 'assign':
                unresolved.append(line)
                continue
            if got in UNUSABLE:
                unresolved.append(line)
                continue
            new_type = TYPE_ALIASES.get(got, got)
            ok = re.fullmatch(r'[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*', new_type)
            if not ok:
                unresolved.append(line)
                continue
            full = f'{root / (name + ".pas")}:{key["routine"]}:{key["name"]}'
            if overrides.get(full) != new_type:
                overrides[full] = new_type
                fixed += 1

        Path(args.overrides).write_text(json.dumps(overrides, indent=1, sort_keys=True))
        print(f'round {round_no}: {len(errors)} error(s), {fixed} type(s) corrected, '
              f'{len(unresolved)} unattributed')
        if fixed == 0:
            print(f'-- no further progress on {name}.pas --')
            for l in unresolved[:20]:
                print('   ' + l)
            return 1

    print(f'-- exceeded {args.rounds} rounds on {name}.pas --')
    return 1


if __name__ == '__main__':
    sys.exit(main())
