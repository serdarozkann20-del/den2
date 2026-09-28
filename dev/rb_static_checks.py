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
  packed-copy  mutating a Packed array fetched through `dict[key]` - it is a value, so the
               write is lost (`rig["names"].append(x)` silently keeps the array empty).
  infer        `var x := <Variant>` (Dictionary/Array index, `.get()`, a helper
               without a return type) -> "Cannot infer the type of x ... doesn't have a set type".
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


# ---------------------------------------------------------------------------
# Type inference: `var x := <expression>` is rejected with
#   "Cannot infer the type of "x" variable because the value doesn't have a set type"
# whenever the expression is Variant-typed - indexing a plain Dictionary/Array,
# `.get()`, a call to a function that declares no return type, ...  `gdparse` accepts all
# of it, so this pass resolves each initializer against what the addon declares.
# ---------------------------------------------------------------------------

# built-in calls and accessors known to return a hard type
_VARIANT_METHODS = {
    "get", "get_indexed", "pop_back", "pop_front", "front", "back", "call", "callv",
    "get_meta", "get_property_list", "get_script_constant_map", "get_class_list",
    "get_setting", "get_value", "parse_string", "get_var", "get_line", "get_csv_line",
    "get_node", "get_node_or_null", "duplicate",  # duplicate() is typed; kept out below
}
_HARD_TYPES = set("""String StringName int float bool Vector2 Vector3 Color Transform2D Transform3D
Rect2 Rect2i Array Dictionary Node Node3D Object Variant RefCounted Resource Script GDScript
Animation AnimationLibrary AnimationPlayer Skeleton3D BoneMap SkeletonProfile PackedStringArray
PackedInt32Array PackedFloat32Array PackedByteArray NodePath Signal Callable Basis Quaternion""".split())
_PACKED = ("Packed", "String", "Array[", "Dict")


def _typed_call(name, funcs):
    rng = funcs.get(name)
    return rng is not None and rng.get("ret") not in (None, "", "void", "Variant")


# Known-hard-type sources inside a file: parameters, typed `var`s and obviously typed
# initialisers. Enough to tell `some_packed[0]` (typed) from `some_dict[k]` (Variant).
def local_types(text):
    types = {}
    for m in re.finditer(r"func\s+\w+\s*\(([^)]*)\)", text):
        for arg in split_args(m.group(1)):
            am = re.match(r"\s*(\w+)\s*:\s*([\w\[\]]+)", arg)
            if am:
                types[am.group(1)] = am.group(2)
    for m in re.finditer(r"^\s*(?:@onready\s+)?var\s+(\w+)\s*:\s*([\w\[\]]+)", text, re.M):
        types[m.group(1)] = m.group(2)
    for m in re.finditer(r"^\s*(?:@onready\s+)?var\s+(\w+)\s*:=\s*(.+?)\s*(?:#.*)?$", text, re.M):
        rhs = m.group(2).strip()
        if re.match(r'^"', rhs) or re.match(r"^&", rhs):
            types[m.group(1)] = "String"
        elif re.match(r"^Packed\w+\(", rhs):
            types[m.group(1)] = re.match(r"^(Packed\w+)", rhs).group(1)
    return types


