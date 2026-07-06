# Design Provenance

These files are the source-of-truth Pallavi Nawale attached to Jira. Do not edit them in-place.
Modifications to the hub live in `../index.html` and `../data/`; these are read-only reference.

## Reference files

| File | From | Status | What it is |
|---|---|---|---|
| `domo-po-metrics.html` | DEV-231807 | Done | Standalone HTML mock of the PO metrics Domo dashboard. 9 KPI cards + 8 Chart.js visualizations. |
| `domo-invoice-metrics.html` | DEV-253879 | Ready for Dev | Standalone HTML mock of the Invoice metrics Domo dashboard. 9 KPI cards + 8 Chart.js visualizations. |
| `../queries/po-core-dataset.sql` | DEV-231807 | Production-ready | 30-field PO Core Dataset SQL. Live Rapid + Standard clients only. |
| `../queries/invoice-metrics.sql` | DEV-253879 | Spec, needs dev | Invoice Core + 3 supplemental datasets. Contains placeholders (`source_id` mapping, `invoice_audit_log` table name) — dev pairing required before live. |

## Fetched

Downloaded from Jira via authenticated API (`/rest/api/3/attachment/content/<id>`) on 2026-07-06.

Attachment IDs preserved for re-download:

- PO SQL: `388103`
- Invoice SQL: `364908`
- PO HTML: `334697`
- Invoice HTML: `334691`

## KPIs captured across both mocks

Nine per product:

**PO (DEV-231807):** Total POs Created, Active Clients Using POs, Avg Approval Time, Total PO Value, First-Time-Right Rate, Budget Compliance Rate, Rejection/Reroute Rate, User Penetration Rate, PDF Attachment Rate.

**Invoice (DEV-253879):** Total Invoices Created, Active Clients Using Invoices, Avg End-to-End Processing Time, First-Time-Right Rate, Early Pay Discount Capture, PO-to-Invoice Cycle Time, Rejection/Reroute Rate, User Penetration Rate, PDF Attachment Rate.

Five KPIs pair across both products (natural side-by-side view): First-Time-Right, Rejection Rate, User Penetration, PDF Attachment, Approval Time.

## Where they map to in `index.html`

- **Overview tab (Advanced)** — 6-KPI stats strip pulls the shared subset.
- **Health tab (Advanced)** — full 9-per-product grids under the product picker.
- **Focus view** — top 6 shared KPIs, plus 3 narrative sections.
