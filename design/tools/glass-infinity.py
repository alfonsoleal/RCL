# Writes the glass infinity into design/AppIcon.svg: the curve projected as InfinityMotion
# projects it (yaw 0.25, pitch 1.0), then strokes stacked into a glass tube with its light.
import math, sys
p = 'design/AppIcon.svg'; s = open(p).read()
W, cx, cy, A = 1024, 512, 770, 262
def point(f):
    # An open infinity, its loops as tall as the reference's, then turned a few degrees and the
    # left loop brought forward a little (larger), as Loop's tube sits in its own view.
    u = f * 2 * math.pi; s_ = math.sin(u); k = 1 + s_ * s_
    x = A * math.cos(u) / k; y = A * 1.05 * s_ * math.cos(u) / k
    near = 1 + 0.09 * (-x / A)
    x, y = x * near, y * near
    t = math.radians(-6)
    return cx + x * math.cos(t) - y * math.sin(t), cy + x * math.sin(t) + y * math.cos(t)
pts = [point(i / 360) for i in range(361)]
d = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts) + " Z"
lf = float(sys.argv[1]) if len(sys.argv) > 1 else 0.03
lx, ly = point(lf)
tube = f'''<!-- layer 3: the glass infinity of RCL's connect screen (Loop's tube): a halo, the bright
     rim, the translucent body, a reflection along it, and the light glowing at the right loop -->
<defs>
<filter id="halo" x="-30%" y="-60%" width="160%" height="220%"><feGaussianBlur stdDeviation="14"></feGaussianBlur></filter>
<filter id="soft" x="-10%" y="-20%" width="120%" height="140%"><feGaussianBlur stdDeviation="2.2"></feGaussianBlur></filter>
<radialGradient id="luz"><stop offset="0" stop-color="#FFFFFF"></stop><stop offset="0.22" stop-color="#F2FFF4"></stop>
<stop offset="0.45" stop-color="#5BEA74" stop-opacity="0.55"></stop><stop offset="1" stop-color="#00D749" stop-opacity="0"></stop></radialGradient>
</defs>
<path d="{d}" fill="none" stroke="#00D749" stroke-width="56" opacity="0.30" filter="url(#halo)"></path>
<path d="{d}" fill="none" stroke="#4BE062" stroke-width="50" stroke-linejoin="round" filter="url(#soft)"></path>
<path d="{d}" fill="none" stroke="#2C6B37" stroke-width="40" stroke-linejoin="round" opacity="0.92"></path>
<path d="{d}" fill="none" stroke="#5FBF6C" stroke-width="40" stroke-linejoin="round" opacity="0.35"></path>
<path d="{d}" fill="none" stroke="#E8FFEC" stroke-width="3.5" stroke-linejoin="round" opacity="0.45" transform="translate(0 -6)"></path>
<circle cx="{lx:.1f}" cy="{ly:.1f}" r="78" fill="url(#luz)"></circle>
<circle cx="{lx:.1f}" cy="{ly:.1f}" r="12" fill="#FFFFFF"></circle>
'''
start = s.index('<!-- layer 3'); end = s.index('</g>\n</svg>')
s = s[:start] + tube + s[end:]
open(p, 'w').write(s)
