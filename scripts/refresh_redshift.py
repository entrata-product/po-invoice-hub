#!/usr/bin/env python3
"""
refresh_redshift.py — placeholder for the PO/Invoice Redshift refresh runner.

This is a STUB scaffold. The full implementation should:
  1. Read Redshift credentials from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
     (refreshed by rolling-thunder's login.js).
  2. Take --query one of: po_core, po_monthly, po_rejection_reasons, po_source_mix, po_adoption,
     invoice_core (once dev-resolved), invoice_monthly, etc.
  3. Build the SQL from queries/*.sql, optionally wrap in a GROUP BY aggregate for the slice.
  4. Execute against the Redshift AP performance data mart.
  5. Emit a compact JSON to --out.

For now, this stub emits a placeholder JSON so the orchestrator flow can be tested end-to-end.
"""
import argparse
import datetime
import json
import sys
from pathlib import Path

VALID_QUERIES = {
    "po_core", "po_monthly", "po_rejection_reasons", "po_source_mix", "po_adoption",
    "invoice_core", "invoice_monthly", "invoice_source_mix", "invoice_adoption",
}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--query", required=True, choices=sorted(VALID_QUERIES))
    p.add_argument("--window", default="30d")
    p.add_argument("--out", required=True)
    args = p.parse_args()

    if args.query.startswith("invoice"):
        print(
            f"WARN: invoice_* queries are provisional. Pallavi's SQL (DEV-253879) has\n"
            f"placeholders for source_id mapping and invoice_audit_log table name.\n"
            f"Do not run against production until dev has resolved these.",
            file=sys.stderr,
        )

    payload = {
        "_status": "stub_run",
        "_generated_at": datetime.datetime.utcnow().isoformat() + "Z",
        "_query": args.query,
        "_window": args.window,
        "_note": "This is a stub. Replace refresh_redshift.py with a real Redshift runner.",
        "data": None,
    }
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(payload, f, indent=2)
    print(f"stub written: {args.out}")


if __name__ == "__main__":
    main()
