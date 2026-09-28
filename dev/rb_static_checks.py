#!/usr/bin/env python3
"""Local static checks for the addon - the mistakes the engine's analyzer rejects but
`gdparse` (syntax only) accepts. Run this before bothering a Godot editor:

    python3 dev/rb_static_checks.py [addons/rigbridge]

Checks
  dup-var      `var x` twice in the same block -> "Identifier 'x' already declared".
  arity        a call passes an argument count the (static) function cannot accept.
  ctor-args    a Godot 3 constructor overload that 4.x removed (e.g.
               `NodePath(names, subnames, absolute)`), when `--classref` points at
               doc/classes; see rb_api_audit.py for how to get them.
  return-path  a `-> Type` function whose body never returns at its own block level.
  scope        a local used in a sibling block - GDScript scoping rules, which `gdparse`
               does not apply, so a renamed loop variable can silently outlive its block.

A file with any of these does not compile, and Godot then reports `Nonexistent function
'...' in base 'GDScript'` at *every* caller of it - which is how a single bad line turns
into 40 errors in an unrelated file.
"""

import glob
import os
import re
import sys

KEYWORDS = {
    "if", "elif", "else", "for", "while", "match", "break", "continue", "pass", "return", "var", "const",
    "static", "func", "class", "class_name", "enum", "signal", "extends", "in", "is", "as", "not", "and", "or",
    "xor", "await", "yield", "assert", "preload", "load", "true", "false", "null", "self", "super", "void",
    "tool", "when", "ns",
}


def strip_noise(line):
    # strings first: a `#` inside a string ("see (#123782)") is not a comment
    line = re.sub(r'"(?:[^"\\\n]|\\.)*"', lambda m: '"' + " " * (len(m.group(0)) - 2) + '"', line)
    line = line.split("#", 1)[0]
    return line


def logical_lines(text):
    """Join continuation lines so calls spanning several lines are seen as one."""
    out = []  # (start_line_no, code)
    buf, buf_no, depth = "", 0, 0
    for no, raw in enumerate(text.split("\n"), 1):
        code = strip_noise(raw)
        if not buf:
            if not code.strip():
                continue
            buf_no = no
            buf = code
        else:
            buf += " " + code.strip()
        for ch in code:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
        if depth <= 0:
            out.append((buf_no, buf))
            buf, depth = "", 0
    if buf:
        out.append((buf_no, buf))
    return out


def split_args(inner):
    if not inner.strip():
        return []
    out, depth, quoted, cur = [], 0, False, ""
    for ch in inner:
        if ch == '"':
            quoted = not quoted
        if not quoted:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            elif ch == "," and depth == 0:
                out.append(cur)
                cur = ""
                continue
        cur += ch
    out.append(cur)
    return [x for x in out if x.strip()]


def indent_of(code):
    return len(code) - len(code.lstrip("\t"))


class Func:
    def __init__(self, name, lineno, indent, params):
        self.name = name
        self.lineno = lineno
        self.indent = indent
        self.params = params
        self.body = []  # (lineno, code, indent)


def parse_funcs(lines):
    funcs = []
    cur = None
    for no, code in lines:
        m = re.match(r"\s*(?:@\w+\s+)?(?:static\s+)?func\s+([A-Za-z_]\w*)\s*\(", code)
        ind = indent_of(code)
        if m and ind == 0:
            inner = code[code.index("(", m.start(1)):]
            inner = inner[inner.index("(") + 1: matching_close(inner, 0)]
            params = []
            for p in split_args(inner):
                pm = re.match(r"\s*([A-Za-z_]\w*)", p)
                if pm:
                    params.append((pm.group(1), "=" in p))
            cur = Func(m.group(1), no, ind, params)
            funcs.append(cur)
            continue
        if cur is not None:
            if ind <= cur.indent and code.strip():
                cur = None
                continue
            cur.body.append((no, code, ind))
    return funcs


def matching_close(s, start):
    depth = 0
    for i in range(start, len(s)):
        if s[i] in "([{":
            depth += 1
        elif s[i] in ")]}":
            depth -= 1
            if depth == 0:
                return i
    return len(s) - 1


def block_paths(text):
    """line_no -> tuple of the line numbers of the block openers that enclose that line."""
    paths = {}
    stack = []
    for no, raw in enumerate(text.split("\n"), 1):
        code = strip_noise(raw)
        if not code.strip():
            continue
        ind = len(raw) - len(raw.lstrip("\t"))
        while stack and stack[-1][0] >= ind:
            stack.pop()
        paths[no] = tuple(s[1] for s in stack)
        if code.rstrip().endswith(":"):
            stack.append((ind, no))
    return paths


# GDScript scopes a local to the block that declares it, so a name declared in one
# `for`/`if` block is a parse error in the next sibling block. `gdparse` (syntax only)
# accepts it - this pass catches it, and it is an easy mistake when two loops share a
# variable name.
def scope_problems(path, text, fns):
    out = []
    paths = block_paths(text)
    file_scope = set(re.findall(r"^(?:@onready\s+)?(?:const|var)\s+(\w+)", text, re.M))
    for fn in fns:
        decl = {}
        for no, code, ind in fn.body:
            stmt = strip_noise(code).strip()
            dm = re.match(r"var\s+([A-Za-z_]\w*)", stmt) or re.match(r"for\s+([A-Za-z_]\w*)\s+in\b", stmt)
            if dm:
                if dm.group(1) in file_scope:
                    continue
                dp = paths.get(no, ())
                if stmt.startswith("for "):
                    dp = dp + (no,)  # a loop variable lives in the loop body
                decl[dm.group(1)] = (no, dp)  # a later declaration shadows in its own block
                continue
            for name in re.findall(r"\b([a-z_]\w*)\b", stmt):
                if name not in decl or name in KEYWORDS:
                    continue
                dl, dp = decl[name]
                if dl >= no:
                    continue
                if paths.get(no, ())[: len(dp)] != dp:
                    out.append(
                        "scope          %s:%d `%s` is used outside the block that declares it (declared on line %d)"
                        % (path, no, name, dl)
                    )
                    decl[name] = (no, paths.get(no, ()))
    return out


