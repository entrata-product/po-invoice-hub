#!/usr/bin/env bash
# refresh-all.sh — orchestrator for the accounting-ops-hub data refresh.
#
# Runs each data slice, updates the refresh-status timestamp, prints a diff summary.
# Does NOT commit or push — the caller (skill or human) reviews the diff and pushes explicitly.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== Accounting Ops Hub refresh ==="
echo ""

echo "[1/5] PO metrics (production-ready)"
python3 scripts/refresh_redshift.py --query po_core              --window 30d  --out data/po-kpis.json
python3 scripts/refresh_redshift.py --query po_monthly           --window 12mo --out data/po-monthly.json
python3 scripts/refresh_redshift.py --query po_rejection_reasons --window 30d  --out data/po-rejection-reasons.json
python3 scripts/refresh_redshift.py --query po_source_mix        --window 30d  --out data/po-source-mix.json
python3 scripts/refresh_redshift.py --query po_adoption          --window 30d  --out data/po-adoption.json
echo ""

echo "[2/5] Invoice metrics (PROVISIONAL — will skip if dev flag unset)"
if [ "${INVOICE_SQL_DEV_RESOLVED:-0}" = "1" ]; then
  python3 scripts/refresh_redshift.py --query invoice_core        --window 30d  --out data/invoice-kpis.json
  python3 scripts/refresh_redshift.py --query invoice_monthly     --window 12mo --out data/invoice-monthly.json
  python3 scripts/refresh_redshift.py --query invoice_source_mix  --window 30d  --out data/invoice-source-mix.json
  python3 scripts/refresh_redshift.py --query invoice_adoption    --window 30d  --out data/invoice-adoption.json
else
  echo "  Skipped. Set INVOICE_SQL_DEV_RESOLVED=1 once source_id + invoice_audit_log are dev-confirmed."
fi
echo ""

echo "[3/5] IPS corrections (from csm-quick-wins output; expected to be pre-populated)"
echo "  data/ips-corrections.json — verify pre-populated. Not auto-generated here."
echo ""

echo "[4/5] Roadmap (Jira live)"
node scripts/fetch_jira_roadmap.mjs \
  --jql 'component = "PXF - Invoices" AND issuetype = Epic AND status in ("In Dev","Backlog","Ready for Dev","Ready for Refinement")' \
  --out data/roadmap.json
echo ""

echo "[5/5] Refresh timestamp"
python3 -c "
import json, datetime, os
ts = datetime.datetime.utcnow().isoformat() + 'Z'
who = os.environ.get('USER', 'unknown')
json.dump(
    {'last_refresh': ts, 'triggered_by': who, 'status': 'refreshed'},
    open('data/refresh-status.json', 'w'),
    indent=2,
)
print(f'  timestamp: {ts}')
"
echo ""

echo "=== Diff summary ==="
git -C . diff --stat data/ || true
echo ""
echo "Review the diff, then: git add data/ && git commit -m 'Refresh accounting-ops-hub' && git push"
