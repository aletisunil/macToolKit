#!/usr/bin/env python3
"""Reads the ScrollView test app's log (see scrollview.swift) for the Smooth
Scrolling E2E checks.

  scrollstats.py stats <log> <from-line>
      One line of key=value facts about everything logged after <from-line>:
        dx, dy     how far the canvas moved, in points
        moves      how many separate positions it went through
        raw        wheel events that reached the app unsmoothed (line based)
        precise    pixel-precise wheel events that reached the app
        ms         first to last movement, in milliseconds
        flips      how often the vertical motion changed direction
        mods       modifier keys seen on the events ("-" for none)
        lx, ly     whole lines the events carried, summed (CGEvent line field)
        steps      events whose NSEvent deltaX/deltaY is not zero - one wheel
                   report each in a terminal app with mouse reporting

  scrollstats.py chart <log> <out.svg> <panel> ...
      Distance scrolled over time as a self-contained SVG, one panel per
      <panel> argument, each with its own scale:
        "<panel title>|<series title>:<from-line>:<to-line>|..."
      Distance is signed (back is negative), along whichever axis moved.
      Also writes <out>.csv with every point.
"""
import sys


def parse(path):
    with open(path) as f:
        return [line.split() for line in f if line.strip()]


def positions(lines):
    return [(float(l[1]), float(l[2]), float(l[3])) for l in lines if l[0] == "P"]


def base_position(lines, start):
    for l in reversed(lines[:start]):
        if l[0] == "P":
            return float(l[2]), float(l[3])
    return 0.0, 0.0


def stats(path, start):
    lines = parse(path)
    seg = lines[start:]
    bx, by = base_position(lines, start)
    moves = positions(seg)
    events = [l for l in seg if l[0] == "E"]
    lx, ly = (moves[-1][1], moves[-1][2]) if moves else (bx, by)
    flips, last_sign, prev = 0, 0, by
    for _, _, y in moves:
        step = y - prev
        prev = y
        sign = (step > 0) - (step < 0)
        if sign and last_sign and sign != last_sign:
            flips += 1
        if sign:
            last_sign = sign
    mods = sorted({l[7] for l in events if l[7] != "-"})
    facts = {
        "dx": round(lx - bx),
        "dy": round(ly - by),
        "moves": len(moves),
        "raw": sum(1 for l in events if l[4] == "0"),
        "precise": sum(1 for l in events if l[4] == "1"),
        "ms": round(moves[-1][0] - moves[0][0]) if moves else 0,
        "flips": flips,
        "mods": "+".join(mods) or "-",
        "lx": sum(int(l[8]) for l in events),
        "ly": sum(int(l[9]) for l in events),
        "steps": sum(1 for l in events if float(l[10]) or float(l[11])),
    }
    print(" ".join(f"{k}={v}" for k, v in facts.items()))


COLORS = ["#8a8f98", "#2a78d6", "#d6732a", "#3a9a5b", "#9b59b6"]


def series_points(lines, start, end):
    bx, by = base_position(lines, start)
    moves = positions(lines[start:end])
    if not moves:
        return []
    t0 = moves[0][0]
    # Signed distance along the axis that moved most.
    use_x = abs(moves[-1][1] - bx) > abs(moves[-1][2] - by)
    return [(0.0, 0.0)] + [(t - t0, (x - bx) if use_x else (y - by)) for t, x, y in moves]