def main():
    addon = sys.argv[1] if len(sys.argv) > 1 else "addons/rigbridge"
    classref = os.environ.get("GODOT_CLASSREF") or (sys.argv[2] if len(sys.argv) > 2 else "")
    ctors = {}
    if classref and os.path.isdir(classref):
        for path in glob.glob(os.path.join(classref, "*.xml")):
            cls = os.path.basename(path)[:-4]
            txt = open(path, encoding="utf-8", errors="replace").read()
            ranges = []
            for m in re.finditer(r'<constructor name="[^"]*">(.*?)</constructor>', txt, re.S):
                body = m.group(1)
                total = len(re.findall(r"<param\b", body))
                opt = len(re.findall(r'optional="true"', body))
                ranges.append((total - opt, total))
            if ranges:
                ctors[cls] = ranges

    files = {}
    for path in sorted(glob.glob(os.path.join(addon, "**", "*.gd"), recursive=True)):
        text = open(path).read()
        files[path] = {"lines": logical_lines(text), "text": text}

    # signatures of everything defined in the addon
    sigs = {}
    for path, f in files.items():
        for fn in parse_funcs(f["lines"]):
            lo = sum(1 for n, o in fn.params if not o)
            hi = len(fn.params)
            sigs.setdefault((os.path.basename(path), fn.name), (lo, hi))
    by_name = {}
    for (fname, n), rng in sigs.items():
        by_name.setdefault(n, []).append((fname, rng))

    problems = []
    for path, f in files.items():
        base = os.path.basename(path)
        consts = dict(
            (m.group(1), m.group(2))
            for m in re.finditer(r"^\s*const\s+(\w+)\s*:=\s*preload\(\"([^\"]+)\"\)", f["text"], re.M)
        )

        # dup-var
        for fn in parse_funcs(f["lines"]):
            seen = {}
            for no, code, ind in fn.body:
                for m in re.finditer(r"\bvar\s+([A-Za-z_]\w*)", code):
                    key = (ind, m.group(1))
                    if key in seen:
                        problems.append(
                            "dup-var      %s:%d '%s' declared twice at the same indent in %s() (also line %d)"
                            % (path, no, m.group(1), fn.name, seen[key])
                        )
                    seen[key] = no

            # return-path - only "no return anywhere" is reported: a body that is a single
            # `match` with a `_` branch returning in each arm is accepted by the analyzer, and
            # reasoning about every shape that is legal here is not worth the false alarms.
            head = next((l for n, l in f["lines"] if re.search(r"\bfunc\s+%s\s*\(" % fn.name, l)), "")
            m = re.search(r"->\s*([A-Za-z_]\w*)", head)
            if m and m.group(1) != "void" and fn.body:
                if not any(re.match(r"\s*return\b", c) for _, c, i in fn.body):
                    problems.append(
                        "return-path    %s:%d %s() -> %s has no `return` at the function's own indent"
                        % (path, fn.lineno, fn.name, m.group(1))
                    )

        for p in scope_problems(path, f["text"], parse_funcs(f["lines"])):
            problems.append(p)

        # arity
        for no, code in f["lines"]:
            for m in re.finditer(r"(?<![\w.])(?:([A-Za-z_]\w*)\.)?([a-z_]\w*)\s*\(", code):
                owner, name = m.group(1), m.group(2)
                if name in KEYWORDS:
                    continue
                inner = code[m.end() - 1:]
                inner = inner[inner.index("(") + 1: matching_close(inner, 0)]
                n = len(split_args(inner))
                if owner and owner in consts:
                    key = (os.path.basename(os.path.normpath(os.path.join(os.path.dirname(path), consts[owner]))), name)
                    rng = sigs.get(key)
                    what = "%s.%s()" % (owner, name)
                elif owner is None:
                    cands = [r for fname, r in by_name.get(name, []) if fname == base]
                    rng = cands[0] if len(cands) == 1 else None
                    what = "%s()" % name
                else:
                    continue
                if rng and not (rng[0] <= n <= rng[1]):
                    problems.append(
                        "arity          %s:%d %s called with %d arg(s), signature expects %d..%d"
                        % (path, no, what, n, rng[0], rng[1])
                    )
                if owner is None and not ctors:
                    continue
            for m in re.finditer(r"\b([A-Z]\w*)\s*\(", code):
                cls = m.group(1)
                if cls not in ctors:
                    continue
                inner = code[m.end() - 1:]
                inner = inner[inner.index("(") + 1: matching_close(inner, 0)]
                n = len(split_args(inner))
                if not any(lo <= n <= hi for lo, hi in ctors[cls]):
                    problems.append(
                        "ctor-args      %s:%d %s(...) with %d arg(s); %s only accepts %s"
                        % (path, no, cls, n, cls, sorted(ctors[cls]))
                    )

    for p in sorted(set(problems)):
        print(p)
    if not problems:
        note = "with class-ref ctor checks" if ctors else "(no --classref: ctor overloads unchecked)"
        print("OK - %d files clean %s" % (len(files), note))
        return 0
    print("\n%d problem(s)" % len(set(problems)))
    return 1


if __name__ == "__main__":
    sys.exit(main())
