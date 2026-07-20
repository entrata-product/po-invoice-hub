/* =====================================================================================
   DATASET 3 — PO-to-Invoice Cycle Time (Domo)
   One row per (PO, Invoice) pair.
   Cycle = invoice_posted_date - po_approved_date (days).

   SOURCE:   Attachment on Jira DEV-253879 (Pallavi Nawale, 2026-07-20).
             filename: dataset_2_po_to_invoice_life_cycle.sql
             (Pallavi renamed dataset numbers mid-thread — this is the
             "PO-to-Invoice cycle" dataset regardless of the "2" or "3" label.)

   DIALECT:  PostgreSQL / Domo. Needs the same Redshift adaptations as
             invoice-core-dataset.sql (schema prefixes, JSONB removal,
             lateral-unnest rewrite, drop single-client filter).

   PM FLAG (from Pallavi):
   - ap_headers.posted_on is usually NULL for invoices.
     invoice_posted_date = COALESCE(posted_on, first ap_header_logs
       'Approved and Posted' / 'Confirmed, Approved and Posted' / 'Auto Approved and Posted').
   ===================================================================================== */

WITH
live_clients AS (
    SELECT c.id AS cid
    FROM clients c
    WHERE c.company_status_type_id = 4
      AND CAST(c.details->>'cluster_id' AS INTEGER) IN (1, 2)
      AND c.id = 12742  -- REMOVE THIS and use required cid
),

live_pos AS (
    SELECT
        h.cid,
        h.id,
        h.approved_on
    FROM ap_headers h
    INNER JOIN live_clients lc ON lc.cid = h.cid
    WHERE h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.deleted_on IS NULL
      AND h.approved_on IS NOT null
),

live_invoices AS (
    SELECT
        h.cid,
        h.id,
        h.created_on,
        h.posted_on,
        h.po_ap_header_ids,
        h.is_posted
    FROM ap_headers h
    INNER JOIN live_clients lc ON lc.cid = h.cid
    WHERE h.ap_header_type_id = 5
      AND h.ap_header_sub_type_id IN (5, 6, 7, 8, 12, 17, 18)
      AND h.is_template = false
      AND h.deleted_on IS NULL
      AND h.reversal_ap_header_id IS NULL
      AND h.po_ap_header_ids IS NOT NULL
      AND cardinality(ARRAY_REMOVE(h.po_ap_header_ids, 0)) > 0 
),

/* Invoice posted timestamp proxy (posted_on is rarely populated) */
invoice_posted AS (
    SELECT
        ahl.cid,
        ahl.ap_header_id AS invoice_id,
        MAX(ahl.log_datetime) AS posted_timestamp
    FROM ap_header_logs ahl
    INNER JOIN live_invoices li
        ON li.cid = ahl.cid AND li.id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 5
      AND ahl.action IN (
          'Approved and Posted',
          'Confirmed, Approved and Posted',
          'Auto Approved and Posted'
      )
      AND li.is_posted = true
    GROUP BY
        ahl.cid,
        ahl.ap_header_id
),

/* Expand invoice → PO links (supports multi-PO invoices) */
invoice_po_links AS (
    SELECT
        li.cid,
        li.id AS invoice_id,
        li.created_on AS invoice_created_on,
        li.posted_on,
        po_id
    FROM live_invoices li
    CROSS JOIN LATERAL UNNEST(ARRAY_REMOVE(li.po_ap_header_ids, 0)) AS po_id
)

SELECT
    ipl.cid                                                         AS client_id,
    ipl.po_id                                                       AS po_id,
    ipl.invoice_id                                                  AS invoice_id,
    po.approved_on                                                  AS po_approved_date,
    COALESCE(ipl.posted_on, ip.posted_timestamp)                    AS invoice_posted_date,
    ROUND(
        EXTRACT(
            EPOCH FROM (
                COALESCE(ipl.posted_on, ip.posted_timestamp) - po.approved_on
            )
        ) / 86400.0,
        2
    )                                                               AS cycle_time_days,
    TO_CHAR(ipl.invoice_created_on, 'YYYY-MM')                      AS creation_month
FROM invoice_po_links ipl
INNER JOIN live_pos po
    ON po.cid = ipl.cid
   AND po.id = ipl.po_id
INNER JOIN invoice_posted ip
    ON ip.cid = ipl.cid
   AND ip.invoice_id = ipl.invoice_id
WHERE COALESCE(ipl.posted_on, ip.posted_timestamp) IS NOT NULL
  AND COALESCE(ipl.posted_on, ip.posted_timestamp) >= po.approved_on
ORDER BY
    creation_month DESC,
    client_id,
    po_id,
    invoice_id;