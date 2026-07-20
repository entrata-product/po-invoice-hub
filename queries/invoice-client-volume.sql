/* =====================================================================================
   INVOICE CLIENT VOLUME + MONTHLY TREND (Domo)

   Two queries in one file:
     1) Monthly trend: client × month × invoice_type → count + dollar volume
     2) Top-20 clients by all-time and trailing-30d invoice count / volume

   SOURCE:   Attachment on Jira DEV-253879 (Pallavi Nawale, 2026-07-20).
             filename: client_invoice_count_and_total_dollar_volume.sql

   DIALECT:  PostgreSQL / Domo. Needs the same Redshift adaptations as
             invoice-core-dataset.sql (schema prefixes, JSONB removal).

   NOTE:     The top-20 query has the single-client filter already commented
             out, so it's the closest to ready-to-run of the three.
   ===================================================================================== */

/* =====================================================================================
   Query 1 — MONTHLY TREND
   Group by creation_month (YYYY-MM) and invoice_type
   ===================================================================================== */
WITH
live_clients AS (
    SELECT c.id AS cid
    FROM clients c
    WHERE c.company_status_type_id = 4
      AND CAST(c.details->>'cluster_id' AS INTEGER) IN (1, 2)
      AND c.id = 12742  --REPLACE CID HERE
),
live_invoices AS (
    SELECT
        h.cid,
        h.id,
        h.created_on,
        h.ap_header_sub_type_id,
        COALESCE(h.transaction_amount, 0) AS transaction_amount
    FROM ap_headers h
    INNER JOIN live_clients lc ON lc.cid = h.cid
    WHERE h.ap_header_type_id     = 5
      AND h.ap_header_sub_type_id IN (5, 6, 7, 8, 12, 17, 18)
      AND h.is_template           = false
      AND h.deleted_on IS NULL
)
SELECT
    li.cid                                                          AS client_id,
    TO_CHAR(li.created_on, 'YYYY-MM')                               AS creation_month,
    CASE li.ap_header_sub_type_id
        WHEN 5  THEN 'Standard'
        WHEN 6  THEN 'Management Fee'
        WHEN 7  THEN 'Owner Distribution'
        WHEN 8  THEN 'Catalog'
        WHEN 12 THEN 'Credit Memo'
        WHEN 17 THEN 'Job Costing'
        WHEN 18 THEN 'Job Costing'
        ELSE 'Other'
    END                                                             AS invoice_type,
    COUNT(*)                                                        AS invoice_count,
    ROUND(SUM(li.transaction_amount)::NUMERIC, 2)                   AS total_dollar_volume
FROM live_invoices li
GROUP BY
    li.cid,
    TO_CHAR(li.created_on, 'YYYY-MM'),
    CASE li.ap_header_sub_type_id
        WHEN 5  THEN 'Standard'
        WHEN 6  THEN 'Management Fee'
        WHEN 7  THEN 'Owner Distribution'
        WHEN 8  THEN 'Catalog'
        WHEN 12 THEN 'Credit Memo'
        WHEN 17 THEN 'Job Costing'
        WHEN 18 THEN 'Job Costing'
        ELSE 'Other'
    END
ORDER BY
    creation_month DESC,
    invoice_type;





/* =====================================================================================
   TOP 20 CLIENTS BY INVOICE COUNT / DOLLAR VOLUME
   All-time and trailing 30 days
   ===================================================================================== */
WITH
live_clients AS (
    SELECT
        c.id AS cid,
        CASE CAST(c.details->>'cluster_id' AS INTEGER)
            WHEN 1 THEN 'Rapid'
            WHEN 2 THEN 'Standard'
        END AS release_track
    FROM clients c
    WHERE c.company_status_type_id = 4
      AND CAST(c.details->>'cluster_id' AS INTEGER) IN (1, 2)
      -- AND c.id = 12742  -- optional single-client test
),
live_invoices AS (
    SELECT
        h.cid,
        h.created_on,
        COALESCE(h.transaction_amount, 0) AS transaction_amount
    FROM ap_headers h
    INNER JOIN live_clients lc ON lc.cid = h.cid
    WHERE h.ap_header_type_id     = 5
      AND h.ap_header_sub_type_id IN (5, 6, 7, 8, 12, 17, 18)
      AND h.is_template           = false
      AND h.deleted_on IS NULL
),
client_metrics AS (
    SELECT
        li.cid                                                        AS client_id,
        COUNT(*)                                                      AS invoice_count_all_time,
        COUNT(*) FILTER (
            WHERE li.created_on >= (CURRENT_TIMESTAMP - INTERVAL '30 days')
        )                                                             AS invoice_count_trailing_30d,
        ROUND(SUM(li.transaction_amount)::NUMERIC, 2)                 AS total_dollar_volume_all_time,
        ROUND(SUM(li.transaction_amount) FILTER (
            WHERE li.created_on >= (CURRENT_TIMESTAMP - INTERVAL '30 days')
        )::NUMERIC, 2)                                                AS total_dollar_volume_trailing_30d
    FROM live_invoices li
    GROUP BY li.cid
)
SELECT
    cm.client_id,
    lc.release_track,
    cm.invoice_count_all_time,
    cm.invoice_count_trailing_30d,
    cm.total_dollar_volume_all_time,
    cm.total_dollar_volume_trailing_30d
 
FROM client_metrics cm
INNER JOIN live_clients lc ON lc.cid = cm.client_id
ORDER BY cm.invoice_count_all_time DESC   -- swap for volume rankings below
LIMIT 20;