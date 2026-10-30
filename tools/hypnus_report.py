#!/usr/bin/env python3
"""Read-only reader for Hypnus Series 8 (e.g. CA820W) SD cards.

Text summary:  python3 -I tools/hypnus_report.py <card> [--days 30] [--end YYYY-MM-DD] [--nights]
HTML report:   python3 -I tools/hypnus_report.py <card> --html out.html [--open]

<card> may be the card root, its DATAFILE folder, or a folder holding a copy of the card.
Every card file is opened read-only; nothing is ever written to the card. See AGENTS.md
for the file format.
"""
import argparse
import array
import base64
import datetime as dt
import json
import os
import re
import struct
import subprocess
import sys
from collections import Counter, defaultdict

HEADER = 512   # EDF-style ASCII header, always 512 bytes on this device
RECORD = 16    # event / usetime record size
HERE = os.path.dirname(os.path.abspath(__file__))

MODES = ["CPAP", "APAP", "BPAP-S", "AutoBPAP-S", "BPAP-T", "BPAP-ST", "ASV", "AutoASV"]
MASKS = ["Nasal", "Full face", "Pillows"]
MODELS = {51: "CA820M", 52: "CA820W", 53: "CA820", 54: "BA825M", 55: "BA825W", 56: "BA825",
          57: "ST830M", 58: "ST830W", 59: "ST830", 60: "AU830Pro", 61: "SV825W", 62: "SV825M"}
# event files: 16-byte records of (u32 count, u32 duration s, timestamp)
EVENT_KINDS = {"ai": "oa", "hi": "h", "csa": "ca", "csr": "csr", "pb": "pb", "fl": "fl", "snore": "sn"}


def ts(b):
    """8-byte device timestamp: u16 year, u8 month, u8 day, u8 weekday, u8 hour, u8 min, u8 sec."""
    y, mo, d, _wd, h, mi, s = struct.unpack("<HBBBBBB", b)
    return dt.datetime(y, mo, d, h, mi, s)


def read(path):
    with open(path, "rb") as f:
        return f.read()


def records(path):
    """Yield (a, b, timestamp) for each 16-byte record in an event-style file."""
    data = read(path)
    for off in range(HEADER, len(data) - RECORD + 1, RECORD):
        a, b = struct.unpack_from("<II", data, off)
        try:
            yield a, b, ts(data[off + 8:off + 16])
        except ValueError:
            continue  # partially written / padding record


def sleep_day(t):
    """Noon-to-noon therapy day, like CPAP reports use (a 01:00 start counts for the previous evening)."""
    return (t - dt.timedelta(hours=12)).date()


def find_root(path):
    """Accept the card root, its DATAFILE folder, or a folder up to two levels above a card."""
    path = os.path.abspath(os.path.expanduser(path))
    if os.path.basename(path) == "DATAFILE":
        return os.path.dirname(path)
    for depth in range(3):
        for dirpath, dirnames, _ in os.walk(path):
            if dirpath[len(path):].count(os.sep) > depth:
                continue
            if "DATAFILE" in dirnames:
                return dirpath
    sys.exit(f"No DATAFILE folder found in {path} - is this a Hypnus SD card?")


def decode_config(b):
    """192-byte Series 8 settings blob (config.bin, and each config.edf record). Layout from Hypnus' viewer."""
    f = struct.unpack_from("<10f", b, 40)
    p = struct.unpack_from("<14f", b, 112)
    mode = b[96]
    return {
        "mode": MODES[mode] if mode < len(MODES) else f"mode {mode}",
        "cpap": round(p[0], 1), "max": round(p[1], 1), "min": round(p[2], 1), "start": round(p[8], 1),
        "ipap": round(p[3], 1), "epap": round(p[4], 1),
        "ramp": b[97], "humidity": b[98], "tube": b[99], "relief_type": b[100], "relief": b[101],
        "mask": MASKS[b[6]] if b[6] < len(MASKS) else str(b[6]),
        "smart_start": bool(b[7]), "smart_stop": bool(b[8]),
        "model": MODELS.get(b[186], str(b[186])), "fw": f"{b[184]}.{b[185]:02d}",
        # summary the LCD "Info" screen last showed (cached when it is viewed)
        "lcd": {"period": struct.unpack_from("<h", b, 32)[0], "days_used": struct.unpack_from("<h", b, 34)[0],
                "days_4h": struct.unpack_from("<h", b, 36)[0], "p90": round(f[0], 1), "leak": round(f[2], 2),
                "ahi": round(f[3], 1), "ai": round(f[4], 1), "hi": round(f[5], 1), "csa": round(f[6], 1)},
    }


