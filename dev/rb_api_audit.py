#!/usr/bin/env python3
"""Static API audit for GDScript sources: catches engine calls that do not exist.

gdparse only checks syntax, so a call like `s.trim_left("_")` (no such String method --
that is the C# API) passes it and then kills the whole script at load time in Godot.
Every caller of the dead script then reports "Nonexistent function 'x' in base
'GDScript'", which points at the wrong file and is miserable to debug.

This script builds an allow-list from the class reference XMLs (doc/classes/*.xml of the
godot repo, one per class) plus everything the addon declares itself, then reports calls,
constants and property accesses outside that set.

Usage:
    python3 dev/rb_api_audit.py addons/rigbridge --docs <dir of class reference XMLs>

The class reference ships with the engine sources as `godot/doc/classes/*.xml`; point
$GODOT_CLASSREF (or --docs) at such a directory. Without a checkout, grab them with:

    gh api repos/godotengine/godot/git/trees/4.7?recursive=1 --jq ".tree[].path" |
        grep "^doc/classes/" | while read -r f; do
            gh api "repos/godotengine/godot/contents/$f?ref=4.7" --jq .content |
                base64 -d > "/tmp/gd47/$(basename $f)"; done
"""

import argparse
import glob
import os
import re
import sys

DYNAMIC = {
    "x", "y", "z", "xy", "xyz", "r", "g", "b", "a", "h", "s", "v",
    "normalized", "flipped", "width", "height", "text", "name", "owner",
    "process_mode", "visible", "modulate", "custom_minimum_size", "size",
    "position", "global_position", "script",
}


def load_allow(docs):
    named, constants, classes, members = set(), set(), set(), set()
    for path in glob.glob(os.path.join(docs, "*.xml")):
        classes.add(os.path.basename(path)[:-4].lstrip("@"))
        txt = open(path, encoding="utf-8", errors="replace").read()
        named |= set(re.findall(r'<(?:method|constructor|signal)\s+[^>]*name="([^"]+)"', txt))
        constants |= set(re.findall(r'<constant\s+name="([^"]+)"', txt))
        members |= set(re.findall(r'<member\s+name="([^"]+)"', txt))
        members |= set(re.findall(r'<property\s+name="([^"]+)"', txt))
        named |= set(re.findall(r'<return\s+type="([^"]+)"', txt))  # nested class names
    return named, constants, classes, members


def collect_own(addon):
    funcs, consts, classes, src, vars_, signals = set(), set(), set(), {}, set(), set()
    for path in glob.glob(os.path.join(addon, "**", "*.gd"), recursive=True):
        txt = open(path, encoding="utf-8").read()
        src[path] = txt
        funcs |= set(re.findall(r"^\s*(?:@\w+\s+)?(?:static\s+|remote\s+)*func\s+([A-Za-z_]\w*)", txt, re.M))
        consts |= set(re.findall(r"^\s*const\s+([A-Za-z_]\w*)", txt, re.M))
        classes |= set(re.findall(r"^\s*class\s+([A-Za-z_]\w*)", txt, re.M))
        vars_ |= set(re.findall(r"^\s*(?:@onready\s+)?(?:static\s+)?var\s+([A-Za-z_]\w*)", txt, re.M))
        signals |= set(re.findall(r"^\s*signal\s+([A-Za-z_]\w*)", txt, re.M))
    return funcs, consts, classes, src, vars_, signals


def strip_noise(line):
    """Remove comments and string literals so patterns only see real identifiers."""
    line = line.split("#", 1)[0]
    line = re.sub(r'"[^"]*"', lambda m: " " * len(m.group(0)), line)
    line = re.sub(r"'[^']*'", lambda m: " " * len(m.group(0)), line)
    return line


def main():
    ap = argparse.ArgumentParser(description="static GDScript engine-API audit")
    ap.add_argument("addon", nargs="?", default="addons/rigbridge")
    ap.add_argument("--docs", default=os.environ.get("GODOT_CLASSREF", "../godot/doc/classes"),
                    help="directory of class reference XML files (or $GODOT_CLASSREF)")
    args = ap.parse_args()

    if not os.path.isdir(args.docs):
        print("no class reference at %s; pass --docs /path/to/godot/doc/classes" % args.docs)
        return 2
    named, constants, classes, members = load_allow(args.docs)
    print("class reference: %s classes, %d methods known" % (len(classes), len(named)))
    funcs, consts, own_classes, src, own_vars, own_signals = collect_own(args.addon)
    allow_call = named | own_classes | classes | funcs | {"new", "free", "queue_free", "duplicate", "get_class", "is_class", "has_method", "call", "call_deferred", "set", "get", "emit_signal", "connect", "disconnect", "get_signal_list", "get_method_list", "get_property_list", "notification", "to_string"}
    allow_const = constants | consts | classes | own_classes
    allow_member = members | named | consts | funcs | own_vars | own_signals | DYNAMIC

    call_re = re.compile(r"(?:^|[^.\w$])(?:[A-Za-z_]\w*\.)+([a-z_]\w*)\s*\(")
    const_re = re.compile(r"\b([A-Z]\w*)\.([A-Z][A-Z_0-9]+)\b")
    member_re = re.compile(r"\b[a-z_]\w*\.([a-z_][a-z_0-9]{2,})(?![A-Za-z0-9_])(?!\s*[=([\[])")

    bad = {}
    for path, txt in src.items():
        for i, raw in enumerate(txt.splitlines(), 1):
            code = strip_noise(raw)
            where = "%s:%d" % (os.path.relpath(path, args.addon), i)
            for m in call_re.finditer(code):
                if m.group(1) not in allow_call:
                    bad.setdefault(m.group(1), []).append(where)
            for m in const_re.finditer(code):
                if m.group(1) in consts or m.group(1) in own_classes:
                    continue  # preload const -> our own module
                if m.group(2) not in allow_const:
                    bad.setdefault("%s.%s" % (m.group(1), m.group(2)), []).append(where)
            for m in member_re.finditer(code):
                if m.group(1) not in allow_member:
                    bad.setdefault("member:" + m.group(1), []).append(where)

    if not bad:
        print("OK - every call/constant/property resolves (%d allowed names)" % len(allow_call))
        return 0
    for name in sorted(bad):
        print("UNKNOWN %-30s %s" % (name, ", ".join(bad[name][:6])))
    print("\n%d unknown identifier(s) across %d site(s)" % (len(bad), sum(len(v) for v in bad.values())))
    return 1


if __name__ == "__main__":
    sys.exit(main())
