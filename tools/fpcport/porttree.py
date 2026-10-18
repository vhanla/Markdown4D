#!/usr/bin/env python3
"""
porttree.py -- port a whole source tree to FPC and drive the type fixpoint.

Runs fpcport.py over every unit, then compiles the entire set at once (via a
generated `uses`-everything program) so that dependency compiles happen in one
pass.  FPC diagnostics are attributed back to individual declarations through
each unit's linemap.json, corrected types are folded into overrides.json, and
the whole tree is regenerated until no further corrections are possible.

Anything still failing after the fixpoint is a genuine gap -- a missing RTL
unit, a differently-shaped API, or a GUI dependency -- and is reported as such
rather than retried.

Usage:
    python3 porttree.py --src Source --dir Core --dir Layout --out /tmp/port
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
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from fixloop import (DIAG_RE, GOT_RE, TYPE_ALIASES, UNUSABLE,  # noqa: E402
                     collect_unit_dirs, find_fpc, override_key,
                     publish_corrections)

HERE = Path(__file__).parent

# A const hoisted verbatim that FPC refuses to fold: its initialiser is not
# actually a compile-time constant, so it has to become a runtime assignment
# rather than have its type "corrected".
CONST_ERR = re.compile(
    r'Illegal expression|Constant expression expected|'
    r'Expression cannot be evaluated at compile time|'
    r'Typed constants of classes or interfaces are not allowed', re.I)


def usable_type(t: str) -> bool:
    """A source-level type spelling a corrected declaration can carry.

    Plain names, dotted unit-qualified names and generic instantiations such as
    `TList<System.Double>` are usable; FPC's internal signatures (which contain
    `(`, `:` and `;`) are not.
    """
    if not re.fullmatch(r'[A-Za-z_][\w.<>, ]*', t):
        return False
    if t.count('<') != t.count('>'):
        return False
    # FPC renders an instantiated generic's base name in upper case in its
    # diagnostics (`TOBJECTLIST<...>`, `TARRAY<...>`), and may fully qualify the
    # arguments by unit.  That spelling is not valid Object Pascal source, so a
    # correction carrying it must be ignored in favour of the heuristic guess.
    if re.search(r'\b[A-Z][A-Z0-9_]{1,}\s*<', t):
        return False
    return True


def port_all(units: List[Path], overrides: Path, build: Path,
             last_error: Optional[str] = None) -> None:
    args = [sys.executable, str(HERE / 'fpcport.py'),
            '--types', str(build / 'types.json'),
            '--manifest', str(build / 'manifest.json'),
            '--linemap', str(build / 'linemap.json'),
            '--overrides', str(overrides),
            '--in-place'] + [str(u) for u in units]
    returns = build / 'returns.json'
    if returns.exists():
        args[2:2] = ['--returns', str(returns)]
    fields = build / 'fields.json'
    if fields.exists():
        args[2:2] = ['--fields', str(fields)]
    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stdout[-4000:])
        print(proc.stderr[-4000:])
        raise SystemExit('fpcport failed')


# `function Name(params): Ret;` possibly wrapped across lines.  The parameter
# list may contain `;` separators and one level of nested parentheses (default
# values), so it is matched structurally rather than up to a `;`.
FUNC_RET_RE = re.compile(
    r'\bfunction\s+([\w.]+)\s*(?:<[^<>]*>)?\s*'
    r'(?:\([^()]*(?:\([^()]*\)[^()]*)*\))?\s*:\s*([^;\n]+);',
    re.S)
# `property TableAlignments: TArray<...> read FTableAlignments write ...;`
# FPC reports the type of a property read only as an opaque internal name when
# the property is a generic instantiation, so the declared type has to be known
# in advance.
PROP_RET_RE = re.compile(
    r'\bproperty\s+([\w.]+)\s*(?:\[[^\]]*\])?\s*:\s*([^;\n]+?)\s+read\b',
    re.I)
# `TSyntaxLineScannerClass = class of TSyntaxLineScanner;` -- a factory typed
# `class of B` constructs a `B` when its `.Create` is called, so the alias must
# resolve to the class it names rather than to itself.
CLASS_OF_ALIAS_RE = re.compile(
    r'^\s*([A-Za-z_]\w*)\s*=\s*class\s+of\s+([A-Za-z_]\w*)\s*;',
    re.I | re.M)
RET_TYPE_OK = re.compile(r'[A-Za-z_][\w.<>, ]*')


def ported_pas_files(pristine: Path, roots: List[str]) -> List[Path]:
    """Every pristine unit belonging to the directories this run ports."""
    files: List[Path] = []
    for root in roots:
        files += sorted((pristine / root).rglob('*.pas'))
    return files


def build_returns(pristine: Path, dest: Path, roots: List[str]) -> None:
    """Index every routine's declared return type across the source tree.

    FPC reports a generic-array result only as an opaque `TARRAY$1$crc...`
    internal name, which cannot be turned back into source.  Knowing the
    callee's declared return type lets a hoisted `X := SomeCall(...)` get the
    right type on the first guess instead of never.

    Only the directories being ported are scanned.  The index is deliberately
    flat and name-only, so letting a companion run's units (the example layer)
    contribute would let, say, a field called `Indent` in an example class
    re-guess a library declaration's type -- and a guess naming a type that is
    not in scope cannot be corrected by the compiler, so the run would stall.
    """
    seen: Dict[str, set] = defaultdict(set)
    for pas in ported_pas_files(pristine, roots):
        text = pas.read_text(encoding='utf-8', errors='replace')
        for m in FUNC_RET_RE.finditer(text):
            full = re.sub(r'\s+', '', m.group(1))
            name = full.rsplit('.', 1)[-1]
            ret = m.group(2).strip()
            if RET_TYPE_OK.fullmatch(ret):
                seen[name].add(ret)
                if '.' in full:
                    # A qualified key lets a receiver-aware call site tell
                    # `TMarkdownTextFormat.Default` apart from any other
                    # `Default`; the bare name alone conflates them.
                    seen[full].add(ret)
        for m in PROP_RET_RE.finditer(text):
            name = m.group(1).rsplit('.', 1)[-1]
            ret = m.group(2).strip()
            if RET_TYPE_OK.fullmatch(ret):
                seen[name].add(ret)
        for m in CLASS_OF_ALIAS_RE.finditer(text):
            # `A = class of B` is indexed as though `A` were a routine whose
            # result is `B`, so a `Var := A.Create(...)` guesses `B`.
            seen[m.group(1)].add(m.group(2))
    # Only unambiguous names are trusted; an overload with a different result
    # type must not be guessed.
    out = {n: next(iter(rs)) for n, rs in seen.items() if len(rs) == 1}
    dest.write_text(json.dumps(out, indent=1, sort_keys=True))


# A type declaration opening (`= record`, `= class`, `= class(...)`) and the
# `end;` that closes it.
TYPE_OPEN_RE = re.compile(r'=\s*(?:packed\s+)?(?:record|class)\b', re.I)
TYPE_CLOSE_RE = re.compile(r'^\s*end\s*[;.]', re.I)
FIELD_DECL_RE = re.compile(r'^\s*([A-Za-z_]\w*)\s*:\s*([^;()=]+);\s*$')
FIELD_SKIP_RE = re.compile(
    r'\b(property|procedure|function|constructor|destructor|case)\b', re.I)


def build_fields(pristine: Path, dest: Path, roots: List[str]) -> None:
    """Index record/class fields declared anywhere in the source tree.

    A hoisted loop variable may iterate a record field of a type declared in
    another unit (`for Contour in Run.Contours`), so the per-unit field map is
    not enough.  Only unambiguous names are kept, because the index is flat:
    `Value` or `Count` appear in many records with different types and must not
    be guessed.  Fields inside routine bodies are not scanned (a routine's own
    `var` section has the same shape).  Like `build_returns`, only the ported
    directories are scanned; see there for why.
    """
    seen: Dict[str, set] = defaultdict(set)
    for pas in ported_pas_files(pristine, roots):
        text = pas.read_text(encoding='utf-8', errors='replace')
        depth = 0
        for line in text.splitlines():
            if depth == 0:
                if TYPE_OPEN_RE.search(line):
                    depth = 1
                continue
            if TYPE_OPEN_RE.search(line):
                depth += 1
                continue
            if TYPE_CLOSE_RE.match(line):
                depth -= 1
                continue
            if FIELD_SKIP_RE.search(line):
                continue
            m = FIELD_DECL_RE.match(line)
            if m:
                typ = m.group(2).strip()
                if RET_TYPE_OK.fullmatch(typ):
                    seen[m.group(1).lower()].add(typ)
    out = {n: next(iter(rs)) for n, rs in seen.items() if len(rs) == 1}
    dest.write_text(json.dumps(out, indent=1, sort_keys=True))


def write_uses_all(units: List[Path], build: Path) -> Path:
    """A program that pulls in every unit, so one compile covers the tree.

    Only units whose file name matches their unit name can be listed; the
    others are still compiled transitively.
    """
    names = sorted({u.stem for u in units
                    if re.fullmatch(r'[A-Za-z_][\w.]*', u.stem)})
    body = ',\n'.join(f'  {n}' for n in names)
    src = (f'program AllUnits;\n'
           f'{{$MODE DELPHIUNICODE}}{{$H+}}\n'
           f'uses\n{body};\n'
           f'begin\nend.\n')
    p = build / 'AllUnits.pas'
    p.write_text(src)
    return p


def compile_tree(fpc: str, units: List[Path], dirs: List[Path],
                 out: Path) -> List[str]:
    """Compile each unit on its own.

    A single compile cannot be used here: FPC aborts the whole run on the first
    Fatal error, which would hide every later failure behind it.  Per-unit
    compiles isolate each failure, and FPC compiles dependencies on demand so
    work is not repeated.
    """
    out.mkdir(parents=True, exist_ok=True)
    seen: set = set()
    log: List[str] = []
    for u in units:
        cmd = [fpc, '-n', '-viwn', '-vn', '-vw', '-Se2000',
               f'-FU{out}', f'-Fi{out}']
        for d in dirs:
            cmd.append(f'-Fu{d}')
        cmd.append(str(u))
        proc = subprocess.run(cmd, capture_output=True, text=True)
        for line in (proc.stdout + proc.stderr).splitlines():
            if re.search(r'\bError:|\bFatal:', line) and line not in seen:
                seen.add(line)
                log.append(line)
    return log


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--src', default='Source')
    ap.add_argument('--dir', action='append', default=[],
                    help='subdirectory to port (repeatable); default Core+Layout')
    ap.add_argument('--extra-dir', action='append', default=[], metavar='NAME=PATH',
                    help='extra source directory to port into out/NAME '
                         '(repeatable); PATH is relative to the working directory')
    ap.add_argument('--skip', action='append', default=[], metavar='UNIT',
                    help='unit stem to leave out of the port (repeatable)')
    ap.add_argument('--extra-only', action='store_true',
                    help='port only the --extra-dir directories, into an '
                         'existing tree, with type indexes of its own')
    ap.add_argument('--out', required=True, help='build tree to write into')
    ap.add_argument('--fpc', default=None)
    ap.add_argument('--rtl', default=str(Path.home() / 'fpcupdeluxe/fpc/units/x86_64-linux'))
    ap.add_argument('--rounds', type=int, default=8)
    ap.add_argument('--overrides', default=str(HERE / 'overrides.json'),
                    help='accumulated type corrections, shared between builds '
                         'and published back when a port succeeds')
    args = ap.parse_args()

    src = Path(args.src)
    dirs = args.dir or ['Core', 'Layout']
    if args.extra_only:
        dirs = []
    skip = set(args.skip)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    fpc = find_fpc(args.fpc)
    rtl_dirs = collect_unit_dirs(Path(args.rtl))

    # Pristine copy of the include plus every unit to port.  Each round is
    # regenerated from these, because transforming an already-transformed file
    # would compound the namespace rewrites.
    shutil.copy2(src / 'Markdown4D.Fpc.inc', out / 'Markdown4D.Fpc.inc')
    # The RTL-shim units are already FPC-specific and are copied verbatim; the
    # transform appends Markdown4D.Fpc.Compat to every ported unit's uses clause.
    fpc_src = src / 'Fpc'
    if fpc_src.is_dir():
        (out / 'Fpc').mkdir(parents=True, exist_ok=True)
        for f in sorted(fpc_src.glob('*.pas')):
            shutil.copy2(f, out / 'Fpc' / f.name)
        # The transform also lists the shim in the implementation clause as
        # `Markdown4D.Fpc.CompatImpl`, because a unit may not appear in both
        # clauses.  It is a hand-authored thin unit that re-exports only the
        # non-generic shadows; duplicating Compat wholesale would give the two
        # clauses distinct instantiations of `TFunc` and break every interface
        # signature that mentions it.  Fall back to a rename only if the thin
        # unit is absent (older trees).
        impl_src = fpc_src / 'Markdown4D.Fpc.CompatImpl.pas'
        if impl_src.exists():
            shutil.copy2(impl_src, out / 'Fpc' / 'Markdown4D.Fpc.CompatImpl.pas')
        else:
            compat = fpc_src / 'Markdown4D.Fpc.Compat.pas'
            if compat.exists():
                impl = compat.read_text(encoding='utf-8').replace(
                    'unit Markdown4D.Fpc.Compat;',
                    'unit Markdown4D.Fpc.CompatImpl;', 1)
                (out / 'Fpc' / 'Markdown4D.Fpc.CompatImpl.pas').write_text(
                    impl, encoding='utf-8')
    pristine = build_root = out / '.fpcbuild' / 'pristine'
    units: List[Path] = []
    # `--extra-dir NAME=PATH` ports a directory outside --src into `out/NAME`,
    # which is what carries the framework-neutral example units (Examples/Shared)
    # into the tree the LCL examples link against.  Being one level deep, their
    # `{$I ../Markdown4D.Fpc.inc}` resolves exactly like Core/Layout do.
    roots: List[Tuple[str, Path]] = [(d, src / d) for d in dirs]
    for spec in args.extra_dir:
        name, sep, path = spec.partition('=')
        if not sep or not name or not path:
            raise SystemExit(f'--extra-dir wants NAME=PATH, got {spec!r}')
        roots.append((name, Path(path)))
    for d, root in roots:
        (out / d).mkdir(parents=True, exist_ok=True)
        (pristine / d).mkdir(parents=True, exist_ok=True)
        for f in sorted(root.glob('*.pas')):
            if f.stem in skip:
                continue
            keeper = pristine / d / f.name
            # The pristine copy is the Delphi original a round starts from, so it
            # has to track Source/: refresh it whenever the file on disk differs.
            # Keeping the first copy forever silently ignored every later edit to
            # the unit -- the tree kept being rebuilt from the stale snapshot.
            if not keeper.exists() or keeper.read_bytes() != f.read_bytes():
                shutil.copy2(f, keeper)
            units.append(out / d / f.name)
    # The LCL-side units (Source/Lcl) are already Free Pascal code, not Delphi,
    # so they are copied verbatim rather than transformed.  Consequence: they
    # must compile exactly as written -- FPC rejects inline declarations
    # (`for var X in ...`), and the rewrite that ports those away only runs on
    # the Core/Layout tree, not here.  They are NOT added
    # to `units`: they depend on the Lazarus LCL, which this driver's plain RTL
    # search path does not carry.  tools/fpcport/lclbuild.sh compiles them
    # against the finished tree instead.
    lcl_src = src / 'Lcl'
    if lcl_src.is_dir():
        for f in sorted(lcl_src.rglob('*.pas')):
            dest = out / 'Lcl' / f.relative_to(lcl_src)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, dest)

    # The LCL units embed the bundled math font with {$R '../Fonts/...'}, so the
    # resource files travel next to them, with the same layout as Source/.
    fonts_src = src / 'Fonts'
    if fonts_src.is_dir():
        (out / 'Fonts').mkdir(parents=True, exist_ok=True)
        for f in sorted(fonts_src.iterdir()):
            if f.is_file():
                shutil.copy2(f, out / 'Fonts' / f.name)

    build = out / '.fpcbuild'
    build.mkdir(parents=True, exist_ok=True)

    def restore() -> None:
        for u in units:
            (out / u.parent.name / u.name).write_bytes(
                (pristine / u.parent.name / u.name).read_bytes())
    overrides = build / 'overrides.json'
    if not overrides.exists():
        seed = Path(args.overrides)
        overrides.write_text(seed.read_text() if seed.exists() else '{}')

    root_names = [name for name, _ in roots]
    build_returns(pristine, build / 'returns.json', root_names)
    build_fields(pristine, build / 'fields.json', root_names)

    entry = write_uses_all(units, build)
    # Every directory already in the tree is on the search path: a companion
    # run (--extra-only) has to resolve the library units it builds on, and a
    # re-run resolves whatever was ported before it.
    unit_dirs = rtl_dirs + [out] + sorted(
        d for d in out.iterdir() if d.is_dir() and not d.name.startswith('.'))
    # Every value a key has ever taken; a key with more than one distinct value
    # is oscillating, which is a correction conflict rather than slow progress.
    history: Dict[str, List[str]] = defaultdict(list)

    def remember(k: str, v: str) -> None:
        if not history[k] or history[k][-1] != v:
            history[k].append(v)

    def print_residual(by_file: Dict[str, Counter]) -> None:
        print('\n-- residual failures by file --')
        for fname, c in sorted(by_file.items(),
                               key=lambda kv: -sum(kv[1].values())):
            top = ', '.join(f'{k} x{v}' for k, v in c.most_common(3))
            print(f'  {fname:52s} {sum(c.values()):4d}   {top}')
        flip = {k: v for k, v in history.items() if len(v) > 1}
        if flip:
            print(f'\n-- oscillating keys: {len(flip)} --')
            for k, v in list(flip.items())[:25]:
                print(f'  {k}  ->  {v}')

    for round_no in range(1, args.rounds + 1):
        restore()
        port_all(units, overrides, build)

        log = compile_tree(fpc, units, unit_dirs, build / 'out')
        errors = [l for l in log if re.search(r'\bError:|\bFatal:', l)]
        if not errors:
            print(f'round {round_no}: tree compiles clean '
                  f'({len(units)} units)')
            if publish_corrections(overrides, Path(args.overrides)):
                print(f'  corrections published to {args.overrides}')
            return 0

        # fpcport.py writes one shared linemap per invocation; load it so
        # diagnostics can be attributed back to individual declarations.
        merged: Dict[str, dict] = {}
        shared = build / 'linemap.json'
        if shared.exists():
            merged.update(json.loads(shared.read_text()))

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

            # Attribute strictly: the recorded line must belong to the same
            # file as the diagnostic.  Matching on the line number alone would
            # let an unrelated file's line 417 "correct" this one, which flips
            # types back and forth forever.
            candidates = [k for k in merged
                          if Path(k.rsplit(':', 1)[0]).name == fname
                          and k.endswith(f':{m.group("line")}')]
            entry = merged[candidates[0]] if candidates else None

            if entry and entry.get('role') == 'const_static' \
                    and CONST_ERR.search(m.group('msg')):
                # The hoisted const is not a compile-time constant after all:
                # demote it so the next round emits `var` + assignment.
                full = override_key(candidates[0].rsplit(':', 1)[0],
                                    entry['routine'], entry['name'])
                if ov.get(full) != '#dynamic':
                    ov[full] = '#dynamic'
                    remember(full, '#dynamic')
                    fixed += 1
                continue

            gm = GOT_RE.search(m.group('msg'))
            if not gm:
                if "Can't find unit" in m.group('msg'):
                    by_file[fname]['missing unit'] += 1
                else:
                    by_file[fname][m.group('msg')[:60]] += 1
                unattributed.append(line)
                continue
            got = gm.group(1)
            # FPC names a literal's type `Constant String`, `Constant Char`, ...
            # Strip the qualifier so the primitive alias below applies.
            got = re.sub(r'^Constant\s+', '', got)
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
            # A demoted const keeps its '#dynamic' marker; its corrected type
            # goes to a companion key so the demotion is not undone.
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
        print(f'round {round_no}: {len(errors)} error(s) in {len(by_file)} file(s), '
              f'{fixed} type(s) corrected, {len(unattributed)} unattributed')
        if fixed == 0:
            print('\n-- fixpoint reached --')
            print_residual(by_file)
            return 1

    print(f'-- exceeded {args.rounds} rounds --')
    print_residual(by_file)
    return 1


if __name__ == '__main__':
    sys.exit(main())
