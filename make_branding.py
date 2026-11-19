"""Creates the Saheli Safe icon and applies the name and loading screen.

Run from the project root:
    pip install pillow
    python3 make_branding.py
Safe to run more than once.
"""
import json
import math
import pathlib
import re

try:
    from PIL import Image, ImageDraw
except ImportError:
    raise SystemExit("Pillow is missing. Run:  pip install pillow   and try again.")

root = pathlib.Path(__file__).resolve().parent
web = root / 'web'
if not web.exists():
    raise SystemExit("Could not find the web folder. Run this from the project root.")
(web / 'icons').mkdir(exist_ok=True)


def gradient(size, c1, c2):
    img = Image.new('RGB', (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
    return img


def shield_points(S):
    pts = [(0.50 * S, 0.17 * S), (0.80 * S, 0.28 * S), (0.80 * S, 0.52 * S)]
    for i in range(1, 25):
        t = i / 24
        x = (1 - t) ** 2 * 0.80 + 2 * (1 - t) * t * 0.78 + t ** 2 * 0.50
        y = (1 - t) ** 2 * 0.52 + 2 * (1 - t) * t * 0.74 + t ** 2 * 0.86
        pts.append((x * S, y * S))
    for i in range(1, 25):
        t = i / 24
        x = (1 - t) ** 2 * 0.50 + 2 * (1 - t) * t * 0.22 + t ** 2 * 0.20
        y = (1 - t) ** 2 * 0.86 + 2 * (1 - t) * t * 0.74 + t ** 2 * 0.52
        pts.append((x * S, y * S))
    pts.append((0.20 * S, 0.28 * S))
    return pts


def heart_points(cx, cy, width):
    k = width / 32.0
    pts = []
    for i in range(361):
        t = math.radians(i)
        x = 16 * math.sin(t) ** 3
        y = (13 * math.cos(t) - 5 * math.cos(2 * t)
             - 2 * math.cos(3 * t) - math.cos(4 * t))
        pts.append((cx + x * k, cy - y * k))
    return pts


def make_icon(size, maskable):
    S = size * 4
    base = gradient(S, (236, 64, 122), (173, 20, 87)).convert('RGBA')
    if not maskable:
        mask = Image.new('L', (S, S), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            (0, 0, S - 1, S - 1), radius=int(S * 0.22), fill=255)
        base.putalpha(mask)
    d = ImageDraw.Draw(base)
    d.polygon(shield_points(S), fill=(255, 255, 255, 255))
    d.polygon(heart_points(0.5 * S, 0.505 * S, 0.30 * S), fill=(214, 40, 100, 255))
    return base.resize((size, size), Image.LANCZOS)


for s in (192, 512):
    make_icon(s, False).save(web / 'icons' / f'Icon-{s}.png')
    make_icon(s, True).save(web / 'icons' / f'Icon-maskable-{s}.png')
make_icon(64, False).save(web / 'favicon.png')
print('Icons created.')

# index.html: title, description, theme colour, loading screen
index = web / 'index.html'
html = index.read_text(encoding='utf-8')
html = re.sub(r'<title>.*?</title>', '<title>Saheli Safe</title>', html, flags=re.S)
html = re.sub(r'(<meta name="description" content=")[^"]*(")',
              lambda m: m.group(1) + 'Saheli Safe: a one-tap women safety app' + m.group(2), html)
html = re.sub(r'(<meta name="apple-mobile-web-app-title" content=")[^"]*(")',
              lambda m: m.group(1) + 'Saheli Safe' + m.group(2), html)
if 'name="theme-color"' not in html:
    html = html.replace('</head>', '  <meta name="theme-color" content="#C2185B">\n</head>', 1)

SPLASH = '''
<div id="splash" style="position:fixed;top:0;right:0;bottom:0;left:0;z-index:9999;display:flex;flex-direction:column;align-items:center;justify-content:center;background:linear-gradient(#FCE4EC,#ffffff);font-family:Arial,Helvetica,sans-serif;transition:opacity .4s ease;">
  <img src="icons/Icon-192.png" width="96" height="96" alt="" style="border-radius:24px;box-shadow:0 8px 24px rgba(194,24,91,.35);">
  <div style="margin-top:20px;font-size:26px;font-weight:700;color:#C2185B;">Saheli Safe</div>
  <div style="margin-top:8px;font-size:14px;color:#777777;">Loading...</div>
</div>
'''
SCRIPT = '''
<script>
  function hideSplash() {
    var s = document.getElementById('splash');
    if (!s) return;
    s.style.opacity = '0';
    setTimeout(function () { if (s.parentNode) s.parentNode.removeChild(s); }, 450);
  }
  window.addEventListener('flutter-first-frame', hideSplash);
  setTimeout(hideSplash, 20000);
</script>
'''
if 'id="splash"' not in html:
    html, n = re.subn(r'(<body[^>]*>)', lambda m: m.group(1) + SPLASH, html, count=1)
    if n == 0:
        raise SystemExit("Could not find the <body> tag in web/index.html.")
    html = html.replace('</body>', SCRIPT + '</body>', 1)
    print('Loading screen added.')
else:
    print('Loading screen was already there.')
index.write_text(html, encoding='utf-8')

# manifest.json: name and colours
manifest = web / 'manifest.json'
data = json.loads(manifest.read_text(encoding='utf-8'))
data['name'] = 'Saheli Safe'
data['short_name'] = 'Saheli Safe'
data['description'] = 'A one-tap women safety app'
data['background_color'] = '#FCE4EC'
data['theme_color'] = '#C2185B'
manifest.write_text(json.dumps(data, indent=4), encoding='utf-8')
print('Manifest updated.')
print('Done. Run the app again and hard refresh the page.')
