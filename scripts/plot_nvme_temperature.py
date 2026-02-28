#!/usr/bin/env python3
import argparse
import csv
from datetime import datetime
from pathlib import Path
import sys


def parse_num(value):
    if value is None:
        return None
    value = value.strip()
    if value == "" or value == "-":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def parse_time(row):
    epoch = row.get("epoch", "").strip()
    if epoch.isdigit():
        return datetime.fromtimestamp(int(epoch))
    ts = row.get("timestamp", "").strip()
    if ts:
        try:
            return datetime.strptime(ts, "%Y-%m-%d %H:%M:%S")
        except ValueError:
            return None
    return None


def read_csv(csv_path):
    xs = []
    data = {
        "composite_c": [],
        "sensor1_c": [],
        "sensor2_c": [],
        "warning_time": [],
        "critical_time": [],
        "t1_count": [],
        "t2_count": [],
        "d_warning_time": [],
        "d_critical_time": [],
        "d_t1_count": [],
        "d_t2_count": [],
    }
    disk = ""
    model = ""

    with csv_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            t = parse_time(row)
            if t is None:
                continue
            xs.append(t)
            for key in data:
                data[key].append(parse_num(row.get(key, "")))

            if not disk:
                disk = row.get("disk", "").strip()
            if not model:
                model = row.get("model", "").strip()

    return xs, data, disk, model


def maybe_plot(ax, xs, ys, label, color=None):
    if any(v is not None for v in ys):
        ax.plot(xs, ys, label=label, linewidth=1.6, color=color)


def main():
    parser = argparse.ArgumentParser(description="Plot NVMe monitor CSV")
    parser.add_argument("--input", required=True, help="Input CSV path")
    parser.add_argument("--output", default="", help="Output PNG path")
    parser.add_argument("--show", action="store_true", help="Show figure window")
    args = parser.parse_args()

    try:
        import matplotlib.pyplot as plt
    except Exception:
        print("matplotlib not installed. Install with: pip install matplotlib", file=sys.stderr)
        return 1

    csv_path = Path(args.input).expanduser().resolve()
    if not csv_path.exists():
        print(f"input CSV not found: {csv_path}", file=sys.stderr)
        return 1

    out_path = Path(args.output).expanduser().resolve() if args.output else csv_path.with_suffix(".png")
    out_path.parent.mkdir(parents=True, exist_ok=True)

    xs, data, disk, model = read_csv(csv_path)
    if not xs:
        print("no valid rows found in CSV", file=sys.stderr)
        return 1

    fig, axes = plt.subplots(3, 1, figsize=(12, 10), sharex=True)
    title = f"NVMe Temperature Monitor - {disk or 'unknown'}"
    if model:
        title += f" ({model})"
    fig.suptitle(title, fontsize=12)

    ax = axes[0]
    maybe_plot(ax, xs, data["composite_c"], "Composite (C)", "#1f77b4")
    maybe_plot(ax, xs, data["sensor1_c"], "Sensor1 (C)", "#d62728")
    maybe_plot(ax, xs, data["sensor2_c"], "Sensor2 (C)", "#ff7f0e")
    ax.set_ylabel("Temp (C)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left")

    ax = axes[1]
    maybe_plot(ax, xs, data["warning_time"], "Warning Time", "#9467bd")
    maybe_plot(ax, xs, data["critical_time"], "Critical Time", "#8c564b")
    maybe_plot(ax, xs, data["t1_count"], "T1 Count", "#2ca02c")
    maybe_plot(ax, xs, data["t2_count"], "T2 Count", "#17becf")
    ax.set_ylabel("Counters")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left")

    ax = axes[2]
    maybe_plot(ax, xs, data["d_warning_time"], "Delta Warning Time", "#9467bd")
    maybe_plot(ax, xs, data["d_critical_time"], "Delta Critical Time", "#8c564b")
    maybe_plot(ax, xs, data["d_t1_count"], "Delta T1 Count", "#2ca02c")
    maybe_plot(ax, xs, data["d_t2_count"], "Delta T2 Count", "#17becf")
    ax.set_ylabel("Delta")
    ax.set_xlabel("Time")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left")

    fig.tight_layout(rect=(0, 0, 1, 0.97))
    fig.savefig(out_path, dpi=160)
    print(f"saved: {out_path}")

    if args.show:
        plt.show()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

