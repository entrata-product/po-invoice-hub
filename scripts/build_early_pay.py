#!/usr/bin/env python3
"""
build_early_pay.py

Reads two raw aggregations from queries/invoice-early-pay.redshift.sql
(config coverage + capture rates) and materializes data/early-pay.json
for the dashboard's Health / Overview tab.

USAGE:
    python3 scripts/build_early_pay.py \\
        --coverage data/local/early-pay/config-coverage.json \\
        --capture  data/local/early-pay/capture.json

INPUT SHAPE — coverage (Query A output):
    { "rows": [{ "client_id": 1788,
                 "discount_terms_active": 1,
                 "distinct_vendors_covered": 1 }, ...] }

INPUT SHAPE — capture (Query B output):
    { "rows": [{ "client_id": 1788,
                 "period_month": "2025-08",
                 "eligible_invoice_count": 1,
                 "discount_available_sum": 25.00,
                 "discount_captured_sum": 0.00,
                 "captured_invoice_count": 0,
                 "capture_rate_pct": 0.00 }, ...] }

OUTPUT (data/early-pay.json):
    {
      "as_of": "YYYY-MM-DD",
      "trailing_period_months": 12,
      "notes": [ ... critical mirror caveats ... ],
      "config_gap": {
        "clients_with_terms_configured": <int>,
        "clients_with_terms_and_vendors_tagged": <int>,
        "clients_with_terms_but_no_vendors": <int>,   # the adoption gap
        "total_terms_defined": <int>,
        "total_vendors_tagged": <int>
      },
      "capture_portfolio": {
        "clients_with_activity": <int>,
        "eligible_invoices_12mo": <int>,
        "discount_available_sum_12mo": <float>,
        "discount_captured_sum_12mo": <float>,
        "discount_missed_sum_12mo": <float>,          # = available - captured
        "capture_rate_pct_12mo": <float>              # weighted (captured/available)
      },
      "monthly": [
        {"period_month": "YYYY-MM", "eligible_invoices": <int>,
         "available": <float>, "captured": <float>, "missed": <float>,
         "capture_rate_pct": <float>}, ...
      ],
      "clients": [
        {"client_id": <int>, "terms_configured": <int>, "vendors_tagged": <int>,
         "eligible_invoices_12mo": <int>, "available_12mo": <float>,
         "captured_12mo": <float>, "missed_12mo": <float>,
         "capture_rate_pct_12mo": <float>}, ...
      ]
    }
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path


SHARED_NOTES = [
    "CRITICAL: ap_payee_terms has been removed from the live Redshift mirror. "
    "This report uses the archived snapshot ap_payee_terms_removed_03_21_25 "
    "(as of 2025-03-21). Any discount-term config created or changed after "
    "that date is invisible here.",
    "Headline story: this is a CONFIGURATION ADOPTION GAP first, capture rate "
    "second. Fewer than a couple dozen live clients had any discount terms "
    "defined in the snapshot.",
    "Capture-rate window: post_date within the trailing 12 months.",
    "Capture-rate month is bucketed by capture-date if captured, else by "
    "the discount deadline. Denominator excludes invoices whose deadline is "
    "still in the future.",
    "Live-client scope only (clients.company_status_type_id = 4).",
]


def _load(path: Path) -> list[dict]:
    with path.open() as f:
        payload = json.load(f)
    return payload["rows"] if isinstance(payload, dict) else payload


def _num(v, default=0):
    if v is None:
        return default
    try:
        return float(v) if "." in str(v) else int(v)
    except (ValueError, TypeError):
        return default


def build(coverage_rows: list[dict], capture_rows: list[dict]) -> dict:
    # ---- Config gap ----
    total_terms = 0
    total_vendors = 0
    with_terms = 0
    with_vendors_tagged = 0
    coverage_by_client: dict[int, dict] = {}
    for r in coverage_rows:
        cid = int(r["client_id"])
        terms = _num(r.get("discount_terms_active"))
        vendors = _num(r.get("distinct_vendors_covered"))
        total_terms += terms
        total_vendors += vendors
        with_terms += 1
        if vendors > 0:
            with_vendors_tagged += 1
        coverage_by_client[cid] = {"terms": terms, "vendors": vendors}

    config_gap = {
        "clients_with_terms_configured": with_terms,
        "clients_with_terms_and_vendors_tagged": with_vendors_tagged,
        "clients_with_terms_but_no_vendors": with_terms - with_vendors_tagged,
        "total_terms_defined": total_terms,
        "total_vendors_tagged": total_vendors,
    }

    # ---- Capture roll-ups ----
    # Only trailing-12 rows: derive from run-date to filter defensively.
    now = datetime.now(timezone.utc)
    cutoff_year = now.year - 1
    cutoff_month = now.month
    def _in_window(pm: str) -> bool:
        try:
            y, m = pm.split("-")
            y_i, m_i = int(y), int(m)
        except ValueError:
            return False
        # Include months >= cutoff (roughly 12mo trailing).
        return (y_i, m_i) >= (cutoff_year, cutoff_month)

    monthly_agg = defaultdict(lambda: {"eligible": 0, "available": 0.0, "captured": 0.0})
    by_client = defaultdict(lambda: {
        "eligible": 0, "available": 0.0, "captured": 0.0, "months": set()
    })
    for r in capture_rows:
        pm = str(r["period_month"])
        if not _in_window(pm):
            continue
        cid = int(r["client_id"])
        eligible = _num(r.get("eligible_invoice_count"))
        avail = _num(r.get("discount_available_sum"))
        cap = _num(r.get("discount_captured_sum"))
        monthly_agg[pm]["eligible"] += eligible
        monthly_agg[pm]["available"] += float(avail)
        monthly_agg[pm]["captured"] += float(cap)
        by_client[cid]["eligible"] += eligible
        by_client[cid]["available"] += float(avail)
        by_client[cid]["captured"] += float(cap)
        by_client[cid]["months"].add(pm)

    monthly = []
    tot_eligible = tot_avail = tot_cap = 0
    for pm in sorted(monthly_agg):
        b = monthly_agg[pm]
        tot_eligible += b["eligible"]
        tot_avail += b["available"]
        tot_cap += b["captured"]
        rate = (
            round(100.0 * b["captured"] / b["available"], 2)
            if b["available"] > 0 else None
        )
        monthly.append({
            "period_month": pm,
            "eligible_invoices": b["eligible"],
            "available": round(b["available"], 2),
            "captured": round(b["captured"], 2),
            "missed": round(b["available"] - b["captured"], 2),
            "capture_rate_pct": rate,
        })

    portfolio = {
        "clients_with_activity": len(by_client),
        "eligible_invoices_12mo": tot_eligible,
        "discount_available_sum_12mo": round(tot_avail, 2),
        "discount_captured_sum_12mo": round(tot_cap, 2),
        "discount_missed_sum_12mo": round(tot_avail - tot_cap, 2),
        "capture_rate_pct_12mo": (
            round(100.0 * tot_cap / tot_avail, 2) if tot_avail > 0 else None
        ),
    }

    client_records = []
    for cid, b in by_client.items():
        cov = coverage_by_client.get(cid, {"terms": 0, "vendors": 0})
        client_records.append({
            "client_id": cid,
            "terms_configured": cov["terms"],
            "vendors_tagged": cov["vendors"],
            "eligible_invoices_12mo": b["eligible"],
            "available_12mo": round(b["available"], 2),
            "captured_12mo": round(b["captured"], 2),
            "missed_12mo": round(b["available"] - b["captured"], 2),
            "capture_rate_pct_12mo": (
                round(100.0 * b["captured"] / b["available"], 2)
                if b["available"] > 0 else None
            ),
        })
    # Sort by biggest missed dollars first — where the product intervention pays.
    client_records.sort(key=lambda x: -x["missed_12mo"])

    return {
        "as_of": now.strftime("%Y-%m-%d"),
        "trailing_period_months": 12,
        "notes": SHARED_NOTES,
        "config_gap": config_gap,
        "capture_portfolio": portfolio,
        "monthly": monthly,
        "clients": client_records,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--coverage", type=Path, required=True,
                    help="Config-coverage JSON (Query A output)")
    ap.add_argument("--capture", type=Path, required=True,
                    help="Capture JSON (Query B output)")
    ap.add_argument("--output", type=Path,
                    default=Path("data/early-pay.json"))
    args = ap.parse_args()

    for p in (args.coverage, args.capture):
        if not p.exists():
            print(f"ERROR: input not found: {p}", file=sys.stderr)
            sys.exit(1)

    coverage_rows = _load(args.coverage)
    capture_rows = _load(args.capture)
    result = build(coverage_rows, capture_rows)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as f:
        json.dump(result, f, indent=2)
    print(
        f"Wrote {args.output} — "
        f"{result['config_gap']['clients_with_terms_configured']} clients with terms, "
        f"{result['capture_portfolio']['clients_with_activity']} with capture activity, "
        f"${result['capture_portfolio']['discount_missed_sum_12mo']:,.0f} missed."
    )


if __name__ == "__main__":
    main()
