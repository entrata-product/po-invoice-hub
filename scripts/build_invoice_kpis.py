#!/usr/bin/env python3
"""
build_invoice_kpis.py

Reads a raw aggregation result from queries/invoice-monthly-kpis.redshift.sql
(as produced by the Redshift MCP) and materializes the four dashboard JSON
files consumed by index.html.

USAGE:
    # 1) Run the aggregation query via the Redshift MCP and save the result:
    #    (in Cursor)  redshift_query with sql = queries/invoice-monthly-kpis.redshift.sql
    #                 -> save the JSON output to /tmp/invoice-agg.json
    # 2) python3 scripts/build_invoice_kpis.py /tmp/invoice-agg.json

INPUT SHAPE (expected from Redshift MCP):
    {
      "rows": [
        {
          "creation_month": "2026-07",
          "client_release_track": null,
          "client_segment": "Enterprise",
          "source_channel": "Vendor Portal",
          "rejection_category": "NONE",
          "invoice_count": 12345,
          "total_amount": 12345678.90,
          "ftr_denom": 12000,
          "ftr_count": 10500,
          "touchless_denom": 12000,
          "touchless_count": 9500,
          "rejected_count": 1500,
          "total_rejection_events": 1750,
          "avg_days_to_posted": 4.2,
          "median_days_to_posted": 3.0,
          "active_clients": 42
        },
        ...
      ]
    }
    (If the MCP returns a bare list, it is also accepted.)

OUTPUT (written to data/invoice-*.json):
    - invoice-kpis.json         Headline totals + 30d/90d/12mo windows + rates
    - invoice-monthly.json      Trailing 25 months of count / volume / active clients
    - invoice-source-mix.json   Trailing 12 months source_channel distribution
    - invoice-adoption.json     client_segment mix + release-track mix

NOTES:
    - Rates are only emitted when the denominator > 0. Otherwise the field is null.
    - Windowed KPIs use the max creation_month in the input as "current month"
      and roll backwards from there. The latest month is flagged as partial.
    - All caveats from the SQL header travel through as `_notes` in the output.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = REPO_ROOT / "data"

SHARED_NOTES = [
    "Source: queries/invoice-monthly-kpis.redshift.sql (Redshift-adapted from Pallavi Nawale's Dataset 1 attached to Jira DEV-253879, 2026-07-20).",
    "Live-client scope only (clients.company_status_type_id = 4). Test / demo / template clients excluded.",
    "Rapid vs Standard release-track split is NULL: the details JSONB column isn't mirrored to Redshift. Restore once DBRE surfaces cluster_id.",
    "is_first_time_right does NOT deduct for reroutes (per Pallavi's caveat — reroute events can't be counted for multi-property invoices).",
    "ELI detection excludes the batch-array fallback branch (Redshift array UNNEST limitation). May under-count ELI adoption for invoices linked only via invoice_plus_batches; refresh once mirror supports SUPER unnest.",
    "'Dashboard Shortcut' and 'Duplicate / Use Previous' source channels are inherently untrackable (no field or log).",
    "rejection_category counts appear only when rejection_count > 0. Non-rejected invoices carry category = 'NONE'.",
]


def load_agg(path: Path) -> list[dict[str, Any]]:
    with path.open() as f:
        raw = json.load(f)
    if isinstance(raw, dict):
        rows = raw.get("rows") or raw.get("data") or raw.get("results")
        if rows is None:
            raise SystemExit(
                "Input JSON has no 'rows' / 'data' / 'results' key. "
                "Expected either a list or an object containing one."
            )
    elif isinstance(raw, list):
        rows = raw
    else:
        raise SystemExit(f"Unexpected input type: {type(raw)}")
    # Coerce numeric fields (MCP sometimes returns them as strings)
    numeric_fields = {
        "invoice_count", "total_amount", "ftr_denom", "ftr_count",
        "touchless_denom", "touchless_count", "rejected_count",
        "total_rejection_events", "avg_days_to_posted",
        "median_days_to_posted", "active_clients",
    }
    for r in rows:
        for k in numeric_fields:
            if k in r and r[k] is not None:
                try:
                    r[k] = float(r[k]) if k in {
                        "total_amount", "avg_days_to_posted",
                        "median_days_to_posted"
                    } else int(float(r[k]))
                except (TypeError, ValueError):
                    r[k] = None
    return rows


def rate(numer: float | int | None, denom: float | int | None) -> float | None:
    if not denom:
        return None
    if numer is None:
        return None
    return round(100.0 * numer / denom, 1)


def build_monthly(rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Sum invoice_count + total_amount + active_clients by creation_month.

    active_clients is a distinct count per (month × segment × channel × category);
    we approximate a monthly active-clients figure with MAX across slices, which
    is a safe lower bound. If we want an exact figure later, we can add a
    dedicated aggregate query.
    """
    agg: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"invoice_count": 0, "total_amount": 0.0, "active_clients_max": 0}
    )
    for r in rows:
        m = r.get("creation_month")
        if not m:
            continue
        a = agg[m]
        a["invoice_count"] += r.get("invoice_count") or 0
        a["total_amount"] += r.get("total_amount") or 0.0
        # Track the max active_clients seen for the month across slices as a
        # lower-bound estimate (safe because distinct clients only grow when
        # you union across slices).
        ac = r.get("active_clients") or 0
        if ac > a["active_clients_max"]:
            a["active_clients_max"] = ac
    months = []
    for m in sorted(agg.keys()):
        months.append({
            "ym": m,
            "invoice_count": agg[m]["invoice_count"],
            "total_amount_usd": round(agg[m]["total_amount"], 2),
            "clients_active_min": agg[m]["active_clients_max"],
        })
    # Flag the latest month as partial (current month is MTD).
    if months:
        latest_ym = months[-1]["ym"]
        today_ym = dt.datetime.utcnow().strftime("%Y-%m")
        if latest_ym == today_ym:
            months[-1]["partial_month"] = True
    return {
        "_schema": "Monthly invoice volume, dollar total, and lower-bound active-client count. Trailing 24 months.",
        "_status": "live",
        "_notes": SHARED_NOTES + [
            "clients_active_min is a lower-bound (max across (segment × channel × category) slices for the month). Distinct-client counts exact figures can be added via a separate aggregate query.",
        ],
        "as_of": dt.datetime.utcnow().date().isoformat(),
        "months": months,
    }