def chart(path, out, panels):
    lines = parse(path)
    parsed = []
    with open(out.rsplit(".", 1)[0] + ".csv", "w") as csv:
        csv.write("panel,series,ms,distance\n")
        for panel in panels:
            title, *specs = panel.split("|")
            series = []
            for spec in specs:
                name, start, end = spec.rsplit(":", 2)
                points = series_points(lines, int(start), int(end))
                for t, d in points:
                    csv.write(f'"{title}","{name}",{t:.1f},{d:.1f}\n')
                series.append((name, points))
            parsed.append((title, series))

    pw, ph, gap, top = 360, 260, 24, 70
    left, bottom = 56, 46
    width = len(parsed) * (pw + gap) + gap
    height = top + ph + bottom + 60
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
           f'font-family="-apple-system, Helvetica, sans-serif" font-size="12">',
           f'<rect width="{width}" height="{height}" fill="#fff"/>',
           f'<text x="{gap}" y="28" font-size="16" font-weight="600" fill="#222">'
           f'Smooth Scrolling - what the app saw</text>',
           f'<text x="{gap}" y="48" fill="#666">Canvas position after each wheel event, '
           f'from the ScrollView test app. Each step is one display frame.</text>']
    for i, (title, series) in enumerate(parsed):
        ox = gap + i * (pw + gap)
        all_points = [p for _, pts in series for p in pts]
        if not all_points:
            continue
        max_t = max(t for t, _ in all_points) or 1
        lo = min(0.0, min(d for _, d in all_points))
        hi = max(0.0, max(d for _, d in all_points))
        span = (hi - lo) or 1
        x0, x1 = ox + left, ox + pw - 8
        y0, y1 = top + 24, top + ph - bottom + 24

        def sx(t):
            return x0 + t / max_t * (x1 - x0)

        def sy(d):
            return y1 - (d - lo) / span * (y1 - y0)

        svg.append(f'<text x="{ox + 4}" y="{top + 8}" font-weight="600" fill="#222">{title}</text>')
        svg.append(f'<line x1="{x0}" y1="{y0}" x2="{x0}" y2="{y1}" stroke="#bbb"/>')
        svg.append(f'<line x1="{x0}" y1="{sy(0):.1f}" x2="{x1}" y2="{sy(0):.1f}" stroke="#bbb"/>')
        for d in (lo, hi):
            if d:
                svg.append(f'<text x="{x0 - 6}" y="{sy(d) + 4:.1f}" text-anchor="end" fill="#666">'
                           f'{d:.0f} pt</text>')
        svg.append(f'<text x="{x0 - 6}" y="{sy(0) + 4:.1f}" text-anchor="end" fill="#666">0</text>')
        svg.append(f'<text x="{x1}" y="{y1 + 18}" text-anchor="end" fill="#666">{max_t:.0f} ms</text>')
        svg.append(f'<text x="{x0}" y="{y1 + 18}" fill="#666">0 ms</text>')
        for j, (name, points) in enumerate(series):
            color = COLORS[(j + (0 if len(series) > 1 else 1)) % len(COLORS)]
            # A step line: the canvas holds each position until the next
            # event; the last position holds to the end of the panel.
            path_points = []
            for k, (t, d) in enumerate(points):
                if k:
                    path_points.append(f"{sx(t):.1f},{sy(points[k - 1][1]):.1f}")
                path_points.append(f"{sx(t):.1f},{sy(d):.1f}")
            path_points.append(f"{sx(max_t):.1f},{sy(points[-1][1]):.1f}")
            svg.append(f'<polyline fill="none" stroke="{color}" stroke-width="2" '
                       f'stroke-linejoin="round" points="{" ".join(path_points)}"/>')
            svg.append(f'<text x="{ox + 4}" y="{y1 + 40 + 16 * j}" fill="{color}">{name} - '
                       f'{len(points) - 1} move{"s" if len(points) != 2 else ""}, '
                       f'{points[-1][1]:+.0f} pt</text>')
    svg.append("</svg>")
    with open(out, "w") as f:
        f.write("\n".join(svg))


if __name__ == "__main__":
    if sys.argv[1] == "stats":
        stats(sys.argv[2], int(sys.argv[3]))
    elif sys.argv[1] == "chart":
        chart(sys.argv[2], sys.argv[3], sys.argv[4:])
    else:
        sys.exit("usage: see the docstring")
