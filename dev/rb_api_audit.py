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
import base64
import glob
import json
import os
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

DYNAMIC = {
    "x", "y", "z", "xy", "xyz", "r", "g", "b", "a", "h", "s", "v",
    "normalized", "flipped", "width", "height", "text", "name", "owner",
    "process_mode", "visible", "modulate", "custom_minimum_size", "size",
    "position", "global_position", "script",
}


def fetch_classref(docs, ref="4.7", jobs=12):
    """Download doc/classes/*.xml of a godot ref into `docs` (api.github.com only)."""
    os.makedirs(docs, exist_ok=True)

    def api(url):
        req = urllib.request.Request(url, headers={"User-Agent": "rigbridge-dev"})
        with urllib.request.urlopen(req, timeout=90) as r:
            return r.read()

    tree = json.loads(api("https://api.github.com/repos/godotengine/godot/git/trees/%s?recursive=1" % ref))
    wanted = [e for e in tree["tree"] if e["path"].startswith("doc/classes/") and e["path"].endswith(".xml") and e["type"] == "blob"]

    def get(item):
        path, sha = item
        out = os.path.join(docs, os.path.basename(path))
        if os.path.exists(out) and os.path.getsize(out) > 200:
            return 0
        try:
            data = json.loads(api("https://api.github.com/repos/godotengine/godot/git/blobs/%s" % sha))
            open(out, "wb").write(base64.b64decode(data["content"]))
            return 1
        except Exception as exc:  # a rate limit or a 502 must not break the audit
            print("  skip %s (%s)" % (os.path.basename(path), exc), file=sys.stderr)
            return 0

    with ThreadPoolExecutor(jobs) as pool:
        n = sum(pool.map(get, [(e["path"], e["sha"]) for e in wanted]))
    print("fetched %d new files of %d into %s" % (n, len(wanted), docs))


def load_allow(docs):
    named, constants, classes, members = set(), set(), set(), set()
    ctors = {}
    for path in glob.glob(os.path.join(docs, "*.xml")):
        classes.add(os.path.basename(path)[:-4].lstrip("@"))
        txt = open(path, encoding="utf-8", errors="replace").read()
        named |= set(re.findall(r'<(?:method|constructor|signal)\s+[^>]*name="([^"]+)"', txt))
        constants |= set(re.findall(r'<constant\s+name="([^"]+)"', txt))
        members |= set(re.findall(r'<member\s+name="([^"]+)"', txt))
        members |= set(re.findall(r'<property\s+name="([^"]+)"', txt))
        named |= set(re.findall(r'<return\s+type="([^"]+)"', txt))  # nested class names
        cls_name = os.path.basename(path)[:-4]
        ranges = []
        for m in re.finditer(r'<constructor name="[^"]*">(.*?)</constructor>', txt, re.S):
            body = m.group(1)
            total = len(re.findall(r"<param\b", body))
            opt = len(re.findall(r'optional="true"', body))
            ranges.append((total - opt, total))
        if ranges:
            ctors[cls_name] = ranges
    return named, constants, classes, members, ctors


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


def split_top_commas(s):
    out, depth, quoted = [], 0, False
    cur = ""
    for ch in s:
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
    return out


def strip_noise(line):
    """Remove comments and string literals so patterns only see real identifiers."""
    line = re.sub(r'"[^"\n]*"', lambda m: " " * len(m.group(0)), line)
    line = line.split("#", 1)[0]
    return line


def main():
    ap = argparse.ArgumentParser(description="static GDScript engine-API audit")
    ap.add_argument("addon", nargs="?", default="addons/rigbridge")
    ap.add_argument("--docs", default=os.environ.get("GODOT_CLASSREF", "../godot/doc/classes"),
                    help="directory of class reference XML files (or $GODOT_CLASSREF)")
    ap.add_argument("--fetch", metavar="REF", nargs="?", const="4.7",
                    help="download the class reference for this godot ref (needs api.github.com)")
    args = ap.parse_args()

    if args.fetch:
        fetch_classref(args.docs, args.fetch)
    if not os.path.isdir(args.docs):
        print("no class reference at %s: pass --docs /path/to/godot/doc/classes, or --fetch 4.7" % args.docs)
        return 2
    named, constants, classes, members, ctors = load_allow(args.docs)
    print("class reference: %d classes, %d methods known" % (len(classes), len(named)))
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

    ctor_re = re.compile(r"\b([A-Z][A-Za-z_0-9]*)\s*\(")
    for path, txt in src.items():
        for i, raw in enumerate(txt.splitlines(), 1):
            code = strip_noise(raw)
            for m in ctor_re.finditer(code):
                cls = m.group(1)
                if cls not in ctors or cls in consts or cls in own_classes:
                    continue
                j, depth = m.end() - 1, 0
                while j < len(code):
                    if code[j] in "([{":
                        depth += 1
                    elif code[j] in ")]}":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                inner = code[m.end():j].strip()
                n = 0 if not inner else len(split_top_commas(inner))
                if any(lo <= n <= hi for lo, hi in ctors[cls]):
                    continue
                bad.setdefault("ctor:%s/%d-args" % (cls, n), []).append(
                    "%s:%d %s(...) accepts %s" % (os.path.relpath(path, args.addon), i, cls, sorted(ctors[cls])))

    if not bad:
        print("OK - every call/constant/property resolves (%d allowed names)" % len(allow_call))
        return 0
    for name in sorted(bad):
        print("UNKNOWN %-30s %s" % (name, ", ".join(bad[name][:6])))
    print("\n%d unknown identifier(s) across %d site(s)" % (len(bad), sum(len(v) for v in bad.values())))
    return 1


if __name__ == "__main__":
    sys.exit(main())
