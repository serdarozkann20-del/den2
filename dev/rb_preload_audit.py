#!/usr/bin/env python3
"""Check every `Const.method(` / `Const.CONST` access against the preloaded file, and that
no preload path is absolute.

The engine reports a missing member of a preloaded script at the *call site*
("Nonexistent function ... in base 'GDScript'"), which is painful to find by hand.
This resolves each preload const to its file and verifies the member exists there.
"""
import glob, os, re, sys

addon = sys.argv[1] if len(sys.argv) > 1 else "addons/rigbridge"
src = {p: open(p).read() for p in glob.glob(os.path.join(addon, "**", "*.gd"), recursive=True)}

def members(text):
    funcs = set(re.findall(r'^\s*(?:@\w+\s+)?(?:static\s+)?func\s+([A-Za-z_]\w*)', text, re.M))
    consts = set(re.findall(r'^\s*const\s+([A-Za-z_]\w*)', text, re.M))
    statics = set(re.findall(r'^\s*static var\s+([A-Za-z_]\w*)', text, re.M))
    classes = set(re.findall(r'^\s*class\s+([A-Za-z_]\w*)', text, re.M))
    return funcs, consts | statics | classes

problems = []
for path in list(src):
    for pm in re.finditer(r'preload\(\s*"([^"]+)"', src[path]):
        if src[path][:pm.start()].split("\n")[-1].lstrip().startswith("#"):
            continue  # an example in a comment, not code
        dep = pm.group(1)
        if dep.startswith(("res://", "user://", "/")):
            ln = src[path][:pm.start()].count("\n") + 1
            problems.append("%s:%d absolute preload '%s' - keep it relative so the addon "
                            "still works when the folder moves" % (os.path.relpath(path, addon), ln, dep))
for path, text in src.items():
    preloads = {}
    for m in re.finditer(r'^\s*const\s+(\w+)\s*:=\s*preload\(\s*"([^"]+)"', text, re.M):
        if m.group(0).lstrip().startswith("#"):
            continue
        preloads[m.group(1)] = os.path.normpath(os.path.join(os.path.dirname(path), m.group(2)))
    for name, target in preloads.items():
        if target not in src:
            problems.append(f"{os.path.relpath(path, addon)}: preload {name} -> {target} NOT IN ADDON")
    base = os.path.dirname(path)
    for m in re.finditer(r'^\s*(\w+)\s*:=\s*preload\(\s*"([^"]+)"', text, re.M):
        target = os.path.normpath(os.path.join(base, m.group(2)))
        if target not in src:
            problems.append(f"{os.path.relpath(path, addon)}: preload {m.group(1)} -> missing file")
    for m in re.finditer(r'\b(RB\w+)\.([a-zA-Z_]\w*)', text):
        cls, mem = m.group(1), m.group(2)
        if cls not in preloads:
            continue
        target = preloads[cls]
        if target not in src:
            continue
        funcs, consts = members(src[target])
        if mem in funcs or mem in consts or mem == "new":
            continue
        ln = text[:m.start()].count("\n") + 1
        problems.append(f"{os.path.relpath(path, addon)}:{ln} {cls}.{mem} not in {os.path.basename(target)}")

for p in sorted(set(problems)):
    print(p)
if not problems:
    print(f"OK - every preload const member resolves ({len(src)} files)")
