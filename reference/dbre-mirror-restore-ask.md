# DBRE ask — restore invoice-processing tables to the Redshift mirror

**Requester:** John Braithwaite (Director, Accounting Suite)
**Filed:** 2026-08-17
**Impact area:** PO/Invoice Hub dashboard (public), plus Product's ability to size AP-suite intervention opportunities defensibly
**Status:** Draft — to file with DBRE / Data platform team

---

## Ask, in one sentence

Please refresh or restore the following `entrata_entrata.*` tables in the Redshift mirror so Product can size PO budget-guardrail leakage and Invoice early-pay adoption without relying on a March-2025 archived snapshot.

## Tables required

| Table | Current mirror state | Why Product needs it |
|---|---|---|
| `ap_payee_terms` | **Missing.** Only the archived `ap_payee_terms_removed_03_21_25` snapshot (as of 2025-03-21) is available. | Powers "Early Pay Discount Adoption" on the PO/Invoice Hub. The March-2025 snapshot has ~44 discount-term records across 25 live clients, so anything a client configured or edited after that date is invisible. This turns a real capture-rate story into a caveated snapshot story. |
| `rule_stop_results` | **Missing.** | Required for the primary PO Budget Compliance metric from `DEV-310770` Dataset 1 (`is_over_budget`). Without it we cannot detect PO lines that tripped the routing/budget rule engine. Currently blocking the "Budget guardrail" candidate epic from getting quant-sized. |
| `rule_stops` | **Missing.** | Companion to `rule_stop_results` — identifies which named rule fired. |
| `rule_conditions` | **Missing.** | Companion to `rule_stops` — parameterizes the rule (e.g. threshold amounts, GL scoping). |
| `route_rules` | **Missing.** | Companion table — ties the rule engine to routing config. |

## What we've done in the meantime

- **Invoice Early Pay** — wired the dashboard against `ap_payee_terms_removed_03_21_25` with an explicit `_notes` caveat, framed as a "config adoption gap" first, "capture rate" second (see `data/early-pay.json`, `queries/invoice-early-pay.redshift.sql`).
- **PO Budget Compliance** — deprioritized until the `rule_*` / `route_rules` tables land. Related engineering ticket: `DEV-310770`. The user-penetration slice of that ticket (Dataset 2) is live on the dashboard.
- **Confirmed mirror gaps** by probing `svv_external_tables` and `svv_external_columns` on 2026-08-17.

## Nice-to-have (lower priority than the five above)

- `ap_headers.ap_payee_term_id` and `ap_headers.reversal_ap_header_id` — already in the mirror (confirmed). No action needed.
- Full column set on `ap_allocations`, `ap_details`, `ap_payments` — already sufficient for the capture-side query (confirmed).

## Verification we're happy to help with

Once the tables land, we can run the exact queries against the mirror and confirm row counts / freshness match production. Happy to pair with DBRE on a smoke test.

## Ticket references

- `DEV-310770` — PO metrics for Domo (Pallavi Nawale)
- `DEV-318886` — Invoice metrics for Domo (Pallavi Nawale)
- `DEV-253879` — Invoice KPIs for Domo (Pallavi Nawale) — separate; unblocked
- Dashboard repo: [`entrata-product/po-invoice-hub`](https://github.com/entrata-product/po-invoice-hub)
