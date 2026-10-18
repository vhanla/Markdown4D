#!/usr/bin/env python3
"""
lclport.py -- drive fpcport.py's type fixpoint for the hand-written LCL units.

The units under Source/Lcl are Free Pascal, not Delphi, so they are never
namespace-rewritten.  They do, however, carry the same inline `var`/`const`
declarations as their Delphi counterparts, and FPC has no such thing, so the
hoisting half of fpcport.py applies to them too -- only the types it guesses
have to be settled against the LCL compile rather than the plain RTL one.

This is porttree.py's loop narrowed to one LCL unit: restore the pristine copy,
re-port it, compile it against the LCL build tree, and fold the corrected types
into an overrides file until the unit compiles clean.

Usage:
    python3 lclport.py --tree /tmp/opencode/tree Source/Lcl/Markdown4D.Lcl.Editor.pas
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, List

sys.path.insert(0, str(Path(__file__).parent))
from fixloop import (DIAG_RE, GOT_RE, TYPE_ALIASES, UNUSABLE,  # noqa: E402
                     override_key)
from porttree import CONST_ERR, usable_type  # noqa: E402

HERE = Path(__file__).parent
REPO = HERE.parent.parent


def compile_unit(tree: Path, unit: Path) -> List[str]:
    """Compile one LCL unit through lclbuild.sh and return its diagnostics."""
    proc = subprocess.run(
        [str(HERE / 'lclbuild.sh'), str(tree), str(unit)],
        capture_output=True, text=True, cwd=str(REPO))
    log: List[str] = []
    seen: set = set()
    for line in (proc.stdout + proc.stderr).splitlines():
        if re.search(r'\bError:|\bFatal:', line) and line not in seen:
            seen.add(line)
            log.append(line)
    return log


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--tree', required=True, help='accumulated build tree')
    ap.add_argument('--rounds', type=int, default=12)
    ap.add_argument('units', nargs='+', help='paths under Source/Lcl to port')
    args = ap.parse_args()

    tree = Path(args.tree).resolve()
    build = tree / '.fpcbuild'
    build.mkdir(parents=True, exist_ok=True)
    pristine = build / 'lclpristine'
    pristine.mkdir(parents=True, exist_ok=True)
    overrides = build / 'lcl-overrides.json'
    if not overrides.exists():
        overrides.write_text('{}')

    targets: List[Dict[str, Path]] = []
    for rel in args.units:
        src = (REPO / rel).resolve() if not Path(rel).is_absolute() else Path(rel)
        keeper = pristine / src.name
        if not keeper.exists():
            shutil.copy2(src, keeper)
        dest = tree / 'Lcl' / src.name
        targets.append({'src': src, 'keeper': keeper, 'dest': dest})

    def restore() -> None:
        for t in targets:
            t['dest'].write_bytes(t['keeper'].read_bytes())

    history: Dict[str, List[str]] = defaultdict(list)

    def remember(key: str, value: str) -> None:
        if not history[key] or history[key][-1] != value:
            history[key].append(value)

    for round_no in range(1, args.rounds + 1):
        restore()
        port = [sys.executable, str(HERE / 'fpcport.py'),
                '--types', str(build / 'types.json'),
                '--manifest', str(build / 'manifest.json'),
                '--linemap', str(build / 'lcl-linemap.json'),
                '--overrides', str(overrides),
                '--no-namespaces', '--in-place']
        if (build / 'returns.json').exists():
            port[2:2] = ['--returns', str(build / 'returns.json')]
        if (build / 'fields.json').exists():
            port[2:2] = ['--fields', str(build / 'fields.json')]
        port += [str(t['dest']) for t in targets]
        proc = subprocess.run(port, capture_output=True, text=True, cwd=str(REPO))
        if proc.returncode != 0:
            print(proc.stdout[-4000:], proc.stderr[-4000:])
            raise SystemExit('fpcport failed')

        merged: Dict[str, dict] = {}
        shared = build / 'lcl-linemap.json'
        if shared.exists():
            merged.update(json.loads(shared.read_text()))

        log: List[str] = []
        seen: set = set()
        for t in targets:
            for line in compile_unit(tree, t['dest']):
                if line not in seen:
                    seen.add(line)
                    log.append(line)

        if not log:
            print(f'round {round_no}: {len(targets)} unit(s) compile clean')
            for t in targets:
                t['src'].write_bytes(t['dest'].read_bytes())
            return 0

        ov: Dict[str, str] = json.loads(overrides.read_text())
        fixed = 0
        by_file: Dict[str, Counter] = defaultdict(Counter)
        unattributed: List[str] = []
        for line in log:
            m = DIAG_RE.match(line)
            if not m or m.group('sev') not in ('Error', 'Fatal'):
                continue
            fname = Path(m.group('file')).name
            by_file[fname]['errors'] += 1

            candidates = [k for k in merged
                          if Path(k.rsplit(':', 1)[0]).name == fname
                          and k.endswith(f':{m.group("line")}')]
            entry = merged[candidates[0]] if candidates else None

            if entry and entry.get('role') == 'const_static' \
                    and CONST_ERR.search(m.group('msg')):
                full = override_key(candidates[0].rsplit(':', 1)[0],
                                    entry['routine'], entry['name'])
                if ov.get(full) != '#dynamic':
                    ov[full] = '#dynamic'
                    remember(full, '#dynamic')
                    fixed += 1
                continue

            gm = GOT_RE.search(m.group('msg'))
            if not gm:
                unattributed.append(line)
                by_file[fname][m.group('msg')[:60]] += 1
                continue
            got = re.sub(r'^Constant\s+', '', gm.group(1))
            if not candidates or got in UNUSABLE:
                unattributed.append(line)
                continue
            new_type = TYPE_ALIASES.get(got, got)
            if not usable_type(new_type):
                unattributed.append(line)
                continue
            key = candidates[0]
            full = override_key(key.rsplit(':', 1)[0],
                                merged[key]['routine'], merged[key]['name'])
            target = f'{full}#type' if ov.get(full) == '#dynamic' else full
            if ov.get(target) != new_type:
                ov[target] = new_type
                remember(target, new_type)
                fixed += 1
                if os.environ.get('FPC_DEBUG'):
                    print(f'    {target} <- {new_type}'
                          f'   [{m.group("file")}:{m.group("line")}]'
                          f' {m.group("msg")[:90]}')

        overrides.write_text(json.dumps(ov, indent=1, sort_keys=True))
        print(f'round {round_no}: {len(log)} error(s) in {len(by_file)} file(s), '
              f'{fixed} type(s) corrected, {len(unattributed)} unattributed')
        if fixed == 0:
            print('\n-- fixpoint reached --')
            for fname, c in sorted(by_file.items(),
                                   key=lambda kv: -sum(kv[1].values())):
                top = ', '.join(f'{k} x{v}' for k, v in c.most_common(3))
                print(f'  {fname:52s} {sum(c.values()):4d}   {top}')
            flip = {k: v for k, v in history.items() if len(v) > 1}
            if flip:
                print(f'\n-- oscillating keys: {len(flip)} --')
                for k, v in list(flip.items())[:25]:
                    print(f'  {k}  ->  {v}')
            for line in unattributed[:40]:
                print(f'  unattributed: {line}')
            return 1

    print(f'-- exceeded {args.rounds} rounds --')
    return 1


if __name__ == '__main__':
    sys.exit(main())
