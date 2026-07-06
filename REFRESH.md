# Refresh Procedure

Two ways to refresh:

1. **PM workspace skill** — run `/refresh-po-invoice-hub` from the john-braithwaite-workspace. The skill orchestrates the whole thing and commits the JSON changes.
2. **Manual** — the steps below, run against a working Redshift connection and a Jira MCP with credentials.

## Prerequisites

- Redshift MCP authenticated (rolling-thunder `login.js` refresh + Cursor MCP server restart if the last query is >24h old).
- Jira credentials available (read from `~/entrata-product/john-braithwaite-workspace/.cursor/mcp.json`, `Jira` server).
- Node 20+ (`node -v`) and Python 3.11+ (`python3 --version`).

## Refresh steps

### 1. PO metrics (production-ready)

```bash
python3 scripts/refresh_redshift.py --query po_core --window 30d --out data/po-kpis.json
python3 scripts/refresh_redshift.py --query po_monthly --window 12mo --out data/po-monthly.json
python3 scripts/refresh_redshift.py --query po_rejection_reasons --window 30d --out data/po-rejection-reasons.json
python3 scripts/refresh_redshift.py --query po_source_mix --window 30d --out data/po-source-mix.json
python3 scripts/refresh_redshift.py --query po_adoption --window 30d --out data/po-adoption.json
```

Base SQL: `queries/po-core-dataset.sql`. Wrap in aggregation for each slice.

### 2. Invoice metrics (provisional — see caveat)

**Do not run until dev has confirmed:**
- Actual `source_id` values that map to each channel (Pallavi's SQL uses placeholder IDs 1-13).
- Real table name for `invoice_audit_log` (may be `ap_header_logs` with a different type filter — pattern matches PO SQL).

Once resolved, mirror the PO commands with `--query invoice_*` and `data/invoice-*.json`.

### 3. IPS corrections (from PM workspace skill)

```bash
# From the PM workspace:
cursor run /csm-quick-wins --aggregate --output po-invoice-hub/data/ips-corrections.json
```

The `csm-quick-wins` skill runs client-specific IPS analysis; we roll up across active IPS clients here.

### 4. Roadmap (Jira)

```bash
node scripts/fetch_jira_roadmap.mjs \
  --jql 'component in ("PXF - Invoices", "ELI", "IPS") AND issuetype = Epic AND status in ("In Dev","Backlog","Ready for Dev")' \
  --out data/roadmap.json
```

### 5. Client voice

Same pattern as vendor-hub: pull NPS, Zendesk, Gong filtered on AP suite keywords, merge to `data/client-voice.json`.

### 6. Timestamp

```bash
python3 -c "import json,datetime;json.dump({'last_refresh':datetime.datetime.utcnow().isoformat()+'Z','triggered_by':'manual'},open('data/refresh-status.json','w'),indent=2)"
```

### 7. Commit + push

```bash
git add data/
git diff --cached --stat        # sanity: only data/*.json files change
git commit -m "Refresh po-invoice-hub data ($(date -u +%Y-%m-%d))"
git push origin main
```

GitHub Pages picks up the change within 1-2 minutes.

## Anti-patterns

- Do not edit `queries/*.sql` — those are canonical from Pallavi's Jira attachments.
- Do not edit `reference/*.html` — those are her Domo mocks, kept read-only for design traceability.
- Do not run the invoice SQL against Redshift as-is — it contains placeholders that will fail.
- Never hardcode dates in `index.html` — the refresh timestamp lives in `data/refresh-status.json` and is injected at runtime.
