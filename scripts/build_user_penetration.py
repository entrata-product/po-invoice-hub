#!/usr/bin/env python3
"""
build_user_penetration.py

Reads a raw aggregation result from queries/user-penetration.redshift.sql
(via the Redshift MCP) and materializes data/user-penetration.json for the
dashboard's Adoption tab (PO + Invoice licensed-user penetration).

USAGE:
    # 1) Run the query via the Redshift MCP. Save the JSON payload:
    #      data/local/penetration/raw.json
    # 2) Build the dashboard file:
    #      python3 scripts/build_user_penetration.py data/local/penetration/raw.json

INPUT SHAPE (from Redshift MCP; bare list also accepted):
    {
      "rows": [
        {
          "client_id": 125,
          "doc_type": "PO" | "INVOICE",
          "period_month": "2026-07",
          "total_licensed_users": "163",
          "active_users": "12",
          "penetration_pct": "7.36"
        },
        ...
      ]
    }

OUTPUT (written to data/user-penetration.json):
    {
      "as_of": "YYYY-MM-DD",
      "trailing_period_months": 12,
      "notes": [ ... caveats ... ],
      "po": {
        "portfolio": {
          "clients_with_activity": <int>,
          "total_licensed_users": <int>,      # sum across active clients (latest month per client)
          "active_users_latest_month": <int>, # last month bucket
          "penetration_pct_latest": <float>,  # weighted (sum active / sum licensed)
          "penetration_pct_avg_12mo": <float> # simple avg of monthly weighted rates
        },
        "monthly": [
          {"period_month": "YYYY-MM", "clients": <int>, "total_licensed_users": <int>,
           "active_users": <int>, "penetration_pct": <float>}, ...
        ],
        "top_clients": [
          {"client_id": <int>, "latest_licensed_users": <int>,
           "latest_active_users": <int>, "penetration_pct_avg_12mo": <float>,
           "months_with_activity": <int>}, ...
        ],
        "bottom_clients": [ ... same shape, low penetration ... ]
      },
      "invoice": { same shape as "po" }
    }

NOTES:
    - `total_licensed_users` in the input is portfolio-current, not
      point-in-time per month; we surface that caveat in `notes`.
    - System users (21, 48, 67, 77) are already excluded upstream in the SQL.
    - Live-client scope is enforced upstream (company_status_type_id = 4).
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path
from collections import defaultdict


SHARED_NOTES = [
    "Live-client scope only (clients.company_status_type_id = 4).",
    "Non-template PO/Invoice activity: created OR edited via ap_header_logs.",
    "System users 21/48/67/77 excluded from the active-users numerator.",
    "Licensed-user denominator is portfolio-current, not point-in-time per month; "
    "penetration for older months is measured against today's user roster.",
    "Trailing 12 calendar months from the run date.",
]


def load_rows(path: Path) -> list[dict]:
    with path.open() as f:
        payload = json.load(f)
    rows = payload["rows"] if isinstance(payload, dict) else payload
    coerced = []
    for r in rows:
        coerced.append({
            "client_id": int(r["client_id"]),
            "doc_type": str(r["doc_type"]),
            "period_month": str(r["period_month"]),
            "total_licensed_users": int(r.get("total_licensed_users") or 0),
            "active_users": int(r.get("active_users") or 0),
            "penetration_pct": (
                float(r["penetration_pct"])
                if r.get("penetration_pct") is not None else None
            ),
        })
    return coerced


def _split_by_doc(rows: list[dict]) -> tuple[list[dict], list[dict]]:
    po = [r for r in rows if r["doc_type"] == "PO"]
    inv = [r for r in rows if r["doc_type"] == "INVOICE"]
    return po, inv


def _build_side(rows: list[dict], top_n: int = 15) -> dict:
    if not rows:
        return {
            "portfolio": {
                "clients_with_activity": 0,
                "total_licensed_users": 0,
                "active_users_latest_month": 0,
                "penetration_pct_latest": None,
                "penetration_pct_avg_12mo": None,
            },
            "monthly": [],
            "top_clients": [],
            "bottom_clients": [],
        }

    # Monthly roll-up (weighted across clients in that month).
    by_month = defaultdict(lambda: {"clients": set(), "licensed_sum": 0, "active_sum": 0})
    for r in rows:
        b = by_month[r["period_month"]]
        b["clients"].add(r["client_id"])
        b["licensed_sum"] += r["total_licensed_users"]
        b["active_sum"] += r["active_users"]

    monthly = []
    for m in sorted(by_month):
        b = by_month[m]
        pct = (
            round(100.0 * b["active_sum"] / b["licensed_sum"], 2)
            if b["licensed_sum"] > 0 else None
        )
        monthly.append({
            "period_month": m,
            "clients": len(b["clients"]),
            "total_licensed_users": b["licensed_sum"],
            "active_users": b["active_sum"],
            "penetration_pct": pct,
        })

    latest = monthly[-1] if monthly else None
    pct_avg = (
        round(statistics.fmean(
            [m["penetration_pct"] for m in monthly if m["penetration_pct"] is not None]
        ), 2)
        if any(m["penetration_pct"] is not None for m in monthly) else None
    )

    # Per-client aggregation.
    by_client = defaultdict(lambda: {
        "licensed": 0, "active_latest": 0, "months": set(),
        "pct_values": [],
    })
    latest_month = latest["period_month"] if latest else None
    for r in rows:
        c = by_client[r["client_id"]]
        c["licensed"] = max(c["licensed"], r["total_licensed_users"])
        if r["period_month"] == latest_month:
            c["active_latest"] = r["active_users"]
        c["months"].add(r["period_month"])
        if r["penetration_pct"] is not None:
            c["pct_values"].append(r["penetration_pct"])

    client_records = []
    for cid, c in by_client.items():
        client_records.append({
            "client_id": cid,
            "latest_licensed_users": c["licensed"],
            "latest_active_users": c["active_latest"],
            "penetration_pct_avg_12mo": (
                round(statistics.fmean(c["pct_values"]), 2)
                if c["pct_values"] else None
            ),
            "months_with_activity": len(c["months"]),
        })

    def _sort_key(row):
        return (
            row["penetration_pct_avg_12mo"] is None,
            -(row["penetration_pct_avg_12mo"] or 0),
            -row["latest_licensed_users"],
        )

    ranked = sorted(client_records, key=_sort_key)
    top_clients = ranked[:top_n]

    # Bottom: only include clients with at least 3 months of activity so we're
    # not naming a client with a single-month blip.
    stable = [c for c in client_records if c["months_with_activity"] >= 3]
    bottom_clients = sorted(
        stable,
        key=lambda x: (
            x["penetration_pct_avg_12mo"] is None,
            (x["penetration_pct_avg_12mo"] or 0),
            -x["latest_licensed_users"],
        ),
    )[:top_n]

    return {
        "portfolio": {
            "clients_with_activity": len(by_client),
            "total_licensed_users": latest["total_licensed_users"] if latest else 0,
            "active_users_latest_month": latest["active_users"] if latest else 0,
            "penetration_pct_latest": latest["penetration_pct"] if latest else None,
            "penetration_pct_avg_12mo": pct_avg,
        },
        "monthly": monthly,
        "top_clients": top_clients,
        "bottom_clients": bottom_clients,
    }


def build(rows: list[dict]) -> dict:
    po, inv = _split_by_doc(rows)
    return {
        "as_of": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "trailing_period_months": 12,
        "notes": SHARED_NOTES,
        "po": _build_side(po),
        "invoice": _build_side(inv),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path, help="Raw MCP JSON from user-penetration query")
    ap.add_argument(
        "--output",
        type=Path,
        default=Path("data/user-penetration.json"),
        help="Path to write the dashboard JSON (default: data/user-penetration.json)",
    )
    args = ap.parse_args()

    if not args.input.exists():
        print(f"ERROR: input not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    rows = load_rows(args.input)
    result = build(rows)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as f:
        json.dump(result, f, indent=2)
    print(
        f"Wrote {args.output} — "
        f"PO clients: {result['po']['portfolio']['clients_with_activity']}, "
        f"Invoice clients: {result['invoice']['portfolio']['clients_with_activity']}",
    )


if __name__ == "__main__":
    main()
