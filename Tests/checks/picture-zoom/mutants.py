# One-line mutants of iOSClient/PictureZoom.swift: each must make Tests/checks/picture-zoom fail.
import os, subprocess, sys, tempfile
root = sys.argv[1]
src = os.path.join(root, "iOSClient/PictureZoom.swift")
here = os.path.dirname(os.path.abspath(__file__))
MUTANTS = [
    ("no upper limit", "min(max(scale * factor, 1), Self.maxScale)", "max(scale * factor, 1)"),
    ("no lower limit", "min(max(scale * factor, 1), Self.maxScale)", "min(scale * factor, Self.maxScale)"),
    ("the pinch ignores its focus", "offset = CGPoint(x: (focus.x - c.x) - k * (focus.x - c.x - offset.x),", "offset = CGPoint(x: k * offset.x,"),
    ("no clamp", "        clamp(size)\n    }\n\n    /// Two fingers", "    }\n\n    /// Two fingers"),
    ("no snap back", "if scale < Self.snapBack { self = PictureZoom() }", "if scale < 1 { self = PictureZoom() }"),
    ("the transform moves, then scales", "CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: scale, y: scale)", "CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: offset.x, y: offset.y)"),
    ("the rect forgets the offset", "y: c.y + offset.y + (rect.minY - c.y) * scale,", "y: c.y + (rect.minY - c.y) * scale,"),
    ("the right edge moves the wrong way", "d.x = -step }", "d.x = step }"),
]
caught = 0
original = open(src).read()
for name, a, b in MUTANTS:
    if original.count(a) != 1:
        print(f"{name}: NOT APPLIED (pattern found {original.count(a)} times)"); continue
    with tempfile.TemporaryDirectory() as t:
        m = os.path.join(t, "PictureZoom.swift"); open(m, "w").write(original.replace(a, b))
        out = os.path.join(t, "check")
        c = subprocess.run(["swiftc", "-O", m, os.path.join(here, "main.swift"), "-o", out], capture_output=True, text=True)
        if c.returncode != 0: print(f"{name}: did not compile"); continue
        r = subprocess.run([out], capture_output=True, text=True)
        fails = r.stdout.count("FAIL")
        if r.returncode != 0: caught += 1; print(f"{name}: caught ({fails} FAIL lines)")
        else: print(f"{name}: SURVIVED")
print(f"mutants caught: {caught} of {len(MUTANTS)}")
