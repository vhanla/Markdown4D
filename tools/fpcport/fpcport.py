#!/usr/bin/env python3
"""
fpcport.py -- convert Delphi 10.3+ inline declarations into FPC-legal form.

Free Pascal has no inline declarations at all: `var X: T;`, `const X = ...;`,
`for var I := ...` and `for var X in ...` inside a statement block are syntax
errors, and no mode switch enables them.  There is no `m_inline_vars` among the
45 modeswitches in FPC 3.3.1.

This tool hoists every inline declaration into the enclosing routine's
declaration part.  The result is valid in BOTH FPC and Delphi -- repeated
interleaved `const`/`var` sections before `begin` are legal in both -- so the
conversion is unconditional and needs no `{$IFDEF}` guard.

Three transforms:

  1. `for var I := a to b`   ->  `for I := a to b`   + hoisted `var I: T;`
     `for var X in C`        ->  `for X in C`        + hoisted `var X: T;`

  2. `var X: T;`             ->  hoisted `var X: T;`

  3. `const X = Expr;`
        compile-time constant -> hoisted into the routine's `const` section
        computed from locals   -> hoisted as `var X: T;` and the original line
                                  becomes the assignment `X := Expr;`
       Hoisting a computed const verbatim would evaluate it once at routine
       entry instead of at the original point, silently changing behaviour.

Duplicate names within one routine are renamed (never merged): renaming a local
is always semantically safe, merging is not when element types differ.

Types for the hoisted declarations cannot be inferred by FPC, so the tool
guesses and records every guess in a JSON sidecar.  `fixloop.py` compiles the
result and corrects the guesses from the compiler's own diagnostics.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from fixloop import override_key  # noqa: E402

# ---------------------------------------------------------------------------
# Lexical masking
# ---------------------------------------------------------------------------

@dataclass
class LexState:
    """Tracks constructs that span physical lines."""
    in_brace: bool = False      # { ... }   or   (* ... *)
    in_paren_comment: bool = False


def mask_line(line: str, state: LexState) -> str:
    """Blank out strings and comments, preserving length and layout.

    Applying the structural regexes to the mask means a `begin` inside a string
    literal or a comment can never be mistaken for a block opener.
    """
    out = list(line)
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if state.in_brace:
            out[i] = ' '
            if c == '}':
                state.in_brace = False
            i += 1
            continue
        if state.in_paren_comment:
            out[i] = ' '
            if c == '*' and i + 1 < n and line[i + 1] == ')':
                out[i + 1] = ' '
                state.in_paren_comment = False
                i += 2
                continue
            i += 1
            continue
        if c == '/' and i + 1 < n and line[i + 1] == '/':
            for j in range(i, n):
                out[j] = ' '
            break
        if c == '{':
            state.in_brace = True
            out[i] = ' '
            i += 1
            continue
        if c == '(' and i + 1 < n and line[i + 1] == '*':
            state.in_paren_comment = True
            out[i] = out[i + 1] = ' '
            i += 2
            continue
        if c == "'":
            out[i] = ' '
            i += 1
            while i < n:
                out[i] = ' '
                if line[i] == "'":
                    if i + 1 < n and line[i + 1] == "'":   # doubled quote
                        out[i + 1] = ' '
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        i += 1
    return ''.join(out)


def strip_comments(line: str, state: LexState) -> str:
    """Blank comments but keep string contents, preserving every offset.

    Structural matching uses `mask_line`, which blanks strings as well so a
    `begin` or `;` inside a literal cannot be mistaken for code.  Reading a
    declaration's *text*, though, must keep `', '` intact while dropping a
    trailing `// note`, which is exactly what this variant produces.
    """
    out = list(line)
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if state.in_brace:
            out[i] = ' '
            if c == '}':
                state.in_brace = False
            i += 1
            continue
        if state.in_paren_comment:
            out[i] = ' '
            if c == '*' and i + 1 < n and line[i + 1] == ')':
                out[i + 1] = ' '
                state.in_paren_comment = False
                i += 2
                continue
            i += 1
            continue
        if c == '/' and i + 1 < n and line[i + 1] == '/':
            for j in range(i, n):
                out[j] = ' '
            break
        if c == '{':
            state.in_brace = True
            out[i] = ' '
            i += 1
            continue
        if c == '(' and i + 1 < n and line[i + 1] == '*':
            state.in_paren_comment = True
            out[i] = out[i + 1] = ' '
            i += 2
            continue
        if c == "'":
            i += 1
            while i < n:
                if line[i] == "'":
                    if i + 1 < n and line[i + 1] == "'":
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        i += 1
    return ''.join(out)


# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

ROUTINE_RE = re.compile(
    r'^(?P<indent>\s*)(?:class\s+)?'
    r'(?P<kind>procedure|function|constructor|destructor|operator)'
    r'\s+(?P<name>[A-Za-z_][\w.]*)', re.I)

END_RE = re.compile(r'^(\s*)end\s*[;.]?\s*$', re.I)
BEGIN_RE = re.compile(r'^(\s*)begin\s*$', re.I)

# An anonymous function used as an expression has its own declaration part and
# therefore its own hoisting target:
#
#     Result := TComparer<T>.Construct(
#       function(const Left, Right: T): Integer
#       begin
#         const LeftOrder = OrderOf(Left);      <- hoists into the anon's part
#         ...
#       end);
ANON_RE = re.compile(r'^(?P<indent>\s*)(?:procedure|function)\s*\([^)]*\)'
                     r'(?:\s*:\s*[^;]+)?\s*$', re.I)
ANON_END_RE = re.compile(r'^(\s*)end\b[\s;.,)]*$', re.I)


@dataclass
class Decl:
    """One inline declaration discovered inside a routine body."""
    line: int                    # 0-based index of the declaring line
    kind: str                    # 'var' | 'const_static' | 'const_dynamic' | 'for'
    names: List[str]
    type_hint: Optional[str]     # explicit `: T` annotation, when present
    rhs: Optional[str]           # initialiser / loop expression
    indent: str
    scope_end: int = -1          # last line (inclusive) the name is visible in
    renamed_from: Optional[str] = None
    end_line: int = -1           # last line of a declaration that wraps
    loop_in: bool = False        # `for X in Y` rather than `for X := a to b`


@dataclass
class Routine:
    header_line: int
    indent: str
    name: str
    body_start: int              # line of the routine's `begin`
    body_end: int                # line of the routine's terminating `end`
    decls: List[Decl] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

def find_anonymous(lines: List[str], masks: List[str],
                   outer: List[Routine]) -> List[Routine]:
    """Locate anonymous-function bodies, which need their own hoisting target.

    An anonymous function's declarations are invisible to the enclosing routine,
    so hoisting into the outer routine would compile but change scope.  These
    bodies are returned as routines with a synthetic, position-stable name.
    """
    found: List[Routine] = []
    for r in outer:
        i = r.body_start + 1
        while i < r.body_end:
            m = ANON_RE.match(masks[i])
            if not m:
                i += 1
                continue
            indent = m.group('indent')
            body = -1
            j = i + 1
            while j < r.body_end:
                bm = BEGIN_RE.match(masks[j])
                if bm and bm.group(1) == indent:
                    body = j
                    break
                j += 1
            if body < 0:
                i += 1
                continue
            end = -1
            for k in range(body + 1, r.body_end + 1):
                em = ANON_END_RE.match(masks[k])
                if em and em.group(1) == indent:
                    end = k
                    break
            if end < 0:
                i += 1
                continue
            found.append(Routine(i, indent, f'anon@{i + 1}', body, end))
            i = end + 1
    return found


def find_routines(lines: List[str], masks: List[str]) -> List[Routine]:
    """Locate every routine body between `implementation` and the final `end.`

    A routine's terminating `end;` sits at the same indentation as its header,
    which is the most reliable boundary in this codebase.  Nested routines are
    found by the same rule at deeper indentation.
    """
    impl = 0
    for i, m in enumerate(masks):
        if re.match(r'^\s*implementation\s*$', m, re.I):
            impl = i
            break

    routines: List[Routine] = []
    i = impl
    n = len(lines)
    while i < n:
        m = ROUTINE_RE.match(masks[i])
        if not m:
            i += 1
            continue
        # A header line may be a forward/interface declaration ending in `;`
        # with no body -- walk to the matching `begin` or bail out.
        indent = m.group('indent')
        j = i
        body = -1
        while j < n:
            if j > i and ROUTINE_RE.match(masks[j]) and not masks[j].startswith(indent + ' '):
                break
            mm = BEGIN_RE.match(masks[j])
            if mm and mm.group(1) == indent:
                body = j
                break
            if j > i and END_RE.match(masks[j]):
                break
            j += 1
        if body < 0:
            i += 1
            continue

        end = -1
        for k in range(body + 1, n):
            em = END_RE.match(masks[k])
            if em and em.group(1) == indent:
                end = k
                break
        if end < 0:
            i += 1
            continue

        routines.append(Routine(i, indent, m.group('name'), body, end))
        i = end + 1
    return routines


DECL_VAR_RE = re.compile(
    r'^(?P<indent>\s*)var\s+(?P<names>[A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)'
    r'\s*:\s*(?!=\s*)(?P<type>[^;]+);')
# `var X := Expr;` -- Delphi infers the type from the initialiser.  The
# initialiser frequently reads a loop variable or an earlier local, so it has to
# stay a runtime assignment at its original position, not move to routine entry.
# `rhs` deliberately starts immediately after the operator.  Matching runs on
# the string-blanked mask, and this anchoring makes the group's span line up
# with the real text, so a literal such as `', '` survives intact.
VAR_INIT_RE = re.compile(
    r'^(?P<indent>\s*)var\s+(?P<name>[A-Za-z_]\w*)\s*:=(?P<rhs>.+?);\s*$')
# `var X: T := Expr;` -- an explicit type AND a runtime initialiser.
VAR_TYPED_INIT_RE = re.compile(
    r'^(?P<indent>\s*)var\s+(?P<name>[A-Za-z_]\w*)\s*:(?P<type>.+?)'
    r'\s*:=(?P<rhs>.+?);\s*$')
DECL_CONST_RE = re.compile(
    r'^(?P<indent>\s*)const\s+(?P<name>[A-Za-z_]\w*)'
    r'\s*(?::\s*(?P<type>[A-Za-z_][\w.<>, ]*?))?\s*=(?P<rhs>.+?);\s*$')
FOR_VAR_RANGE_RE = re.compile(
    r'^(?P<indent>\s*)for\s+var\s+(?P<name>[A-Za-z_]\w*)'
    r'\s*(?::\s*(?P<type>[A-Za-z_][\w.<>, ]*?))?\s*:=\s*(?P<rhs>.+)$')
FOR_VAR_IN_RE = re.compile(
    r'^(?P<indent>\s*)for\s+var\s+(?P<name>[A-Za-z_]\w*)'
    r'\s*(?::\s*(?P<type>[A-Za-z_][\w.<>, ]*?))?\s+in\s+(?P<rhs>.+)$')
# A `var`/`const` declaration that wraps onto the following lines.  `for` is
# deliberately excluded: its header carries no `;`, so scanning for one would
# run into the loop body.
MULTILINE_START_RE = re.compile(r'^\s*(?:var|const)\s+[A-Za-z_]\w*', re.I)

# Identifiers and calls that yield a known type, used for the first guess.
STRING_CALLS = re.compile(
    r'\b(Trim|TrimLeft|TrimRight|UpperCase|LowerCase|IntToStr|Format|Copy|'
    r'StringReplace|QuotedStr|IntToHex|FloatToStr|ReplaceText|GetEnumName|'
    r'IntToStr|BoolToStr|StringOf|NewStr|UTF8Encode|JoinString)\s*\(', re.I)
BOOL_CALLS = re.compile(
    r'\b(assigned|Supports|IsDigit|IsLetter|IsLetterOrDigit|IsWhiteSpace|'
    r'TryStrToInt|TryStrToFloat|SameText|CompareText|StartsWith|EndsWith|'
    r'Contains|IsEmpty|TryGetValue|Equals)\b', re.I)
BOOL_OPS = re.compile(
    r'(<>|<=|>=|<|>|\band\b|\bor\b|\bnot\b|\bxor\b|\bTrue\b|\bFalse\b|'
    r'(?<![<>=!])=(?!=))', re.I)
FLOAT_LIT = re.compile(r'\b\d+\.\d+\b|\.\d+\b|\b\d+(\.\d+)?[eE][-+]?\d+\b')
# Bare `<`/`>` above would misfire on a generic instantiation such as
# `TList<Integer>`, so discount that shape before trusting the Boolean guess.
GENERIC_SHAPE = re.compile(r'[A-Za-z_]\w*\s*<[A-Za-z_][\w.]*>')
# `Xs := SingleCall(args)` -- a whole right-hand side that is one call, whose
# declared return type is authoritative when the tree-wide index knows it.
# The receiver chain is kept so `TOwner.Make` can be looked up as
# `TOwner.Make` before the bare `Make` is considered.
QUALIFIED_CALL = re.compile(
    r'^(?P<callee>(?:[A-Za-z_]\w*\s*\.\s*)*[A-Za-z_]\w*)'
    r'\s*(?:<[^<>]*(?:<[^<>]*>[^<>]*)*>)?\s*\(.*\)$', re.S)

# Delphi's `Default(T)` and the `T(Expr)` cast both yield exactly `T`.  Handling
# them explicitly keeps the bare-callee return index from misreading
# `Default(TWindingCounter)` as a call to some other class's `Default` method.
DEFAULT_CALL = re.compile(r'Default\s*\(\s*([A-Za-z_]\w*)\s*\)$', re.S)
CAST_CALL = re.compile(r'(T[A-Z]\w*)\s*\(.*\)$', re.S)
# `TList<Integer>.Create`, `TObjectList<TList<Integer>>.Create` (the latter
# already rewritten to a local alias) construct and return their receiver type.
CTOR_CALL = re.compile(
    r'^(?P<ty>[A-Za-z_]\w*\s*(?:<[^<>]*(?:<[^<>]*>[^<>]*)*>)?)'
    r'\s*\.\s*Create\b', re.S)
# Ordinal-returning intrinsics: `Round`, `Trunc`, `Ceil` and `Floor` all yield
# `Int64` in FPC (and `Int64`/`Integer` in Delphi), never `Double`.
ORDINAL_INT_CALL = re.compile(r'\b(Ceil|Floor|Round|Trunc)\s*\(', re.I)

# A bare callee whose name is also a member method of nearly every class says
# nothing about the result type -- the tree-wide return index conflates them
# (`TMarkdownTextFormat.Default` has nothing to do with `Default(TEdgeCrossing)`).
RET_DENY = {
    'create', 'free', 'default', 'tostring', 'clone', 'equals', 'gethashcode',
    'parse', 'tryparse', 'fromstring', 'compare', 'getvalue', 'trygetvalue',
    'add', 'contains', 'indexof', 'toarray', 'tolist', 'assign', 'loadfrom',
    'saveto', 'count', 'getenumerator', 'tojson', 'fromjson',
}

# Generic containers whose single type argument is the element a `for ... in`
# loop or an index yields.  `TDictionary` is deliberately absent: iterating one
# produces a key/value pair, not its value type.
ELEMENT_CONTAINERS = {
    'tarray', 'tlist', 'tobjectlist', 'tstack', 'tqueue', 'tobjectstack',
    'tobjectqueue', 'tcollection', 'tenumerable', 'ienumerable', 'tthreadlist',
    'torderedlist', 'tobjectdictionary',
}
# Container members that return the element itself rather than a field.  A
# `Stack.Peek` read yields the type argument, not a field named `Peek`.
CONTAINER_READERS = {'peek', 'last', 'first', 'top', 'elementat'}
STRING_TYPES = {'string', 'unicodestring', 'widestring', 'ansistring',
                'rawbytestring', 'utf8string'}
# Receivers that name a built-in type rather than a value.  A call qualified by
# one of these (`string.Join`) is an RTL type helper, never a member of a
# same-named function elsewhere in the tree.
TYPE_RECEIVERS = STRING_TYPES | {
    'integer', 'int64', 'int32', 'cardinal', 'byte', 'word', 'smallint',
    'longint', 'qword', 'double', 'single', 'extended', 'real', 'boolean',
    'char', 'widestring', 'variant', 'tobject',
}


def generic_arg_list(inner: str) -> List[str]:
    """Split a generic argument list on the commas at nesting depth zero."""
    parts: List[str] = []
    depth = 0
    cur = ''
    for ch in inner:
        if ch == '<':
            depth += 1
        elif ch == '>':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur)
            cur = ''
        else:
            cur += ch
    parts.append(cur)
    return [p.strip() for p in parts]


def element_type(t: Optional[str]) -> Optional[str]:
    """The type an index or a `for ... in` binds over `t`, when knowable."""
    if not t:
        return None
    t = t.strip()
    m = re.fullmatch(r'([A-Za-z_]\w*)\s*<(.*)>', t, re.S)
    if m and m.group(1).lower() in ELEMENT_CONTAINERS:
        args = generic_arg_list(m.group(2))
        return args[0] if args else None
    m = re.fullmatch(r'array\s+of\s+(.+)', t, re.I)
    if m:
        return m.group(1).strip()
    if t.lower() in STRING_TYPES:
        return 'Char'
    return None


def type_of_expr(expr: str, env: Dict[str, str],
                 fields: Dict[str, str]) -> Optional[str]:
    """Resolve the declared type of a simple expression via the scope env.

    Handles a bare identifier, a field of one (`Block.Alignments`), and any
    number of index operations on either (`Contours[I]`, `Key.Font.Name`).
    Only the shapes the inline-declaration transform actually meets are covered;
    anything richer returns None so the heuristics take over.
    """
    s = expr.strip()
    # One index step: `Base[...]`; recurse on the base so `A[I][J]` peels twice.
    m = re.fullmatch(r'(.+?)\s*\[.*\]', s, re.S)
    if m:
        base = type_of_expr(m.group(1), env, fields)
        return element_type(base)
    # One field step: `Base.Field`.
    m = re.fullmatch(r'([A-Za-z_]\w*)\.([A-Za-z_]\w*)', s)
    if m:
        base = type_of_expr(m.group(1), env, fields)
        if base:
            member = m.group(2).lower()
            # `Stack.Peek`, `List.Last`, ... yield the container's element type;
            # there is no field of that name to look up.
            if member in CONTAINER_READERS:
                return element_type(base)
            # A per-type field index is not kept; field names are unique enough
            # in this codebase (they carry an F prefix where it matters).
            return fields.get(member)
        return None
    m = re.fullmatch(r'[A-Za-z_]\w*', s)
    if m:
        return env.get(s.lower()) or fields.get(s.lower())
    return None


def returns_type(rhs: str, returns: Optional[Dict[str, str]],
                 owner: str = '', env: Optional[Dict[str, str]] = None,
                 fields: Optional[Dict[str, str]] = None) -> Optional[str]:
    """The declared return type of a whole right-hand side that is one call.

    A bare call inside a method may name a sibling whose bare name is ambiguous
    tree-wide (`ContentsOf` exists in two units with different results), so the
    enclosing class is tried first.  A call on a receiver whose type is known
    (`Icon.Build(...)`) is resolved through that type.  A dotted or bare member
    read (`Block.TableAlignments`) resolves through the property's declared
    type, which lives in the same index.
    """
    if not returns:
        return None
    env = env or {}
    fields = fields or {}
    m = QUALIFIED_CALL.match(rhs.strip())
    if not m:
        s = rhs.strip()
        read = re.fullmatch(r'(?:[A-Za-z_]\w*\s*\.\s*)*([A-Za-z_]\w*)', s)
        if not read:
            return None
        # A receiver naming a type (`TMarkdownNodeKind.Link`) is an enum member
        # or a static access, not an instance property; the enum rule handles it
        # later, and a static access must not borrow a same-named property's
        # type.
        head = re.match(r'([A-Za-z_]\w*)\s*\.', s)
        if head and re.match(r'^T[A-Z]', head.group(1)):
            return None
        bare = read.group(1)
        if bare.lower() in RET_DENY:
            return None
        return returns.get(bare)
    callee = re.sub(r'\s+', '', m.group('callee'))
    bare = callee.rsplit('.', 1)[-1]
    if '.' in callee:
        recv, meth = callee.rsplit('.', 1)
        if callee in returns:
            return returns[callee]
        # A receiver naming a type (`string.Join`, `TFoo.Bar`) is a deliberate
        # qualification: only that type's own member counts, and the bare name
        # (which may belong to an unrelated unit) must not be substituted.
        if re.fullmatch(r'T[A-Z]\w*(?:<.*>)?', recv) \
                or recv.lower() in TYPE_RECEIVERS:
            return None
        recv_type = type_of_expr(recv, env, fields)
        if recv_type and f'{recv_type}.{meth}' in returns:
            return returns[f'{recv_type}.{meth}']
        return returns.get(bare)
    if owner and f'{owner}.{bare}' in returns:
        return returns[f'{owner}.{bare}']
    if bare.lower() in RET_DENY:
        return None
    return returns.get(bare)


def guess_type(decl: Decl, returns: Optional[Dict[str, str]] = None,
               env: Optional[Dict[str, str]] = None,
               fields: Optional[Dict[str, str]] = None,
               loop_in: bool = False, owner: str = '') -> str:
    """Best-effort initial type for a hoisted declaration.

    Deliberately conservative: `fixloop.py` corrects mistakes from the
    compiler's `Incompatible types: got "T" expected "U"` diagnostics, which
    name the exact type of the offending expression.  `returns` maps a routine
    name (bare or `Owner.Name`) to its declared return type, which resolves
    array and record results that FPC otherwise reports only as an opaque
    `TARRAY$...` internal name.  `env`/`fields` let a loop variable or an index
    read take the element type of what it iterates or indexes.
    """
    env = env or {}
    fields = fields or {}
    if decl.type_hint:
        return decl.type_hint
    if decl.kind == 'var' and not decl.rhs:
        return 'Integer'                       # no initialiser to inspect
    rhs = decl.rhs or ''
    stripped = re.sub(r"'[^']*'", "''", rhs)

    # 1. `Default(T)` and `T(Expr)` name their result type outright.
    dm = DEFAULT_CALL.match(stripped.strip())
    if dm:
        return dm.group(1)
    cm = CAST_CALL.match(stripped.strip())
    if cm:
        return cm.group(1)

    # 2. A `for ... in` binds the element type of the collection it walks.  The
    #    captured header still carries a trailing `do` (and possibly an inline
    #    body), so cut the collection expression out first.
    if loop_in:
        coll = re.sub(r'\s+\b(?:do|begin)\b.*$', '', rhs.strip(), flags=re.I | re.S)
        t = element_type(type_of_expr(coll, env, fields))
        if t:
            return t

    # 3. A plain read (`Contours`, `Block.Alignments`, `Values[I]`) resolves
    #    through the scope environment.
    t = type_of_expr(stripped.strip(), env, fields)
    if t:
        return t

    # 3b. A constructor call returns its receiver, which may be a nested-generic
    #     specialization or a local alias for one.  A receiver that is not
    #     itself type-shaped (`Factory.Create(...)`) is a value or a function
    #     whose own type must be resolved; a `class of B` alias then yields `B`.
    ct = CTOR_CALL.match(stripped.strip())
    if ct:
        recv = re.sub(r'\s+', '', ct.group('ty'))
        if re.fullmatch(r'T[A-Z]\w*(?:<.*>)?', recv, re.S):
            return recv
        t = returns_type(recv, returns, owner, env, fields) \
            or type_of_expr(recv, env, fields)
        if t:
            return (returns or {}).get(t, t)
        return recv

    # 4. A single call takes the callee's declared return type, when known.
    t = returns_type(stripped, returns, owner, env, fields)
    if t:
        return t

    if FLOAT_LIT.search(stripped):
        return 'Double'
    probe = GENERIC_SHAPE.sub('T', stripped)
    if BOOL_OPS.search(probe) or BOOL_CALLS.search(probe):
        return 'Boolean'
    if "''" in stripped or STRING_CALLS.search(stripped):
        return 'string'
    # `Ceil`/`Floor`/`Round`/`Trunc` yield an ordinal, not a real, even though
    # their argument is one.
    if ORDINAL_INT_CALL.search(stripped):
        return 'Int64'
    # The `string` type helper's concatenators return a string.
    if re.match(r'^\s*string\s*\.\s*(Join|Concat)\s*\(', stripped, re.I):
        return 'string'
    # `TEnum.Member` -> the enum type, but only when the whole right-hand side
    # is exactly that; a `T...` type appearing inside call arguments must not
    # be mistaken for the type of a receiver such as `Value.GetValue(TFoo.Key)`.
    enum_member = re.fullmatch(r'(T[A-Z]\w*)\.[A-Za-z_]\w*', stripped.strip())
    if enum_member:
        return enum_member.group(1)
    # `Ratio = Count / Total` style integer division promoted to float.
    if re.search(r'/', stripped) and not re.search(r'//|/\*', stripped):
        return 'Double'
    return 'Integer'


def statement_end(masks: List[str], i: int, limit: int = 40) -> int:
    """Last line of a declaration that starts at `i`.

    Delphi lets an inline declaration wrap across physical lines; its terminator
    is the first `;` seen with every `(`/`[` balanced.  Matching against the
    string-blanked mask keeps a `;` inside a literal from ending it early.  If
    no terminator is found within `limit` lines, `i` is returned unchanged.
    """
    depth = 0
    j = i
    while j < len(masks) and j <= i + limit:
        depth += masks[j].count('(') - masks[j].count(')')
        depth += masks[j].count('[') - masks[j].count(']')
        # An anonymous-function initialiser opens a `begin` block of its own, so
        # the statement's terminator is the `end;` that closes it, not the `;`
        # that ends the last statement inside it.  Counting `begin`/`end` keeps
        # that inner `;` from terminating the declaration early.
        depth += len(re.findall(r'\bbegin\b', masks[j]))
        depth -= len(re.findall(r'\bend\b', masks[j]))
        if ';' in masks[j] and depth <= 0:
            return j
        j += 1
    return i


def is_dynamic_const(rhs: str, local_names: set) -> bool:
    """A const is hoistable verbatim only when it is a compile-time constant.

    Anything mentioning a local variable, a parameter, or a field must become a
    runtime assignment, otherwise hoisting would freeze it at routine entry.
    """
    stripped = re.sub(r"'[^']*'", "''", rhs)
    for ident in re.findall(r'\b([A-Za-z_]\w*)\b', stripped):
        if ident.lower() in local_names:
            return True
    # Method calls and field reads on locals are runtime by definition.
    if re.search(r'\b(Self|Result)\b', stripped):
        return True
    # An anonymous method is never a compile-time constant; FPC rejects a typed
    # const whose initialiser is one.
    if re.search(r'\bfunction\s*\(|\bprocedure\s*\(|\bbegin\b', stripped):
        return True
    if re.search(r'\)\s*\.', stripped):        # Something(...).Field
        return True
    return False


def collect_locals(routines: List[Routine], masks: List[str],
                   codes: List[str],
                   exclude: Optional[List[Tuple[int, int]]] = None) -> None:
    """Populate each routine's decls, in source order.

    `masks` blanks both strings and comments and drives structural matching;
    `codes` blanks only comments and supplies the declaration text, so a string
    literal such as `', '` survives into the hoisted statement.  The two are
    always the same length, so a match on one yields spans valid in the other.

    `exclude` holds line ranges belonging to nested anonymous functions, whose
    declarations must be hoisted into the anonymous body instead.
    """
    skip = exclude or []

    def text(code: str, m: 're.Match', name: str) -> str:
        return code[m.start(name):m.end(name)].strip()

    for r in routines:
        # Parameters are visible in the body and can make a const dynamic.
        local: set = set()
        for j in range(r.header_line, r.body_start):
            for ident in re.findall(r'\b([A-Za-z_]\w*)\b', masks[j]):
                local.add(ident.lower())
        for j in range(r.body_start + 1, r.body_end):
            if any(a <= j <= b for a, b in skip):
                continue
            m = masks[j]
            s = m.strip()
            if not s:
                continue

            # `var`/`const` may wrap onto the following lines; join the whole
            # statement so the single-line regexes below can still read it.
            # (`for` is excluded: its header has no `;`.)
            end = j
            if MULTILINE_START_RE.match(m) and ';' not in m:
                end = statement_end(masks, j)
            jm = m
            jc = codes[j]
            if end > j:
                jm = m + ' ' + ' '.join(masks[k].strip()
                                        for k in range(j + 1, end + 1))
                jc = codes[j] + ' ' + ' '.join(codes[k].strip()
                                               for k in range(j + 1, end + 1))

            fm = FOR_VAR_RANGE_RE.match(jm)
            if fm:
                r.decls.append(Decl(j, 'for', [text(jc, fm, 'name')],
                                    text(jc, fm, 'type'),
                                    text(jc, fm, 'rhs'), fm.group('indent'),
                                    end_line=end))
                local.add(fm.group('name').lower())
                continue
            fm = FOR_VAR_IN_RE.match(jm)
            if fm:
                r.decls.append(Decl(j, 'for', [text(jc, fm, 'name')],
                                    text(jc, fm, 'type'),
                                    text(jc, fm, 'rhs'), fm.group('indent'),
                                    end_line=end, loop_in=True))
                local.add(fm.group('name').lower())
                continue
            vm = VAR_INIT_RE.match(jm)
            if vm:
                # Checked before DECL_VAR_RE so `:=` is not read as `: type`.
                r.decls.append(Decl(j, 'var_init', [vm.group('name')], None,
                                    text(jc, vm, 'rhs'), vm.group('indent'),
                                    end_line=end))
                local.add(vm.group('name').lower())
                continue
            vm = VAR_TYPED_INIT_RE.match(jm)
            if vm:
                r.decls.append(Decl(j, 'var_typed_init', [vm.group('name')],
                                    text(jc, vm, 'type'), text(jc, vm, 'rhs'),
                                    vm.group('indent'), end_line=end))
                local.add(vm.group('name').lower())
                continue
            vm = DECL_VAR_RE.match(jm)
            if vm:
                names = [x.strip() for x in vm.group('names').split(',')]
                r.decls.append(Decl(j, 'var', names, text(jc, vm, 'type'),
                                    None, vm.group('indent'), end_line=end))
                local.update(x.lower() for x in names)
                continue
            cm = DECL_CONST_RE.match(jm)
            if cm:
                rhs = text(jc, cm, 'rhs')
                kind = ('const_dynamic'
                        if is_dynamic_const(rhs, local)
                        else 'const_static')
                type_hint = (text(jc, cm, 'type')
                             if cm.group('type') is not None else None)
                r.decls.append(Decl(j, kind, [cm.group('name')], type_hint, rhs,
                                    cm.group('indent'), end_line=end))
                local.add(cm.group('name').lower())


# ---------------------------------------------------------------------------
# Scopes and duplicate resolution
# ---------------------------------------------------------------------------

def compute_scope_ends(routine: Routine, masks: List[str]) -> None:
    """Give every declaration the last line on which its name is visible.

    For `for` loops that is the loop body: either a `begin` block, or a single
    statement after `do`.  Everything else stays visible to the end of the
    routine, which is a superset of the true scope and therefore safe to rename
    within -- but only until the next declaration of the same name, which hides
    it from its own line on.  Ignoring that shadowing made the earlier
    declaration's rename rewrite the later one's body, leaving the two out of
    step (`const Builder` renamed to `Builder_3` while its uses still read
    `Builder_2`).
    """
    for d in routine.decls:
        if d.kind != 'for':
            d.scope_end = routine.body_end
            continue

        # The trailing keyword is the last whole-word `do` on the line: a
        # substring search would stop at the `do` of `Document` or `downto` and
        # collapse the scope to the header line, leaving the body of a renamed
        # loop variable pointing at whatever shared its name.
        do_match = None
        for candidate in re.finditer(r'\bdo\b', masks[d.line], re.I):
            do_match = candidate
        if do_match is None:
            d.scope_end = routine.body_end
            continue

        k = d.line + 1
        # `do` on the same line followed by the single statement.
        tail = masks[d.line][do_match.end():].strip()
        if tail and not re.match(r'^(begin|$)', tail, re.I):
            d.scope_end = d.line
            continue

        # `do begin` shares the line with the opening `begin` of the body.
        first = d.line if tail else k
        bm = BEGIN_RE.match(masks[first]) if first < len(masks) else None
        if bm:
            depth = 0
            e = first
            while e <= routine.body_end:
                depth += len(re.findall(r'\bbegin\b', masks[e], re.I))
                depth -= len(re.findall(r'\bend\b', masks[e], re.I))
                if depth <= 0:
                    break
                e += 1
            d.scope_end = min(e, routine.body_end)
        else:
            d.scope_end = min(k, routine.body_end)

    # A later declaration of the same name hides the earlier one from the later
    # one's line on, so the earlier one's scope has to stop there.
    by_name: Dict[str, List[Decl]] = {}
    for d in routine.decls:
        for name in d.names:
            by_name.setdefault(name.lower(), []).append(d)
    for decls in by_name.values():
        decls.sort(key=lambda d: d.line)
        for earlier, later in zip(decls, decls[1:]):
            earlier.scope_end = min(earlier.scope_end, later.line - 1)


def resolve_duplicates(routine: Routine,
                       masks: List[str]) -> List[Tuple[Decl, str, str]]:
    """Rename repeated declarations inside one routine.

    Renaming a local is always safe; merging is not, because two `for..in`
    loops over different element types cannot share one declared type.  Only
    ~60 sites in the whole tree repeat a name, so the conservative choice costs
    nothing.

    Returns `(declaration, old name, new name)` triples, each carrying its own
    scope, so one declaration's rename cannot reach into a scope that a later
    declaration of the same name owns.
    """
    renames: List[Tuple[Decl, str, str]] = []
    seen: Dict[str, List[Decl]] = {}
    for d in routine.decls:
        for name in d.names:
            seen.setdefault(name.lower(), []).append(d)

    counters: Dict[str, int] = {}
    for key, decls in seen.items():
        if len(decls) < 2:
            continue
        original = decls[0].names[0] if decls[0].names else key
        for d in decls[1:]:
            counters[key] = counters.get(key, 1) + 1
            new = f'{original}_{counters[key]}'
            renames.append((d, key, new))
            d.names = [new if x.lower() == key else x for x in d.names]
            d.renamed_from = original
    return renames


def replace_ident_in_pair(real: str, mask: str, old: str, new: str) -> Tuple[str, str]:
    """Replace whole-word occurrences in both the code and its mask.

    Applied right-to-left so earlier replacements cannot shift later spans.
    Identifier matching is case-insensitive, because Object Pascal is.
    """
    spans = [m.span() for m in
             re.finditer(r'\b' + re.escape(old) + r'\b', mask, re.I)]
    for a, b in reversed(spans):
        real = real[:a] + new + real[b:]
        mask = mask[:a] + new + mask[b:]
    return real, mask


# ---------------------------------------------------------------------------
# Namespace rewrite
# ---------------------------------------------------------------------------

# Delphi-style namespaced units that have a name-identical FPC counterpart.
# FPC's -FN switch *prefixes* units rather than stripping a prefix (see
# compiler/fppu.pas: "repeat 1-3 and 5-8 with namespace as prefix"), and there
# is no unit-alias switch, so the uses clause itself has to change.
NAMESPACE_MAP = {
    'System.SysUtils': 'SysUtils',
    'System.Classes': 'Classes',
    'System.Math': 'Math',
    'System.StrUtils': 'StrUtils',
    'System.Character': 'Character',
    'System.TypInfo': 'TypInfo',
    'System.SyncObjs': 'SyncObjs',
    'System.DateUtils': 'DateUtils',
    'System.Generics.Collections': 'Generics.Collections',
    'System.Generics.Defaults': 'Generics.Defaults',
}

USES_RE = re.compile(r'^(?P<indent>\s*)uses\b', re.I)


def _uses_clause_end(masks: List[str], start: int) -> int:
    """Line index of the `;` that closes the `uses` clause beginning at `start`."""
    i = start
    while i < len(masks):
        if ';' in masks[i]:
            return i
        if USES_RE.match(masks[i]) and i != start:
            break
        i += 1
    return -1


def _append_uses_unit(lines: List[str], masks: List[str], unit_name: str,
                      after_implementation: bool) -> None:
    """Add `unit_name` to the first `uses` clause on one side of `implementation`.

    The line array grows by one element rather than gaining an embedded newline,
    so array indices stay equal to the line numbers FPC reports.
    """
    starts = [i for i, m in enumerate(masks) if USES_RE.match(m)]
    if not starts:
        return
    impl = next((i for i, m in enumerate(masks)
                 if re.match(r'^\s*implementation\s*$', m, re.I)), len(masks))
    choices = ([i for i in starts if i > impl] if after_implementation
               else [i for i in starts if i < impl])
    if not choices:
        return
    end = _uses_clause_end(masks, choices[0])
    if end < 0:
        return
    idx = lines[end].rindex(';')
    tail = lines[end][idx:]
    lines[end:end + 1] = [lines[end][:idx] + ',', f'  {unit_name}{tail}']
    masks[end:end + 1] = [masks[end][:idx] + ',', masks[end][idx:]]


def inject_compat_uses(lines: List[str], masks: List[str]) -> None:
    """Wire the FPC compatibility units into a unit's `uses` clauses.

    `Markdown4D.Fpc.Compat` is added to the interface clause so its
    `TStringBuilder`/`TFunc`/`GetAlphaColorValues` shadows are visible in
    interface declarations.  `Markdown4D.Fpc.CompatImpl` is added to the
    implementation clause as well: the implementation `uses` list is searched
    before the interface one, so only a unit listed there can shadow an RTL unit
    the implementation itself pulls in (`System.Hash`, `System.UIConsts`, ...).
    The two are separate units because a single unit may not appear in both
    clauses.  Both edits run before any structural analysis, so every recorded
    line number already accounts for the inserted lines.

    `Markdown4D.Fpc.Json` joins the implementation clause only where the JSON
    call rewrite actually fired, so the rest of the tree does not take a
    dependency on System.JSON.
    """
    # Implementation clause first: inserting there leaves the interface clause's
    # indices (used by the second insertion) untouched.
    if any('ParseJsonOrNil' in l for l in lines) \
            and not any(re.search(r'\bMarkdown4D\.Fpc\.Json\b', l)
                        for l in lines):
        _append_uses_unit(lines, masks, 'Markdown4D.Fpc.Json', True)
    if not any(re.search(r'\bMarkdown4D\.Fpc\.CompatImpl\b', l) for l in lines):
        _append_uses_unit(lines, masks, 'Markdown4D.Fpc.CompatImpl', True)
    if not any(re.search(r'\bMarkdown4D\.Fpc\.Compat\b', l) for l in lines):
        _append_uses_unit(lines, masks, 'Markdown4D.Fpc.Compat', False)



# vcl-compat's TJSONParser.Parse only re-raises the scanner's exception when the
# RaiseExc option is set; without it the routine returns without assigning the
# function result, so the caller receives an uninitialised pointer where
# Delphi's TJSONObject.ParseJSONValue returns nil.  Markdown4D.Fpc.Json restores
# the Delphi contract (parse with RaiseExc, translate the exception into nil).
JSON_PARSE_RE = re.compile(
    r'\bTJSONObject\s*\.\s*ParseJSONValue\s*\((?P<arg>[^()]*)\)')


def rewrite_json_parse_calls(lines: List[str], masks: List[str]) -> None:
    """Retarget `TJSONObject.ParseJSONValue(X)` at the compat wrapper.

    Applied unconditionally: the wrapper compiles on Delphi too, and the
    rewritten call reads the same either way.
    """
    def repl(m: 're.Match') -> str:
        return 'ParseJsonOrNil(' + m.group('arg') + ')'

    for i, code in enumerate(masks):
        if 'ParseJSONValue' not in code:
            continue
        new_code, n = JSON_PARSE_RE.subn(repl, code)
        if n:
            lines[i] = JSON_PARSE_RE.sub(repl, lines[i])
            masks[i] = new_code



# FPC's regex engine (bare `regexpr`, reached through vcl-compat's
# System.RegularExpressions) does not honour the lookahead the GFM tag-filter
# pattern needs: `'<(?=/?(?:title|...)[\s/>])'` consumes the tag it is meant to
# only inspect, so `<xmp> is disallowed.  <XMP> is also disallowed.` collapses
# to `&lt;x&lt;XMP> is also disallowed.`.  Markdown4D.Fpc.Compat scans for the
# same tags instead, which the ported call site calls.
TAG_FILTER_RE = re.compile(
    r'\bFTagFilterRegex\s*\.\s*Replace\s*\(\s*'
    r'(?P<arg>[^,()]+?)\s*,\s*EscapedLessThan\s*\)')

TAG_FILTER_CALL_RE = re.compile(r'\bFTagFilterRegex\s*\.\s*Replace\s*\(')


def rewrite_tag_filter_calls(lines: List[str], masks: List[str]) -> None:
    """Retarget `FTagFilterRegex.Replace(X, EscapedLessThan)` at the scanner.

    Applied unconditionally: the compat routine compiles on Delphi too and
    filters exactly like the pattern it stands in for.  The regex field itself
    stays where it is - building it is harmless - so the rewrite only has to
    move the call.
    """
    def repl(m: 're.Match') -> str:
        return 'FilterDisallowedTags(' + m.group('arg') + ')'

    fired = 0
    for i, code in enumerate(masks):
        if 'FTagFilterRegex' not in code:
            continue
        new_code, n = TAG_FILTER_RE.subn(repl, code)
        if n:
            fired += n
            lines[i] = TAG_FILTER_RE.sub(repl, lines[i])
            masks[i] = new_code

    # A call site the pattern does not recognize would silently keep the broken
    # RTL behaviour, so fail instead.
    if fired == 0 and any(TAG_FILTER_CALL_RE.search(code) for code in masks):
        raise ValueError('tag-filter call site not recognized by TAG_FILTER_RE')



# FPC's `TArray<T>` is a plain generic, not the record helper Delphi's RTL
# installs, so the static call `TArray.Sort<T>(...)` is a syntax error there
# (`"CREATE" expected but "SORT" found`).  FPC declares the same helpers on
# `TArrayHelper<T>`; the neutral source stays Delphi-shaped and only the ported
# copy is rewritten.
TARRAY_STATIC_RE = re.compile(
    r'\bTArray\s*\.\s*(?P<method>Sort)\s*'
    r'(?P<args><[^<>]*(?:<[^<>]*>[^<>]*)*>)')


def rewrite_generic_static_calls(lines: List[str], masks: List[str]) -> None:
    """Retarget `TArray.Sort<T>` at FPC's `TArrayHelper<T>.Sort`.

    The specialization sits on the method in Delphi's spelling
    (`TArray.Sort<T>(...)`), but FPC declares the helper on the type, so it has
    to move (`TArrayHelper<T>.Sort(...)`).  The rewrite is wrapped in a
    conditional so the emitted file still compiles unchanged under Delphi, where
    the helper type does not exist.
    """
    for i, code in enumerate(masks):
        if 'TArray' not in code:
            continue

        def repl(m: 're.Match') -> str:
            args = m.group('args')
            method = m.group('method')
            return ('{$IFDEF FPC}TArrayHelper' + args + '.' + method
                    + '{$ELSE}TArray.' + method + args + '{$ENDIF}')

        new_code, n = TARRAY_STATIC_RE.subn(repl, code)
        if n:
            lines[i] = TARRAY_STATIC_RE.sub(repl, lines[i])
            masks[i] = new_code


# A generic *method* call, `Receiver.Method<T>(args)`.
GENERIC_METHOD_CALL_RE = re.compile(
    r'[A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*\s*<[^<>;]*?>\s*\(')
# What may precede a call that stands as a statement rather than as an operand.
STMT_BEFORE_RE = re.compile(r'(?:^|;|\bbegin\b|\bthen\b|\bdo\b|\belse\b)\s*$',
                            re.I)
STMT_AFTER_RE = re.compile(r'^\s*(?:;|end\b|else\b)', re.I)
# A routine heading, where `<T>` declares the generic rather than calling one.
DECL_HEADING_RE = re.compile(
    r'\b(?:function|procedure|constructor|destructor|property)\s*$', re.I)


def _group_end(code: str, open_idx: int) -> int:
    """Index just past the parenthesised group that opens at `open_idx`."""
    depth = 0
    for i in range(open_idx, len(code)):
        if code[i] == '(':
            depth += 1
        elif code[i] == ')':
            depth -= 1
            if depth == 0:
                return i + 1
    return -1


def _call_chain_end(code: str, i: int) -> int:
    """Extend a call chain from `i` across `(args)`, `.Member`, `.M<T>(args)`."""
    while True:
        j = i
        while j < len(code) and code[j] in ' \t':
            j += 1
        if j < len(code) and code[j] == '(':
            end = _group_end(code, j)
            if end < 0:
                return i
            i = end
            continue
        if j < len(code) and code[j] == '.':
            k = j + 1
            while k < len(code) and code[k] in ' \t':
                k += 1
            m = re.match(r'[A-Za-z_]\w*', code[k:])
            if not m:
                return i
            i = k + m.end()
            gt = re.match(r'\s*<[^<>;]*?>\s*\(', code[i:])
            if gt:
                end = _group_end(code, i + gt.end() - 1)
                if end < 0:
                    return i
                i = end
            continue
        return i


def rewrite_generic_call_parens(lines: List[str], masks: List[str]) -> None:
    """Parenthesise generic method calls that are operands of a boolean operator.

    FPC's Delphi-mode parser reads `Receiver.Method<T>(args)` as a comparison
    chain (`Method < T > (args)`) unless the call is the whole expression or is
    already parenthesised.  As an operand of `and`/`or`/`xor`/`not` -- including
    when the operator is on the neighbouring line, which is why the context is
    read from there too -- the call is then a syntax error:

        if not obj.TryGetValue<string>(Key, Value) or (Value = '') then

    Parentheses are valid in Delphi as well, so this is applied unconditionally,
    like the hoisting.  A call that stands as a statement, or that heads a
    routine declaration, must be left alone.  A call whose argument list runs
    past the line is skipped rather than wrapped half way.
    """
    for idx, code in enumerate(masks):
        if '<' not in code:
            continue
        head_fallback = ''
        for k in range(idx - 1, -1, -1):
            if masks[k].strip():
                head_fallback = masks[k]
                break
        tail_fallback = ''
        for k in range(idx + 1, len(masks)):
            if masks[k].strip():
                tail_fallback = masks[k]
                break

        spans: List[Tuple[int, int]] = []
        pos = 0
        while True:
            m = GENERIC_METHOD_CALL_RE.search(code, pos)
            if not m:
                break
            end = _group_end(code, m.end() - 1)
            if end < 0:
                pos = m.end()
                continue
            end = _call_chain_end(code, end)
            head = code[:m.start()]
            if not head.strip():
                head = head_fallback
            tail = code[end:]
            if not tail.strip():
                tail = tail_fallback
            if not DECL_HEADING_RE.search(head) \
                    and not (STMT_BEFORE_RE.search(head)
                             and STMT_AFTER_RE.match(tail)):
                spans.append((m.start(), end))
            pos = max(end, m.end())

        for start, end in reversed(spans):
            lines[idx] = lines[idx][:start] + '(' + lines[idx][start:end] \
                + ')' + lines[idx][end:]
            masks[idx] = masks[idx][:start] + '(' + masks[idx][start:end] \
                + ')' + masks[idx][end:]


def rewrite_uses(lines: List[str], masks: List[str]) -> None:
    """Wrap mapped unit names in a `{$IFDEF FPC}` so Delphi still resolves them.

    Delphi accepts both `SysUtils` and `System.SysUtils`, but its default unit
    scopes do not include `Generics`, so the choice is made explicit rather than
    relying on project settings.  Code and mask are edited in lockstep so later
    passes keep seeing accurate structure.
    """
    in_uses = False
    for i, m in enumerate(masks):
        if not in_uses:
            if USES_RE.match(m):
                in_uses = True
            else:
                continue
        code = m
        if '{$IFDEF FPC}' in lines[i]:
            continue                            # already rewritten; stay idempotent
        for long_name, short_name in NAMESPACE_MAP.items():
            spans = [mm.span() for mm in re.finditer(
                r'(?<![\w.])' + re.escape(long_name) + r'(?![\w])', code)]
            for a, b in reversed(spans):
                wrapped = ('{$IFDEF FPC}' + short_name + '{$ELSE}'
                           + long_name + '{$ENDIF}')
                lines[i] = lines[i][:a] + wrapped + lines[i][b:]
                code = code[:a] + wrapped + code[b:]
        masks[i] = code
        if ';' in m:
            in_uses = False


# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------

def render_type_list(names: List[str], t: str) -> str:
    return f'{", ".join(names)}: {t};'


def transform(path: Path, types: Dict[str, str], manifest: Dict[str, str],
              overrides: Dict[str, str], linemap: Dict[str, dict],
              rewrite_namespaces: bool = True,
              returns: Optional[Dict[str, str]] = None,
              tree_fields: Optional[Dict[str, str]] = None) -> str:
    text = path.read_text(encoding='utf-8')
    lines = text.split('\n')
    if rewrite_namespaces:
        lines = insert_include_lines(lines)
        # Both rewrites run before any structural analysis: `rewrite_uses` edits
        # a line in place, `inject_compat_uses` inserts one.  Doing them first
        # keeps every line number recorded downstream (and in linemap.json)
        # equal to the line FPC will actually report.
        pre_state = LexState()
        pre_masks = [mask_line(l, pre_state) for l in lines]
        rewrite_uses(lines, pre_masks)
        rewrite_generic_static_calls(lines, pre_masks)
        rewrite_generic_call_parens(lines, pre_masks)
        rewrite_json_parse_calls(lines, pre_masks)
        rewrite_tag_filter_calls(lines, pre_masks)
        inject_compat_uses(lines, pre_masks)
    state = LexState()
    masks = [mask_line(l, state) for l in lines]
    cstate = LexState()
    codes = [strip_comments(l, cstate) for l in lines]

    routines = find_routines(lines, masks)
    anons = find_anonymous(lines, masks, routines)
    for r in routines:
        covered = [(a.body_start, a.body_end) for a in anons
                   if r.body_start <= a.body_start <= r.body_end]
        collect_locals([r], masks, codes, exclude=covered)
    for a in anons:
        collect_locals([a], masks, codes)
    for r in routines + anons:
        compute_scope_ends(r, masks)

    body_ranges = [(r.header_line, r.body_end) for r in routines + anons]
    fields = build_field_types(lines, masks, body_ranges)
    if tree_fields:
        # The unit's own declaration wins over the tree-wide index, which can
        # only be flat (a name may appear in several records).
        merged = dict(tree_fields)
        merged.update(fields)
        fields = merged

    # Scopes and renames resolve against the ORIGINAL line numbering, so all
    # renaming must finish before any line is inserted.
    for r in routines + anons:
        for d, old, new in resolve_duplicates(r, masks):
            scope_end = min(d.scope_end, len(lines) - 1)
            for k in range(d.line, scope_end + 1):
                lines[k], masks[k] = replace_ident_in_pair(
                    lines[k], masks[k], old, new)
            # The declaration text was captured before renaming, so keep it
            # in step with the rewritten lines.
            for other in r.decls:
                if other.rhs and d.line <= other.line <= scope_end:
                    other.rhs = re.sub(r'\b' + re.escape(old) + r'\b', new,
                                       other.rhs, flags=re.I)

    # Phase 1: rewrite and delete lines in place.  Line rewrites never change
    # the line count, so every routine still uses its original coordinates.
    blocks: List[Tuple[Routine, List[str], List[Tuple[int, str, str, str]],
                       List[BlockMeta], List[str]]] = []
    for r in routines + anons:
        block, pending, block_meta, posts = emit_routine(
            r, lines, masks, codes, path, types, manifest, overrides,
            returns, fields)
        if block or posts:
            blocks.append((r, block, pending, block_meta, posts))
    # Front to back by body position, so the running offset stays exact even
    # when an anonymous body sits inside an enclosing routine.
    blocks.sort(key=lambda b: b[0].body_start)

    # Deletions left holes (None) in the array.  Compact them away first, and
    # remember how many holes preceded each original index so the routine
    # offsets can be translated.
    holes = [0] * (len(lines) + 1)
    for i, l in enumerate(lines):
        holes[i + 1] = holes[i] + (1 if l is None else 0)
    lines = [l for l in lines if l is not None]

    # Phase 2: insert the blocks front to back, carrying a running offset so the
    # recorded line numbers match the file FPC actually sees.
    offset = 0
    # (anchor in compacted coordinates, how many lines the insertion adds).  A
    # later pass needs these because a nested anonymous body's block is inserted
    # after its enclosing routine's, yet lands earlier in the file.
    insertions: List[Tuple[int, int]] = []
    for r, block, pending, block_meta, posts in blocks:
        anchor = r.body_start - holes[r.body_start]
        at = anchor + offset
        # Hoisted declaration lines have no original line of their own; record
        # where each one lands so a diagnostic on it can be attributed.  `at` is
        # already final: no later block is inserted at an earlier position.
        for idx, meta in enumerate(block_meta):
            if meta is None:
                continue
            routine_name, name, role, original = meta
            linemap[f'{path}:{at + idx + 1}'] = {
                'routine': routine_name, 'name': name, 'role': role,
                'original': original - holes[original] + 1}
        lines[at:at] = block
        offset += len(block)
        if posts:
            # The converted interface constants are assigned as the body's first
            # statements, immediately after its `begin`.
            lines[at + len(block) + 1:at + len(block) + 1] = posts
            offset += len(posts)
        insertions.append((anchor, len(block) + len(posts)))

    # A rewritten in-place line (a `var` + assignment or a `for`) is shifted by
    # every insertion anchored at or before it, including a nested body's.
    for r, block, pending, block_meta, posts in blocks:
        for original, routine_name, name, role in pending:
            c = original - holes[original]
            shift = sum(length for a, length in insertions if a <= c)
            linemap[f'{path}:{c + shift + 1}'] = {
                'routine': routine_name, 'name': name, 'role': role}

    return '\n'.join(lines)


UNIT_HEAD_RE = re.compile(r'^\s*(?:unit|program|library)\s+[A-Za-z_][\w.]*\s*;',
                          re.I | re.M)


def insert_compiler_include(text: str) -> str:
    """Put the FPC/Lazarus compiler contract right after the unit clause."""
    if 'Markdown4D.Fpc.inc' in text:
        return text
    m = UNIT_HEAD_RE.search(text)
    if not m:
        return text
    return text[:m.end()] + '\n\n{$I ../Markdown4D.Fpc.inc}' + text[m.end():]


def insert_include_lines(lines: List[str]) -> List[str]:
    """Insert the include before any structural analysis.

    Doing it here keeps every line number downstream -- including the ones
    recorded in linemap.json -- consistent with the file that FPC actually
    compiles.
    """
    if any('Markdown4D.Fpc.inc' in l for l in lines):
        return lines
    for i, l in enumerate(lines):
        if UNIT_HEAD_RE.match(l):
            return lines[:i + 1] + ['', '{$I ../Markdown4D.Fpc.inc}'] + lines[i + 1:]
    return lines


# A block entry's provenance: (routine, name, role, original line).  `role` is
# 'const_static' for a hoisted const and 'decl' for a hoisted variable, so a
# diagnostic on an inserted line can be attributed and, for a const, retried as
# a runtime assignment.
BlockMeta = Optional[Tuple[str, str, str, int]]


def dedup_meta(entries: List[Tuple[str, BlockMeta]]) -> List[Tuple[str, BlockMeta]]:
    """Drop duplicate declaration lines, keeping the first occurrence."""
    seen: set = set()
    out: List[Tuple[str, BlockMeta]] = []
    for text, meta in entries:
        if text in seen:
            continue
        seen.add(text)
        out.append((text, meta))
    return out


IDENT_RE = re.compile(r'[A-Za-z_]\w*')


def param_types(header: str) -> Dict[str, str]:
    """`name -> type` for every parameter in a routine header.

    The header may wrap across lines and the parameter list may carry `const`,
    `var` or `out` modifiers and default values; all of that is stripped so the
    bare type is what remains.
    """
    out: Dict[str, str] = {}
    start = header.find('(')
    if start < 0:
        return out
    depth = 0
    end = -1
    for i in range(start, len(header)):
        if header[i] == '(':
            depth += 1
        elif header[i] == ')':
            depth -= 1
            if depth == 0:
                end = i
                break
    if end < 0:
        return out
    for part in header[start + 1:end].split(';'):
        part = part.strip()
        if not part:
            continue
        part = re.sub(r'^(?:const|var|out)\s+', '', part, flags=re.I)
        m = re.match(r'([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*:\s*(.+)$',
                     part, re.S)
        if not m:
            continue
        typ = re.split(r'\s*=\s*', m.group(2).strip())[0].strip()
        for name in m.group(1).split(','):
            out[name.strip().lower()] = typ
    return out


def build_field_types(lines: List[str], masks: List[str],
                      skip: Optional[List[Tuple[int, int]]] = None
                      ) -> Dict[str, str]:
    """`field name -> type` over one unit, for receiver reads.

    Field names are effectively unique in this codebase (private fields carry an
    `F` prefix, record fields do not), so a single flat map resolves
    `Block.Alignments` and `Key.Font.Size` closely enough for a first guess.
    Properties, methods and type/const declarations are excluded so their text
    is not mistaken for a field type.

    Types may be declared *after* `implementation` (`TMarkdownGradient` is), so
    that region is scanned too.  Lines inside a routine body are skipped
    (`skip`), because a routine's own `var` section has the same `Name: Type;`
    shape as a field and would otherwise be recorded as one.
    """
    hidden: set = set()
    for a, b in (skip or []):
        hidden.update(range(a, b + 1))
    fields: Dict[str, str] = {}
    for i in range(0, len(lines)):
        if i in hidden:
            continue
        m = masks[i]
        if re.search(r'\b(property|procedure|function|constructor|destructor)\b',
                     m, re.I):
            continue
        mm = re.match(r'^\s*(?P<name>F?[A-Za-z_]\w*)\s*:\s*(?P<type>[^;()=]+);\s*$',
                      m)
        if not mm:
            continue
        typ = mm.group('type').strip()
        if not re.fullmatch(r'[A-Za-z_][\w.<>, ]*', typ):
            continue
        fields[mm.group('name').lower()] = typ
    return fields


def nested_generic_spans(line: str) -> List[Tuple[int, int, str]]:
    """Spans of `Name<...<...>>` that are followed by `.`, in `line`.

    FPC cannot parse a qualified expression whose type argument is itself a
    generic specialization (`TList<TArray<T>>.Create`); the same text is a
    perfectly good type declaration.  Such a span is replaced by a local type
    alias, which turns the qualified expression into `Alias.Create`.
    """
    spans: List[Tuple[int, int, str]] = []
    n = len(line)
    i = 0
    while i < n:
        c = line[i]
        if not (c.isalpha() or c == '_'):
            i += 1
            continue
        m = IDENT_RE.match(line, i)
        j = m.end()
        k = j
        while k < n and line[k] == ' ':
            k += 1
        if k >= n or line[k] != '<':
            i = j
            continue
        depth = 0
        p = k
        nested = False
        while p < n:
            ch = line[p]
            if ch == '<':
                depth += 1
                if depth >= 2:
                    nested = True
            elif ch == '>':
                depth -= 1
                if depth == 0:
                    break
            elif ch in ';\r':
                break
            p += 1
        if depth == 0 and p < n and line[p] == '>' and nested:
            q = p + 1
            while q < n and line[q] == ' ':
                q += 1
            if q < n and line[q] == '.':
                spans.append((i, p + 1, line[i:p + 1]))
                i = p + 1
                continue
        i = j
    return spans


def hoist_nested_generic_aliases(routine: Routine, lines: List[str],
                                 masks: List[str]
                                 ) -> List[Tuple[str, str]]:
    """Replace nested-generic qualified expressions in a body with aliases.

    Returns the `alias -> type` pairs to declare in the routine's local `type`
    section, and rewrites the affected lines in place.
    """
    entries: List[Tuple[str, str]] = []
    aliases: Dict[str, str] = {}
    for idx in range(routine.body_start + 1, routine.body_end):
        line = lines[idx]
        if not line or '<' not in line:
            continue
        spans = nested_generic_spans(line)
        if not spans:
            continue
        new_line = line
        for a, b, text in reversed(spans):
            if text not in aliases:
                aliases[text] = f'TMarkdownFpcAlias{len(entries) + 1}'
                entries.append((aliases[text], text))
            new_line = new_line[:a] + aliases[text] + new_line[b:]
        lines[idx] = new_line
        masks[idx] = mask_line(new_line, LexState())
        # A rewritten declaration is re-emitted from its captured `rhs`, so the
        # alias has to appear there too or the raw nested-generic expression
        # comes back when the declaration is hoisted.
        for d in routine.decls:
            if d.line == idx and d.rhs:
                for text, alias in aliases.items():
                    if text in d.rhs:
                        d.rhs = d.rhs.replace(text, alias)
    return entries


# FPC rejects a typed constant whose type is a class or interface
# ("Typed constants of classes or interfaces are not allowed").  Such a constant
# is turned into a plain variable plus an assignment as the body's first
# statement, which preserves the one-evaluation-at-entry semantics.
INTERFACE_CONST_RE = re.compile(
    r'^(?P<indent>\s*)(?P<name>[A-Za-z_]\w*)\s*:\s*(?P<type>I[A-Z]\w*)\s*'
    r'=\s*(?P<rhs>.+?);\s*$')


def rewrite_interface_consts(routine: Routine, lines: List[str],
                             masks: List[str], codes: List[str]) -> List[str]:
    """Convert routine-level interface-typed constants into a var + assignment.

    Returns the assignment statements to place right after the routine's
    `begin`.  The `const` section header above the constant becomes `var` when
    nothing else in the section forbids it.
    """
    posts: List[str] = []
    for j in range(routine.header_line + 1, routine.body_start):
        m = INTERFACE_CONST_RE.match(codes[j])
        if not m:
            continue
        lines[j] = f"{m.group('indent')}{m.group('name')}: {m.group('type')};"
        masks[j] = mask_line(lines[j], LexState())
        codes[j] = lines[j]
        posts.append(f"{m.group('indent')}{m.group('name')} := {m.group('rhs')};")

        k = j - 1
        while k > routine.header_line and not (lines[k] or '').strip():
            k -= 1
        if k <= routine.header_line or \
                not re.fullmatch(r'\s*const\s*', masks[k] or '', re.I):
            continue
        # Reusing the header is only sound when the rest of the section holds no
        # untyped constant, which `var` cannot express.
        safe = True
        for t in range(j + 1, routine.body_start):
            tm = masks[t] or ''
            if re.fullmatch(r'\s*(?:const|var|type|label)\s*', tm, re.I) or \
                    re.match(r'^\s*begin\b', tm, re.I):
                break
            if re.match(r'^\s*[A-Za-z_]\w*\s*=', codes[t] or ''):
                safe = False
                break
        if safe:
            lines[k] = re.sub(r'\bconst\b', 'var', lines[k], count=1, flags=re.I)
            masks[k] = mask_line(lines[k], LexState())
    return posts


def emit_routine(routine: Routine, lines: List[str], masks: List[str],
                 codes: List[str],
                 path: Path, types: Dict[str, str], manifest: Dict[str, str],
                 overrides: Dict[str, str],
                 returns: Optional[Dict[str, str]] = None,
                 fields: Optional[Dict[str, str]] = None
                 ) -> Tuple[List[str],
                            List[Tuple[int, str, str, str]],
                            List[BlockMeta],
                            List[str]]:
    """Rewrite a routine's inline declarations, returning the block to insert.

    Line rewrites and deletions happen here; the block itself is inserted by the
    caller, which needs to know the running offset to keep linemap.json aligned
    with the file FPC actually sees.

    Returns `(block, pending, block_meta)`.  `pending` describes rewritten lines
    that still exist in place; `block_meta` is parallel to `block`, so a
    diagnostic on a hoisted declaration can be traced back to its source.
    """
    posts = rewrite_interface_consts(routine, lines, masks, codes)
    type_entries = hoist_nested_generic_aliases(routine, lines, masks)
    if not routine.decls and not type_entries and not posts:
        return [], [], [], []
    # The enclosing class, so an unqualified call to a sibling method can be
    # resolved as `Owner.Method` when its bare name is ambiguous tree-wide.
    owner = routine.name.rsplit('.', 1)[0] if '.' in routine.name else ''

    const_entries: List[Tuple[str, BlockMeta]] = []
    var_entries: List[Tuple[str, BlockMeta]] = []
    # (original line, routine, variable, role)
    pending: List[Tuple[int, str, str, str]] = []

    # Names visible to a hoisted initialiser: the parameters, any class fields,
    # and every declaration already hoisted in this routine.  Building it as the
    # declarations are emitted lets a later one read an earlier one's type.
    env: Dict[str, str] = dict(fields or {})
    header_text = ' '.join(masks[routine.header_line:routine.body_start])
    env.update(param_types(header_text))

    for d in routine.decls:
        key = override_key(path, routine.name, d.names[0])
        last = d.end_line if d.end_line > d.line else d.line

        demoted = overrides.get(key) == '#dynamic'

        if d.kind == 'const_static' and not demoted:
            # A genuine compile-time constant: move it, verbatim, into the
            # routine's const section.
            annotation = f': {d.type_hint}' if d.type_hint else ''
            const_entries.append((f'  {d.names[0]}{annotation} = {d.rhs};',
                                  (routine.name, d.names[0], 'const_static',
                                   d.line)))
            for k in range(d.line, last + 1):
                lines[k] = None                # moved into the const section
            if d.type_hint:
                for name in d.names:
                    env[name.lower()] = d.type_hint
            continue

        # Types come from the sidecar when fixloop.py has already corrected
        # them, otherwise from a heuristic guess the compiler will vet.
        # '#dynamic' is not a type: it marks a const FPC refused to fold, which
        # has to become a runtime assignment instead.
        t = overrides.get(key + '#type') if demoted else overrides.get(key)
        if not t or t == '#dynamic' or d.type_hint:
            # An explicit `: T` in the source is authoritative: it beats both
            # the recorded corrections and the heuristic guess, which is how a
            # `for ... in` over a container whose element type is not knowable
            # (`TJSONArray`) is typed exactly rather than guessed.
            t = d.type_hint or guess_type(d, returns, env, fields, d.loop_in,
                                          owner)
        if t and t != '#dynamic':
            for name in d.names:
                env[name.lower()] = t

        if d.kind in ('const_dynamic', 'var_init', 'var_typed_init') or \
                demoted:
            # Stays a runtime assignment: the expression usually reads a loop
            # variable or an earlier local, so hoisting it verbatim would
            # evaluate it once at routine entry instead of here.
            var_entries.append((f'  {render_type_list(d.names, t)}',
                                (routine.name, d.names[0], 'decl', d.line)))
            lines[d.line] = f'{d.indent}{d.names[0]} := {d.rhs};'
            masks[d.line] = mask_line(lines[d.line], LexState())
            for k in range(d.line + 1, last + 1):
                lines[k] = None
            pending.append((d.line, routine.name, d.names[0], 'assign'))
            record_type(types, manifest, path, routine, d.names[0], t, d.line)
            continue

        if d.kind == 'for':
            # The variable is now declared by the hoist, so an explicit
            # `for var X: T in` loses its annotation here.
            lines[d.line] = re.sub(
                r'\bfor\s+var\s+(?P<n>[A-Za-z_]\w*)'
                r'(?:\s*:\s*[A-Za-z_][\w.<>, ]*?)?\s*(?P<kw>:=|in\b)',
                r'for \g<n> \g<kw>', lines[d.line], count=1)
            masks[d.line] = mask_line(lines[d.line], LexState())
            pending.append((d.line, routine.name, d.names[0], 'assign'))
        else:
            for k in range(d.line, last + 1):
                lines[k] = None                # `var X: T;` becomes the hoist
        var_entries.append((f'  {render_type_list(d.names, t)}',
                            (routine.name, d.names[0], 'decl', d.line)))
        for name in d.names:
            record_type(types, manifest, path, routine, name, t, d.line)

    block: List[str] = []
    block_meta: List[BlockMeta] = []
    if type_entries:
        block.append('type')
        block_meta.append(None)
        for alias, text in type_entries:
            block.append(f'  {alias} = {text};')
            block_meta.append(None)
    if const_entries:
        block.append('const')
        block_meta.append(None)
        for text, meta in dedup_meta(const_entries):
            block.append(text)
            block_meta.append(meta)
    if var_entries:
        block.append('var')
        block_meta.append(None)
        for text, meta in dedup_meta(var_entries):
            block.append(text)
            block_meta.append(meta)

    return block, pending, block_meta, posts


def record_type(types: Dict[str, str], manifest: Dict[str, str], path: Path,
                routine: Routine, name: str, t: str, line: int) -> None:
    """Remember each guess so fixloop.py can correct it from FPC's diagnostics."""
    manifest[f'{path}:{routine.name}:{name}'] = t
    types[f'{path.as_posix()}:{line + 1}'] = t



# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('files', nargs='+')
    ap.add_argument('--types', default='types.json',
                    help='JSON sidecar of inferred types (refined by fixloop.py)')
    ap.add_argument('--overrides', default=None,
                    help='JSON sidecar of corrected types, keyed path:routine:name')
    ap.add_argument('--manifest', default='manifest.json')
    ap.add_argument('--returns', default=None,
                    help='JSON map of routine name -> declared return type, '
                         'used to type a hoisted variable assigned from a call')
    ap.add_argument('--fields', default=None,
                    help='JSON map of record/class field name -> type across '
                         'the whole tree, for reads of another unit\'s field')
    ap.add_argument('--linemap', default='linemap.json',
                    help='maps transformed line numbers back to routine:name, '
                         'so fixloop.py can attribute FPC diagnostics')
    ap.add_argument('--in-place', action='store_true')
    ap.add_argument('--out', default=None)
    ap.add_argument('--no-namespaces', action='store_true',
                    help='leave System.* unit names alone')
    args = ap.parse_args()

    known: Dict[str, str] = {}
    if Path(args.types).exists():
        known = json.loads(Path(args.types).read_text())
    overrides: Dict[str, str] = {}
    if args.overrides and Path(args.overrides).exists():
        overrides = json.loads(Path(args.overrides).read_text())
    manifest: Dict[str, str] = {}
    linemap: Dict[str, dict] = {}
    returns: Dict[str, str] = {}
    if args.returns and Path(args.returns).exists():
        returns = json.loads(Path(args.returns).read_text())
    tree_fields: Dict[str, str] = {}
    if args.fields and Path(args.fields).exists():
        tree_fields = json.loads(Path(args.fields).read_text())

    for f in args.files:
        p = Path(f)
        result = transform(p, known, manifest, overrides, linemap,
                           rewrite_namespaces=not args.no_namespaces,
                           returns=returns, tree_fields=tree_fields)
        if args.in_place:
            p.write_text(result, encoding='utf-8')
            print(f'port  {p}')
        else:
            dest = Path(args.out or '.') / p.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(result, encoding='utf-8')
            print(f'port  {p} -> {dest}')

    Path(args.types).write_text(json.dumps(known, indent=1, sort_keys=True))
    Path(args.manifest).write_text(json.dumps(manifest, indent=1, sort_keys=True))
    Path(args.linemap).write_text(json.dumps(linemap, indent=1, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