def settings_key(c):
    return {k: v for k, v in c.items() if k not in ("lcd", "model", "fw")}


def config_history(folder_path, folder):
    """List of (timestamp, decoded config) from <folder>_config.edf (192-byte blob + 8-byte timestamp)."""
    p = os.path.join(folder_path, f"{folder}_config.edf")
    if not os.path.exists(p):
        return []
    data = read(p)
    out = []
    for off in range(HEADER, len(data) - 199, 200):
        try:
            out.append((ts(data[off + 192:off + 200]), decode_config(data[off:off + 192])))
        except (ValueError, struct.error):
            continue
    return out


def u8(path):
    return read(path)[HEADER:] if os.path.exists(path) else b""


def i16(path):
    a = array.array("h")
    if os.path.exists(path):
        raw = read(path)[HEADER:]
        a.frombytes(raw[:len(raw) // 2 * 2])
    return a


def pct(sorted_vals, q):
    return sorted_vals[min(len(sorted_vals) - 1, int(len(sorted_vals) * q))] if sorted_vals else None


def median(vals):
    s = sorted(vals)
    return pct(s, 0.5)


def new_night(day):
    return {"d": day.isoformat(), "ses": [], "ev": defaultdict(list), "ph": Counter(), "lh": Counter(),
            "tv": [], "rr": [], "ti": [], "o2": [], "hr": [], "tl_p": {}, "tl_l": {}, "lk": 0}


def load(root, detail=True, progress=None):
    """Return ({sleep_day: night}, [(timestamp, config)], device) for every DATAFILE folder.

    With detail=False only sessions and events are read (fast text summary).
    progress, if given, is called as progress(done, total, folder, files_read) after each folder.
    """
    nights = {}
    configs = []
    device = {}
    base = os.path.join(root, "DATAFILE")
    folders = sorted(os.listdir(base))
    files_read = 0
    for i, folder in enumerate(folders, 1):
        d = os.path.join(base, folder)
        f = lambda kind: os.path.join(d, f"{folder}_{kind}.edf")
        if progress:
            if os.path.isdir(d):
                files_read += len(os.listdir(d))
            progress(i, len(folders), folder, files_read)
        if not os.path.isdir(d) or not os.path.exists(f("usetime")):
            continue
        if not device:
            h = read(f("usetime"))[:HEADER]
            serial = re.search(rb"[A-Z]{2}\d{9}", h[8:168])
            device = {"serial": serial.group().decode() if serial else "",
                      "firmware": h[0:8].decode("ascii", "replace").strip(),
                      "model": h[0xC0:0xE0].split(b"\0")[0].decode("ascii", "replace").split()[-1]}
        configs += config_history(d, folder)

        # usetime: u32 therapy seconds, u8 mode, u8 p1, u8 p2, u8 p3 (x0.1 cmH2O), timestamp = stop time
        sessions = []
        for secs, packed, end in records(f("usetime")):
            mode, p1, p2, _p3 = struct.unpack("<BBBB", struct.pack("<I", packed))
            start = end - dt.timedelta(seconds=secs)
            day = sleep_day(start)
            n = nights.setdefault(day, new_night(day))
            n["ses"].append([start.isoformat(), end.isoformat(), secs, MODES[mode] if mode < len(MODES) else str(mode),
                             p1 / 10, p2 / 10])
            sessions.append((start, end, secs, n))

        def night_at(t):
            for start, end, _s, n in sessions:
                if start - dt.timedelta(minutes=2) <= t <= end + dt.timedelta(minutes=2):
                    return n
            day = sleep_day(t)
            return nights.setdefault(day, new_night(day))

        for kind, key in EVENT_KINDS.items():
            if os.path.exists(f(kind)):
                for _count, dur, t in records(f(kind)):
                    night_at(t)["ev"][key].append([t.isoformat(), dur])
        if os.path.exists(f("leak")):
            for _age, dur, t in records(f("leak")):
                night_at(t)["lk"] += 1

        if not detail or not sessions:
            continue
        # Continuous signals are the sessions concatenated in order, no timestamps.
        pres = i16(f("pressure"))   # set pressure x0.1 cmH2O, 80 ms
        leak = u8(f("difleak"))     # unintentional leak L/min, 5 s
        mv = u8(f("mvtvbr"))        # u16 tidal volume mL, u16 breath rate, u16 inspiratory time ms, 10 s
        ox = u8(f("spo2bpm"))       # u8 SpO2 %, u8 pulse bpm, 1 s
        ip = il = im = io = 0
        for start, _end, secs, n in sessions:
            t0 = dt.datetime.fromisoformat(n["ses"][0][0])
            off_min = (start - t0).total_seconds() / 60

            k = round(secs / 0.08)
            seg = pres[ip:ip + k]
            ip += k
            for i in range(0, len(seg), 12):   # ~1 sample per second
                v = seg[i]
                if v >= 30:                    # ignore blower spin-up / spin-down samples
                    n["ph"][v] += 1
                    m = int(off_min + i * 0.08 / 60)
                    n["tl_p"].setdefault(m, []).append(v)

            k = secs // 5
            seg = leak[il:il + k]
            il += k
            for i, v in enumerate(seg):
                n["lh"][v] += 1
                m = int(off_min + i * 5 / 60)
                n["tl_l"].setdefault(m, []).append(v)

            k = secs // 10
            seg = mv[im * 6:(im + k) * 6]
            im += k
            for i in range(0, len(seg) - 5, 6):
                tv, rr, ti = struct.unpack_from("<HHH", seg, i)
                if rr and tv:
                    n["tv"].append(tv)
                    n["rr"].append(rr)
                    n["ti"].append(ti)

            k = secs
            seg = ox[io * 2:(io + k) * 2]
            io += k
            for i in range(0, len(seg) - 1, 2):
                if 50 <= seg[i] <= 100 and seg[i + 1]:
                    n["o2"].append(seg[i])
                    n["hr"].append(seg[i + 1])
    return nights, configs, device


def motor_hours(root):
    """Last 'Device Time / Motor Time' counters from log.txt (internal hour meters)."""
    p = os.path.join(root, "log.txt")
    if not os.path.exists(p):
        return None
    with open(p, "rb") as fh:
        fh.seek(max(0, os.path.getsize(p) - 400_000))
        tail = fh.read().decode("ascii", "replace")
    for line in reversed(tail.splitlines()):
        if "Motor Time:" in line:
            try:
                return {"at": line[:19], "device_h": float(line.split("Device Time:")[1].split("h")[0]),
                        "motor_h": float(line.split("Motor Time:")[1].split("h")[0])}
            except (IndexError, ValueError):
                return None
    return None


def compact_night(n):
    """JSON-ready night: histograms, nightly medians and a per-minute timeline."""
    hours = sum(s[2] for s in n["ses"]) / 3600
    span = max([int(k) for k in n["tl_p"]] + [int(k) for k in n["tl_l"]] + [0]) + 1
    tl_p = [round(sum(v) / len(v)) if (v := n["tl_p"].get(m)) else None for m in range(span)]
    tl_l = [round(sum(v) / len(v)) if (v := n["tl_l"].get(m)) else None for m in range(span)]
    mvs = sorted(tv * rr / 1000 for tv, rr in zip(n["tv"], n["rr"]))
    ie = sorted((60000 / rr - ti) / ti for rr, ti in zip(n["rr"], n["ti"]) if ti)
    return {
        "d": n["d"], "ses": n["ses"], "hours": round(hours, 3),
        "ev": {k: v for k, v in n["ev"].items()},
        "ph": dict(n["ph"]), "lh": dict(n["lh"]), "lk": n["lk"],
        "tv": median(n["tv"]), "rr": median(n["rr"]), "ti": median(n["ti"]),
        "mv": round(pct(mvs, 0.5), 2) if mvs else None, "ie": round(pct(ie, 0.5), 2) if ie else None,
        "o2": median(n["o2"]), "o2min": min(n["o2"]) if n["o2"] else None, "hr": median(n["hr"]),
        "tl": {"p": tl_p, "l": tl_l},
    }


def print_progress(done, total, folder, files_read):
    """One JSON line per folder on stdout, read by the Mac app's progress bar."""
    print(json.dumps({"done": done, "total": total, "folder": folder, "files": files_read}), flush=True)


def write_html(root, out_path, open_after=False, progress=None):
    nights, configs, device = load(root, progress=progress)
    configs.sort(key=lambda c: c[0])
    history = []
    for t, c in configs:
        if not history or settings_key(history[-1][1]) != settings_key(c):
            history.append((t, c))
    cfg_bin = os.path.join(root, "CONFIG", "config.bin")
    lcd = None
    if os.path.exists(cfg_bin) and len(read(cfg_bin)) >= 192:
        cb = decode_config(read(cfg_bin)[:192])
        lcd = cb["lcd"]
    def asset(name, mime):
        p = os.path.join(HERE, "assets", name)
        return f"data:{mime};base64," + base64.b64encode(read(p)).decode() if os.path.exists(p) else None

    nights_on_card = sorted(nights)
    device["first_night"] = nights_on_card[0].isoformat() if nights_on_card else None
    if lcd:
        device["mask"] = cb["mask"]
    payload = {
        "logo": asset("hypnus-logo.png", "image/png"),
        "photo": asset("device.jpg", "image/jpeg"),
        "generated": dt.datetime.now().isoformat(timespec="minutes"),
        "source": root.replace(os.path.expanduser("~"), "~", 1),   # no username in shared reports
        "device": device,
        "meters": motor_hours(root),
        "settings": [[t.isoformat(), settings_key(c)] for t, c in history],
        "lcd": lcd,
        "nights": [compact_night(nights[k]) for k in sorted(nights)],
    }
    with open(os.path.join(HERE, "report_template.html"), encoding="utf-8") as fh:
        html = fh.read()
    data = json.dumps(payload, separators=(",", ":")).replace("</", "<\\/")
    html = html.replace("/*__DATA__*/null", data)
    out_path = os.path.abspath(out_path)
    if out_path.startswith(os.path.abspath(root) + os.sep):
        sys.exit("Refusing to write inside the SD card folder - choose another output path.")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(html)
    print(f"Report written: {out_path}  ({len(payload['nights'])} nights)")
    if open_after and sys.platform == "darwin":
        subprocess.run(["open", out_path], check=False)


def text_summary(root, days, end, show_nights):
    nights, _, _ = load(root, detail=False)
    totals = {k: {"secs": sum(s[2] for s in n["ses"]), "sessions": len(n["ses"]),
                  **{e: len(n["ev"].get(e, [])) for e in ("oa", "h", "ca")}} for k, n in nights.items()}
    end = dt.date.fromisoformat(end) if end else max(totals)
    start = end - dt.timedelta(days=days - 1)
    window = {k: v for k, v in totals.items() if start <= k <= end}

    if show_nights:
        print(f"{'night of':<11} {'hours':>6} {'sess':>4} {'OA':>4} {'H':>4} {'CA':>4} {'AHI':>6}")
        for day in sorted(window):
            n = window[day]
            hrs = n["secs"] / 3600
            ev = n["oa"] + n["h"] + n["ca"]
            ahi = f"{ev / hrs:6.2f}" if hrs else "     -"
            print(f"{day!s:<11} {hrs:6.2f} {n['sessions']:>4} {n['oa']:>4} {n['h']:>4} {n['ca']:>4} {ahi}")
        print()

    hrs = sum(n["secs"] for n in window.values()) / 3600
    oa = sum(n["oa"] for n in window.values())
    h = sum(n["h"] for n in window.values())
    ca = sum(n["ca"] for n in window.values())
    used = [d for d, n in window.items() if n["secs"] > 0]
    used4 = [d for d, n in window.items() if n["secs"] >= 4 * 3600]
    print(f"Window: {start} .. {end} ({days} days, noon-to-noon)")
    print(f"Days used (any): {len(used)} / {days}")
    print(f"Days used >= 4h: {len(used4)} / {days}")
    print(f"Total therapy:   {hrs:.1f} h  (avg {hrs / len(used) if used else 0:.1f} h on days used)")
    print(f"Events:          OA {oa}, H {h}, CA {ca}")
    if hrs:
        print(f"AHI:             {(oa + h + ca) / hrs:.2f}  (OAI {oa / hrs:.2f}, HI {h / hrs:.2f}, CAI {ca / hrs:.2f})")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("root", help="SD card, its DATAFILE folder, or a folder containing a card copy")
    p.add_argument("--days", type=int, default=30)
    p.add_argument("--end", help="last therapy day to include (default: latest on card)")
    p.add_argument("--nights", action="store_true", help="print a per-night table")
    p.add_argument("--html", metavar="OUT", help="write an interactive HTML report (all nights) to OUT")
    p.add_argument("--open", action="store_true", help="open the HTML report when done (macOS)")
    p.add_argument("--progress", action="store_true", help="print JSON progress lines while reading (for the Mac app)")
    a = p.parse_args()
    root = find_root(a.root)
    if a.html:
        write_html(root, a.html, a.open, print_progress if a.progress else None)
    else:
        text_summary(root, a.days, a.end, a.nights)


if __name__ == "__main__":
    main()