def build_kpis(rows: list[dict[str, Any]], monthly: dict[str, Any]) -> dict[str, Any]:
    """Portfolio KPIs — totals across full input + 30d/90d/12mo windows."""
    months = monthly["months"]
    if not months:
        return {
            "_schema": "Invoice headline KPIs (portfolio-wide).",
            "_status": "live",
            "_notes": SHARED_NOTES + ["No data returned from the aggregate query."],
            "as_of": dt.datetime.utcnow().date().isoformat(),
        }

    ym_list = [m["ym"] for m in months]
    # windows are ANCHORED on the input's latest month (safest against partial-month drift).
    latest_ym = ym_list[-1]

    def _window(n_months: int) -> list[dict[str, Any]]:
        return months[-n_months:] if n_months > 0 else months

    def _sum(entries: list[dict[str, Any]], key: str) -> float | int:
        s = 0
        for e in entries:
            s += e.get(key) or 0
        return s

    # 30d ≈ current (partial) month; 90d ≈ trailing 3 months; 12mo = trailing 12.
    w30 = _window(1)
    w90 = _window(3)
    w12 = _window(12)

    # Portfolio totals from the FULL aggregation (rate denominators too).
    ftr_denom = sum((r.get("ftr_denom") or 0) for r in rows)
    ftr_count = sum((r.get("ftr_count") or 0) for r in rows)
    touchless_denom = sum((r.get("touchless_denom") or 0) for r in rows)
    touchless_count = sum((r.get("touchless_count") or 0) for r in rows)
    rejected_count = sum((r.get("rejected_count") or 0) for r in rows)
    total_rejection_events = sum((r.get("total_rejection_events") or 0) for r in rows)
    total_invoices = sum((r.get("invoice_count") or 0) for r in rows)
    # Weighted avg days-to-posted across rows (weight by invoice_count).
    weighted_days_num = 0.0
    weighted_days_denom = 0
    for r in rows:
        avg = r.get("avg_days_to_posted")
        cnt = r.get("invoice_count") or 0
        if avg is not None and cnt:
            weighted_days_num += avg * cnt
            weighted_days_denom += cnt
    avg_days_to_posted = (
        round(weighted_days_num / weighted_days_denom, 2)
        if weighted_days_denom else None
    )

    # Active-clients: max across all slices in the trailing 30-day window
    # (still a lower bound; will refine with a distinct-count query).
    active_clients_30d = max(
        (r.get("active_clients") or 0)
        for r in rows if r.get("creation_month") == latest_ym
    ) if rows else 0

    return {
        "_schema": "Invoice headline KPIs (portfolio-wide) — trailing 30d / 90d / 12mo windows anchored on the latest month in the input.",
        "_status": "live",
        "_source": "Redshift entrata_entrata (mirrored ~24h behind prod)",
        "_notes": SHARED_NOTES + [
            "windows are month-aligned: 30d = latest month (partial if current), 90d = trailing 3 months, 12mo = trailing 12.",
            "active_clients figures are lower-bound estimates (max across slices).",
        ],
        "as_of": dt.datetime.utcnow().date().isoformat(),
        "anchor_month": latest_ym,
        "totals": {
            "total_invoices": total_invoices,
            "total_amount_usd": round(sum(m["total_amount_usd"] for m in months), 2),
            "ftr_denom": ftr_denom,
            "ftr_count": ftr_count,
            "ftr_rate_pct": rate(ftr_count, ftr_denom),
            "touchless_denom": touchless_denom,
            "touchless_count": touchless_count,
            "touchless_rate_pct": rate(touchless_count, touchless_denom),
            "rejected_count": rejected_count,
            "total_rejection_events": total_rejection_events,
            "rejection_rate_pct": rate(rejected_count, total_invoices),
            "avg_days_to_posted": avg_days_to_posted,
        },
        "window_30d": {
            "invoices_created": _sum(w30, "invoice_count"),
            "total_amount_usd": round(_sum(w30, "total_amount_usd"), 2),
            "active_clients_min": active_clients_30d,
        },
        "window_90d": {
            "invoices_created": _sum(w90, "invoice_count"),
            "total_amount_usd": round(_sum(w90, "total_amount_usd"), 2),
        },
        "window_12mo": {
            "invoices_created": _sum(w12, "invoice_count"),
            "total_amount_usd": round(_sum(w12, "total_amount_usd"), 2),
        },
    }