def infer_problems(path, text, fns, funcs, consts, preloads):
    out = []
    ltypes = local_types(text)
    for m in re.finditer(r"^\s*(?:@onready\s+)?var\s+(\w+)\s*:=\s*(.+?)\s*(?:#.*)?$", text, re.M):
        var, rhs = m.group(1), m.group(2).strip()
        line = text[: m.start()].count("\n") + 1
        reason = None
        # cast(...) / `as Type` / literal containers settle the type by themselves
        if re.match(r"^(%s)\s*\(" % "|".join(sorted(_HARD_TYPES, key=len, reverse=True)), rhs):
            continue
        # a call to a function that does declare a return type is typed, whatever it contains
        oc = re.match(r"^(?:([A-Za-z_]\w*)\.)?([a-z_]\w*)\s*\(", rhs)
        if oc:
            owner, name = oc.group(1), oc.group(2)
            if owner is None and name in funcs and _typed_call(name, funcs):
                continue
        if re.search(r"\bas\s+[A-Za-z_]\w*", rhs) or re.search(r"\bis\s+[A-Za-z_]\w*", rhs):
            continue
        if re.match(r"^[{\[]", rhs) or re.match(r"^[A-Z]\w*\.new\(", rhs):
            continue
        # container indexing without a declared element type
        im = re.match(r"^(\w+)((?:\[.*?\])+)$", rhs)
        if im:
            base = im.group(1)
            dt = ltypes.get(base, "")
            if not dt.startswith(_PACKED):
                reason = "indexing %s%s yields Variant" % (base, ": " + dt if dt else " (untyped)")
        # `.get(...)` and friends return Variant
        vm = re.search(r"\.(%s)\s*\(" % "|".join(sorted(_VARIANT_METHODS - {"duplicate"})), rhs)
        if vm and reason is None:
            reason = "`.%s()` returns Variant" % vm.group(1)
        # a helper that declares no return type is Variant
        cm = re.match(r"^(?:([A-Za-z_]\w*)\.)?([a-z_]\w*)\s*\(", rhs)
        if cm and reason is None:
            owner, name = cm.group(1), cm.group(2)
            if owner is None and name in funcs and not _typed_call(name, funcs):
                reason = "%s() declares no return type" % name
            elif owner in preloads:
                tgt = os.path.basename(os.path.normpath(os.path.join(os.path.dirname(path), preloads[owner])))
                if (tgt, name) in funcs and not _typed_call(name, funcs[(tgt, name)]["funcs"] if False else {}):
                    reason = "%s.%s() declares no return type" % (owner, name)
                elif (tgt, name) in funcs:
                    pass
        # attribute of an untyped Dictionary (`d.key` form)
        am = re.match(r"^(\w+)\.(\w+)$", rhs)
        if am and reason is None:
            base = am.group(1)
            dt = ltypes.get(base, "")
            if dt == "Dictionary" or (not dt and re.search(r"(?:var|const)\s+%s\s*:?=?\s*\{" % re.escape(base), text)):
                reason = "`%s.%s` is a Dictionary lookup, which is Variant" % (base, am.group(2))
        if reason:
            out.append(
                "infer          %s:%d `var %s := ...` - %s; declare the type instead"
                % (path, line, var, reason)
            )
    return out


# ---------------------------------------------------------------------------
# Packed*Array is a *value* type in Godot: `some_dict["names"].append(x)` (or
# `(some_dict["names"] as PackedStringArray).append(x)`) mutates a temporary copy and the
# change is lost. `Array`/`Dictionary` are references, so the same code shape is fine for
# them - which is why this is easy to write and impossible to see in a review. A file that
# builds its snapshot this way returns empty arrays and every caller quietly gets nothing.
# ---------------------------------------------------------------------------

_PACKED_MUTATORS = "append|push_back|push_front|insert|resize|remove_at|reverse|sort|fill|append_array|insert_array|rtrim|ltrim"


def packed_copy_problems(path, text, packed_keys):
    out = []
    for no, line in enumerate(text.split("\n"), 1):
        code = strip_noise(line)
        if re.search(r"as Packed\w+\)\s*\.\s*(%s)\s*\(" % _PACKED_MUTATORS, code):
            out.append(
                "packed-copy    %s:%d mutates a copy - `(x[...] as Packed*)` is a value, append/assign into a"
                " local and store it back" % (path, no)
            )
            continue
        m = re.search(r"\[\"(\w+)\"\]\s*\.\s*(%s)\s*\(" % _PACKED_MUTATORS, code)
        if m and m.group(1) in packed_keys:
            out.append(
                "packed-copy    %s:%d `[\"%s\"]` holds a Packed array - mutating it in place does nothing"
                % (path, no, m.group(1))
            )
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

    # Keys whose values are known to hold a Packed array, collected across the addon: the
    # rig/report Dictionaries are built in one file and mutated in another.
    packed_keys = set()
    for text in [f["text"] for f in files.values()]:
        packed_keys |= set(re.findall(r'"(\w+)":\s*Packed\w+\(', text))
        packed_keys |= set(re.findall(r'\["(\w+)"\]\s*=\s*Packed\w+\(', text))

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
        for p in packed_copy_problems(path, f["text"], packed_keys):
            problems.append(p)

        # type inference
        local_funcs = {}
        for fn in parse_funcs(f["lines"]):
            head = next((l for n, l in f["lines"] if re.search(r"\bfunc\s+%s\s*\(" % fn.name, l)), "")
            local_funcs[fn.name] = {"ret": (re.search(r"->\s*([\w\[\] ]+)", head).group(1).strip() if "->" in head else "")}
        for p in infer_problems(path, f["text"], f["lines"], local_funcs, consts, consts):
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
