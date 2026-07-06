# Accounting Ops Hub

A single-view dashboard for the AP suite: **Purchase Orders, Invoices, Invoice Processing (IPS), and ELI Invoice Entry**.

Sibling to the [Vendor Enablement Hub](https://github.com/entrata-product/vendor-enablement-hub) — same architecture, different product area.

## What it does

Six narrative tabs, each answering a question a director/CSM/PM would actually ask:

| Tab | Question | Data source |
|---|---|---|
| **Overview** | How is the AP suite doing at a glance? | Aggregate KPIs across all 4 products |
| **Adoption** | Who's using each product, by segment and release track? | `client_segment` + `client_release_track` from Pallavi's SQL |
| **Health** | For product X — what are all the operational metrics? | Full 9-KPI grid per product (matches Pallavi's Domo mocks) |
| **Client Voice** | What are clients saying about the AP suite? | NPS + Zendesk + Gong signals filtered to AP products |
| **Roadmap** | What's shipping next? | Live Jira pull on `PXF - Invoices` component + adjacent |
| **CS Toolkit** | Client-specific quick wins a CSM can walk into a call with | `csm-quick-wins` skill outputs + rejection root-cause packs |

Two views:
- **Focus** — executive one-page narrative (default). Six shared KPIs + 3 sections.
- **Advanced** — full 6-tab detail.

## Data sources

**Production-ready (wire immediately):**
- Purchase Orders → `queries/po-core-dataset.sql` (DEV-231807, Done, Pallavi Nawale)
- IPS corrections → `csm-quick-wins` skill in the PM workspace

**Provisional (needs dev pairing before live):**
- Invoices → `queries/invoice-metrics.sql` (DEV-253879, Ready for Dev). Contains placeholders for `source_id` mapping and `invoice_audit_log` table — dev must resolve before running in prod.

**Adjacent:**
- Roadmap → Jira via `scripts/fetch_jira_roadmap.mjs` (same pattern as vendor-hub)
- Client voice → NPS/Zendesk/Gong (same pattern as vendor-hub)

## Layout

```
accounting-ops-hub/
├── index.html                    # Six-tab dashboard, Focus/Advanced toggle
├── README.md                     # This file
├── REFRESH.md                    # Manual refresh instructions
├── data/                         # JSON files loaded at runtime
│   ├── refresh-status.json
│   ├── po-*.json                 # PO metrics slices
│   ├── invoice-*.json            # Invoice metrics slices
│   ├── ips-corrections.json
│   ├── client-voice.json
│   └── roadmap.json
├── queries/                      # Canonical SQL from Pallavi
│   ├── po-core-dataset.sql
│   └── invoice-metrics.sql
├── reference/                    # Read-only design source-of-truth
│   ├── domo-po-metrics.html      # Pallavi's Domo mock for PO
│   ├── domo-invoice-metrics.html # Pallavi's Domo mock for Invoice
│   └── design-provenance.md
└── scripts/                      # Refresh orchestrators
    ├── refresh-all.sh
    ├── refresh_redshift.py
    └── fetch_jira_roadmap.mjs
```

## Refresh

See [`REFRESH.md`](./REFRESH.md) for the manual refresh procedure, or run the `refresh-accounting-hub` skill from the PM workspace.

## Provenance

Started 2026-07-06 by John Braithwaite. Design pattern lifted from [`vendor-enablement-hub`](https://github.com/entrata-product/vendor-enablement-hub). SQL sourced from Pallavi Nawale's DEV-231807 + DEV-253879 subtasks under DEV-231191 ("Metrics for Core AP KPIs R3 2026").