def build_source_mix(rows: list[dict[str, Any]], monthly: dict[str, Any]) -> dict[str, Any]:
    """Trailing 12-month source_channel distribution."""
    months = monthly["months"]
    if not months:
        return {"_status": "live", "sources": []}
    trailing_12_ym = {m["ym"] for m in months[-12:]}

    by_source: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"invoice_count": 0, "total_amount": 0.0}
    )
    total = 0
    for r in rows:
        if r.get("creation_month") not in trailing_12_ym:
            continue
        s = r.get("source_channel") or "Unknown"
        by_source[s]["invoice_count"] += r.get("invoice_count") or 0
        by_source[s]["total_amount"] += r.get("total_amount") or 0.0
        total += r.get("invoice_count") or 0

    entries = []
    for s, agg in sorted(by_source.items(), key=lambda kv: -kv[1]["invoice_count"]):
        entries.append({
            "source": s,
            "invoice_count": agg["invoice_count"],
            "total_amount_usd": round(agg["total_amount"], 2),
            "pct": round(100.0 * agg["invoice_count"] / total, 1) if total else 0.0,
        })
    return {
        "_schema": "Invoice source_channel distribution, last 12 months.",
        "_status": "live",
        "_notes": SHARED_NOTES + [
            "Sources 'Dashboard Shortcut' and 'Duplicate / Use Previous' will never appear (no source field or log).",
            "'ELI Invoice Entry' is under-counted because the batch-array fallback branch is dropped in the Redshift adaptation.",
        ],
        "as_of": dt.datetime.utcnow().date().isoformat(),
        "window": "last_12_months",
        "total_invoices_in_window": total,
        "sources": entries,
    }


