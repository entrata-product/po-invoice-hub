# PO/Invoice Hub — moved

This repository has moved to **[Entrata-Collab/po-invoice-hub](https://github.com/Entrata-Collab/po-invoice-hub)**.

**Live URL (Entrata VPN required):** http://po-invoice.prototype.entrata.io/

## Why the move

The hub grew from a research artifact into a cross-team decision surface (Product, CS, Finance leadership). It now lives in `Entrata-Collab` alongside its sibling [`vendor-enablement-hub`](https://github.com/Entrata-Collab/vendor-enablement-hub) so people outside R&D can find and contribute to it.

Same rationale that moved the Vendor Enablement Hub to Collab on 2026-07-06.

## What lives where now

| Concern | Location |
|---|---|
| Latest code + data | [Entrata-Collab/po-invoice-hub](https://github.com/Entrata-Collab/po-invoice-hub) |
| Live dashboard | http://po-invoice.prototype.entrata.io/ *(VPN)* |
| Deploy pipeline | GitHub Actions on push to `main` → ECR → ECS Fargate |
| Refresh procedure | `Entrata-Collab/po-invoice-hub/REFRESH.md` + the `refresh-po-invoice-hub` skill in the PM workspace |
| Historical work in this repo | Preserved verbatim — all commits through 2026-08-19 are here |

## This repo is frozen

No new commits will land here. The full history through the migration point is preserved for audit / archaeology. Please open issues, PRs, and discussions in the [Entrata-Collab repo](https://github.com/Entrata-Collab/po-invoice-hub) instead.

## Provenance

Started 2026-07-06 as a sibling to `entrata-product/vendor-enablement-hub`. Migrated to `Entrata-Collab/po-invoice-hub` on 2026-08-19 (see infra commit `9366b19` in the new repo — adds Docker/ECS deploy scaffolding and moves the hub to the prototype VPC).
