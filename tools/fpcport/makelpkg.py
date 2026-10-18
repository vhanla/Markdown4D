#!/usr/bin/env python3
"""
makelpkg.py -- write the Lazarus package for a ported tree.

The package lists the units porttree.py generated plus the hand-written LCL
units, so the viewer and the editor can be dropped on a Lazarus form the same
way the VCL ones are dropped on a Delphi form.  It is generated rather than
hand-maintained because the unit list has to follow the source tree.

Usage:
    python3 makelpkg.py --tree build/fpc --out packages/markdown4d_lcl.lpk

The file name has to match the package name: Lazarus refuses a package link
whose .lpk is not named after the package it declares (`IsMakingSense` in
packagelinkintf.pas), so `markdown4d_lcl.lpk` -- not `Markdown4D.Lcl.lpk`.

It also has to carry `<UsageOptions><UnitPath Value="$(PkgOutDir)"/>
</UsageOptions>`: without it a project that requires the package gets no unit
path for it and fails with "Can't find unit Markdown4D".
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import List, Tuple

# `unit Foo.Bar;` -- the unit name does not always match the file name (the
# ported tree has a few that do not), and the package must use the real one.
UNIT_NAME_RE = re.compile(r'^\s*unit\s+([A-Za-z_][\w.]*)\s*;', re.M)

SUBDIRS = ('Core', 'Layout', 'Fpc', 'Lcl')


def read_unit_name(path: Path) -> str:
    m = UNIT_NAME_RE.search(path.read_text(encoding='utf-8', errors='replace'))
    return m.group(1) if m else path.stem


def collect(tree: Path) -> List[Tuple[Path, str]]:
    units: List[Tuple[Path, str]] = []
    for sub in SUBDIRS:
        d = tree / sub
        if not d.is_dir():
            continue
        # Only the top level: Source/Lcl/Examples holds programs, which are not
        # part of the package.
        for f in sorted(d.glob('*.pas')):
            units.append((f, read_unit_name(f)))
    return units


def relative(path: Path, base: Path) -> str:
    """The path as Lazarus writes it: relative to the .lpk, forward slashes."""
    import os
    return os.path.relpath(path, base).replace('\\', '/')


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--tree', default='build/fpc',
                    help='the ported tree (see makefpc.sh)')
    ap.add_argument('--out', default='packages/markdown4d_lcl.lpk')
    ap.add_argument('--name', default='markdown4d_lcl')
    args = ap.parse_args()

    tree = Path(args.tree)
    out = Path(args.out)
    if not tree.is_dir():
        raise SystemExit(f'no such tree: {tree} -- run makefpc.sh first')

    units = collect(tree)
    if not units:
        raise SystemExit(f'{tree} holds no units -- run makefpc.sh first')

    base = out.parent
    lines: List[str] = []
    for path, name in units:
        lines.append('      <Item>')
        lines.append(f'        <Filename Value="{relative(path, base)}"/>')
        lines.append(f'        <UnitName Value="{name}"/>')
        lines.append('      </Item>')

    body = '\n'.join(lines)
    # Lazarus builds a package by compiling a generated main unit that pulls in
    # every listed unit, so the directories those units live in have to be on
    # the unit path as well -- the file list alone is not enough.
    search = ';'.join(relative(tree / sub, base) for sub in SUBDIRS)
    xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<CONFIG>
  <Package Version="6">
    <Name Value="{args.name}"/>
    <Type Value="RunAndDesignTime"/>
    <Author Value="GDK Software"/>
    <License Value="MIT"/>
    <Description Value="Markdown4D markdown viewer and editor for LCL (Free Pascal / Lazarus)."/>
    <Version Major="1"/>
    <Files>
{body}
    </Files>
    <RequiredPkgs>
      <Item>
        <PackageName Value="LCL"/>
      </Item>
    </RequiredPkgs>
    <CompilerOptions>
      <Version Value="11"/>
      <SearchPaths>
        <OtherUnitFiles Value="{search}"/>
        <UnitOutputDirectory Value="lib/$(TargetCPU)-$(TargetOS)"/>
      </SearchPaths>
    </CompilerOptions>
    <UsageOptions>
      <UnitPath Value="$(PkgOutDir)"/>
    </UsageOptions>
  </Package>
</CONFIG>
'''
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(xml, encoding='utf-8')
    print(f'wrote {out} ({len(units)} units)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