def build_adoption(rows: list[dict[str, Any]], monthly: dict[str, Any]) -> dict[str, Any]:
    """client_segment mix + release-track mix (trailing 12 months)."""
    months = monthly["months"]
    if not months:
        return {"_status": "live", "by_segment": []}
    trailing_12_ym = {m["ym"] for m in months[-12:]}

    by_segment: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"invoice_count": 0, "active_clients_max": 0}
    )
    by_track: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"invoice_count": 0, "active_clients_max": 0}
    )
    total = 0
    for r in rows:
        if r.get("creation_month") not in trailing_12_ym:
            continue
        seg = r.get("client_segment") or "Unknown"
        by_segment[seg]["invoice_count"] += r.get("invoice_count") or 0
        ac = r.get("active_clients") or 0
        if ac > by_segment[seg]["active_clients_max"]:
            by_segment[seg]["active_clients_max"] = ac

        track = r.get("client_release_track") or "Unknown"
        by_track[track]["invoice_count"] += r.get("invoice_count") or 0
        if ac > by_track[track]["active_clients_max"]:
            by_track[track]["active_clients_max"] = ac
        total += r.get("invoice_count") or 0

    segment_entries = []
    for seg in ["Enterprise", "Mid-Market", "Small", "Unknown"]:
        if seg not in by_segment:
            continue
        segment_entries.append({
            "segment": seg,
            "invoice_count": by_segment[seg]["invoice_count"],
            "active_clients_min": by_segment[seg]["active_clients_max"],
            "pct": round(100.0 * by_segment[seg]["invoice_count"] / total, 1) if total else 0.0,
        })

    track_entries = []
    for track in ["Rapid", "Standard", "Unknown"]:
        if track not in by_track:
            continue
        track_entries.append({
            "release_track": track,
            "invoice_count": by_track[track]["invoice_count"],
            "active_clients_min": by_track[track]["active_clients_max"],
            "pct": round(100.0 * by_track[track]["invoice_count"] / total, 1) if total else 0.0,
        })

    return {
        "_schema": "Invoice adoption slices (client_segment + client_release_track), last 12 months.",
        "_status": "live",
        "_notes": SHARED_NOTES + [
            "'Unknown' release_track is the norm today (cluster_id JSONB not mirrored). Rapid vs Standard split will populate once DBRE surfaces cluster_id.",
        ],
        "as_of": dt.datetime.utcnow().date().isoformat(),
        "window": "last_12_months",
        "total_invoices_in_window": total,
        "by_segment": segment_entries,
        "by_release_track": track_entries,
    }


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")
    try:
        rel = path.relative_to(REPO_ROOT)
    except ValueError:
        rel = path
    print(f"  wrote  {rel}  ({len(json.dumps(payload)):,} bytes)")


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("input", type=Path,
                   help="Path to the Redshift MCP output JSON (from queries/invoice-monthly-kpis.redshift.sql)")
    p.add_argument("--data-dir", type=Path, default=DATA_DIR,
                   help="Override output data directory (default: repo data/)")
    args = p.parse_args(argv)

    if not args.input.exists():
        print(f"ERROR: input file not found: {args.input}", file=sys.stderr)
        return 1

    print(f"reading  {args.input}")
    rows = load_agg(args.input)
    print(f"loaded  {len(rows):,} rows")

    print("building  invoice-monthly.json")
    monthly = build_monthly(rows)
    print("building  invoice-kpis.json")
    kpis = build_kpis(rows, monthly)
    print("building  invoice-source-mix.json")
    source_mix = build_source_mix(rows, monthly)
    print("building  invoice-adoption.json")
    adoption = build_adoption(rows, monthly)

    write_json(args.data_dir / "invoice-monthly.json", monthly)
    write_json(args.data_dir / "invoice-kpis.json", kpis)
    write_json(args.data_dir / "invoice-source-mix.json", source_mix)
    write_json(args.data_dir / "invoice-adoption.json", adoption)

    print("done.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
