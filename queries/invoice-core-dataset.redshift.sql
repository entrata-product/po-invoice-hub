/* =====================================================================================
   DATASET 1 — INVOICE CORE DATASET (Redshift-adapted) — REFERENCE
   One row per Invoice. Live clients only (Rapid/Standard track unavailable
   without cluster_id — see live_clients CTE).

   SOURCE:   queries/invoice-core-dataset.sql  (Pallavi Nawale via DEV-253879, 2026-07-20)
   TARGET:   AWS Redshift, schema entrata_entrata.*

   ADAPTATIONS vs Pallavi's Domo/PG original:
     1. Prefixed every table with `entrata_entrata.`.
     2. `c.details->>'cluster_id'` JSONB path is NOT mirrored to Redshift.
        We keep the live-client filter (company_status_type_id = 4) and set
        release_track = NULL. Restore once DBRE surfaces cluster_id.
     3. `COUNT(*) FILTER (WHERE ...)` → `SUM(CASE WHEN ... THEN 1 ELSE 0 END)`.
     4. `ARRAY_AGG(... ORDER BY ...)[1]` → `ROW_NUMBER() OVER (...)` subquery.
     5. `DISTINCT ON (cid, ap_header_id)` → `ROW_NUMBER()` window with rn = 1.
     6. `entrata_entrata.rule_stop_results` is NOT mirrored → routing_events
        emits an empty CTE (WHERE 1 = 0). Downstream, routing_assigned_timestamp
        is NULL and system_processing_hours degrades to "no routing signal";
        approver_wait_hours falls back to (approved_on - created_on).
        Restore once DBRE mirrors rule_stop_results.
     7. `invoice_plus_batches.ap_header_ids` is an integer[] array requiring
        CROSS JOIN LATERAL UNNEST — not natively supported in Redshift for
        integer arrays without SUPER type support. We drop the batch-array
        fallback branch and detect ELI-processed invoices only via the
        direct `invoice_plus_file_processors` path. This may under-count
        ELI adoption for invoices linked via batches only (expected to be
        a small fraction; measure once mirror supports SUPER unnest).
     8. `created_from_po` uses `cardinality(ARRAY_REMOVE(po_ap_header_ids, 0))`
        which is PG-specific. We fall back to a plain
        `po_ap_header_ids IS NOT NULL` check (mild over-count of invoices
        whose array is literally `{0}`, which per Pallavi's own filter is rare).
     9. `BOOL_OR(...)` — supported in modern Redshift; kept as-is.
    10. Single-client filter `AND c.id = 12742` removed for portfolio runs.

   INHERITED CAVEATS (from Pallavi's original, unchanged by adaptation):
     - is_first_time_right = "posted AND rejection_count = 0". Reroute events
       are NOT deducted because they can't be counted for multi-property invoices.
     - is_exception is not available (validation errors aren't persisted).
     - Source-channel "Dashboard Shortcut" and "Duplicate / Use Previous" cannot
       be tracked (no field or log). Those invoices land in the fallback bucket.
     - property_id on multi-property invoices = first line item's property.
     - rejection_count = Rejected + Returned To Previous + Returned To Beginning.

   USAGE:
     - This file is the REFERENCE (per-invoice grain). For portfolio-wide
       execution through the Redshift MCP, use `invoice-monthly-kpis.redshift.sql`
       which aggregates at (month × segment × release_track) grain and returns
       far fewer rows.
     - To smoke-test this file for a single client, add
       `AND c.id = <cid>` in live_clients.
   ===================================================================================== */

WITH
live_clients AS (
    SELECT
        c.id AS cid,
        CAST(NULL AS VARCHAR) AS release_track
    FROM entrata_entrata.clients c
    WHERE c.company_status_type_id = 4
),

live_invoices AS (
    SELECT h.*
    FROM entrata_entrata.ap_headers h
    INNER JOIN live_clients lc ON lc.cid = h.cid
    WHERE h.ap_header_type_id = 5                             -- Invoice
      AND h.ap_header_sub_type_id IN (
          5,   -- Standard
          6,   -- Management Fee
          7,   -- Owner Distribution
          8,   -- Catalog
          12,  -- Credit Memo
          17,  -- Standard Job
          18   -- Catalog Job
      )
      AND COALESCE(h.is_template, false) = false
),

client_units AS (
    SELECT
        p.cid,
        SUM(p.number_of_units) AS total_units
    FROM entrata_entrata.properties p
    INNER JOIN live_clients lc ON lc.cid = p.cid
    WHERE p.is_test = 0
      AND p.is_disabled = 0
      AND p.termination_date IS NULL
    GROUP BY p.cid
),

invoice_properties AS (
    SELECT cid, ap_header_id, property_id AS first_property_id
    FROM (
        SELECT
            ad.cid,
            ad.ap_header_id,
            ad.property_id,
            ROW_NUMBER() OVER (
                PARTITION BY ad.cid, ad.ap_header_id
                ORDER BY ad.id
            ) AS rn
        FROM entrata_entrata.ap_details ad
        INNER JOIN live_invoices li
            ON li.cid = ad.cid AND li.id = ad.ap_header_id
        JOIN entrata_entrata.properties p
            ON p.cid = ad.cid AND p.id = ad.property_id
           AND p.is_test = 0
           AND p.is_disabled = 0
           AND p.termination_date IS NULL
        WHERE ad.deleted_on IS NULL
    ) WHERE rn = 1
),

invoice_attachments AS (
    SELECT
        fa.cid,
        fa.ap_header_id,
        COUNT(*) AS attachment_count
    FROM entrata_entrata.file_associations fa
    INNER JOIN live_invoices li
        ON li.cid = fa.cid AND li.id = fa.ap_header_id
    WHERE fa.ap_header_id IS NOT NULL
      AND fa.deleted_on IS NULL
    GROUP BY fa.cid, fa.ap_header_id
),

/* ELI (AI) detection — direct file_processors path only.
   Batch-array fallback dropped due to Redshift UNNEST limitation (see file
   header note #7). */
invoice_plus_linked AS (
    SELECT
        ipfp.cid,
        ipfp.ap_header_id,
        BOOL_OR(COALESCE(ipb.is_ai_processed, false)) AS is_ai_processed
    FROM entrata_entrata.invoice_plus_file_processors ipfp
    INNER JOIN live_invoices li
        ON li.cid = ipfp.cid AND li.id = ipfp.ap_header_id
    LEFT JOIN entrata_entrata.invoice_plus_batches ipb
        ON ipb.cid = ipfp.cid
       AND ipb.id = ipfp.invoice_plus_batch_id
    WHERE ipfp.ap_header_id IS NOT NULL
    GROUP BY ipfp.cid, ipfp.ap_header_id
),

invoice_imported AS (
    SELECT DISTINCT
        ahl.cid,
        ahl.ap_header_id
    FROM entrata_entrata.ap_header_logs ahl
    INNER JOIN live_invoices li
        ON li.cid = ahl.cid AND li.id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 5
      AND ahl.action = 'Imported'
),

/* Simplified from Pallavi's cardinality(ARRAY_REMOVE(...)) predicate.
   See file header note #8. */
created_from_po AS (
    SELECT DISTINCT
        ahl.cid,
        ahl.ap_header_id
    FROM entrata_entrata.ap_header_logs ahl
    INNER JOIN live_invoices li
        ON li.cid = ahl.cid AND li.id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 5
      AND ahl.action = 'Created'
      AND ahl.po_ap_header_ids IS NOT NULL
),

log_agg AS (
    SELECT
        ahl.cid,
        ahl.ap_header_id,
        SUM(CASE WHEN ahl.action IN (
            'Rejected',
            'Returned To Previous',
            'Returned To Beginning'
        ) THEN 1 ELSE 0 END) AS rejection_count,
        SUM(CASE WHEN ahl.action = 'Edited' THEN 1 ELSE 0 END) AS edit_count
    FROM entrata_entrata.ap_header_logs ahl
    INNER JOIN live_invoices li
        ON li.cid = ahl.cid AND li.id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 5
    GROUP BY ahl.cid, ahl.ap_header_id
),

first_rejection AS (
    SELECT cid, ap_header_id, first_rejection_reason
    FROM (
        SELECT
            ahl.cid,
            ahl.ap_header_id,
            ahl.approval_note AS first_rejection_reason,
            ROW_NUMBER() OVER (
                PARTITION BY ahl.cid, ahl.ap_header_id
                ORDER BY ahl.log_datetime ASC
            ) AS rn
        FROM entrata_entrata.ap_header_logs ahl
        INNER JOIN live_invoices li
            ON li.cid = ahl.cid AND li.id = ahl.ap_header_id
        WHERE ahl.ap_header_type_id = 5
          AND ahl.action IN ('Rejected', 'Returned To Previous', 'Returned To Beginning')
    ) WHERE rn = 1
),

/* routing signal unavailable — see file header note #6. */
routing_events AS (
    SELECT
        CAST(NULL AS INTEGER)   AS cid,
        CAST(NULL AS INTEGER)   AS ap_header_id,
        CAST(NULL AS TIMESTAMP) AS created_on
    WHERE 1 = 0
),
routing AS (
    SELECT
        re.cid,
        re.ap_header_id,
        MIN(re.created_on) AS routing_assigned_timestamp
    FROM routing_events re
    GROUP BY re.cid, re.ap_header_id
),

posted_events AS (
    SELECT
        ahl.cid,
        ahl.ap_header_id,
        MAX(ahl.log_datetime) AS posted_timestamp
    FROM entrata_entrata.ap_header_logs ahl
    INNER JOIN live_invoices li
        ON li.cid = ahl.cid AND li.id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 5
      AND ahl.action IN (
          'Approved and Posted',
          'Confirmed, Approved and Posted',
          'Auto Approved and Posted'
      )
    GROUP BY ahl.cid, ahl.ap_header_id
),

invoice_facts AS (
SELECT
    h.id                                                            AS invoice_id,
    h.header_number,
    h.cid                                                           AS client_id,
    COALESCE(h.posted_on, pe.posted_timestamp)                      AS posted_timestamp,
    h.created_on,
    h.approved_on,
    COALESCE(h.bulk_property_id, ip.first_property_id)              AS property_id,

    h.created_on::date                                              AS creation_date,
    TO_CHAR(h.created_on, 'YYYY-MM')                                AS creation_month,

    CASE h.ap_header_sub_type_id
        WHEN 5  THEN 'Standard'
        WHEN 6  THEN 'Management Fee'
        WHEN 7  THEN 'Owner Distribution'
        WHEN 8  THEN 'Catalog'
        WHEN 12 THEN 'Credit Memo'
        WHEN 17 THEN 'Job Costing'
        WHEN 18 THEN 'Job Costing'
        ELSE 'Other'
    END                                                             AS invoice_type,

    CASE
        WHEN h.is_deleted = true OR h.ap_financial_status_type_id = 8 THEN 'Deleted'
        WHEN h.ap_financial_status_type_id = 6                        THEN 'Rejected'
        WHEN h.is_posted = true                                       THEN 'Posted'
        ELSE 'Pending'
    END                                                             AS invoice_status,

    CASE
        WHEN h.created_by = 21
            THEN 'Vendor Portal'
        WHEN h.created_by = 48
            THEN 'UEM'
        WHEN h.created_by IN (77, 67)
            THEN 'Invoice Processing (Manual Entry/Upload)'
        WHEN h.template_ap_header_id IS NOT NULL
         AND h.created_by = 16
            THEN 'Recurring Transaction'
        WHEN h.template_ap_header_id IS NOT NULL
            THEN 'Invoice Template'
        WHEN imp.ap_header_id IS NOT NULL
          OR COALESCE(h.is_initial_import, false) = true
            THEN 'Invoice Import'
        WHEN COALESCE(ipl.is_ai_processed, false) = true
            THEN 'ELI Invoice Entry'
        WHEN ipl.ap_header_id IS NOT NULL
            THEN 'Bulk Invoice Entry'
        WHEN h.ap_batch_id IS NOT NULL
            THEN 'Old Bulk Invoice Entry'
        WHEN cfp.ap_header_id IS NOT NULL
            THEN 'Purchase Orders: Create Invoice'
        WHEN cu_api.id IS NOT NULL
            THEN 'API'
        WHEN cu_app.id IS NOT NULL
            THEN 'App User'
        ELSE 'Add Invoice (Manual)'
    END                                                             AS source_channel,

    COALESCE(h.transaction_amount, 0)                               AS invoice_total_amount,
    CASE WHEN ia.ap_header_id IS NOT NULL THEN 1 ELSE 0 END         AS has_attachment,

    CASE
        WHEN h.is_posted = true
         AND COALESCE(h.posted_on, pe.posted_timestamp) IS NOT NULL
            THEN ROUND(
                EXTRACT(EPOCH FROM (
                    COALESCE(h.posted_on, pe.posted_timestamp) - h.created_on
                )) / 86400.0
            , 2)
    END                                                             AS days_to_posted,

    CASE WHEN h.approved_on IS NOT NULL
        THEN ROUND(EXTRACT(EPOCH FROM (h.approved_on - h.created_on)) / 86400.0, 2)
    END                                                             AS days_to_approved,

    CASE
        WHEN h.is_posted = false THEN NULL
        WHEN h.is_posted = true
         AND COALESCE(la.edit_count, 0) = 0 THEN 1
        ELSE 0
    END                                                             AS is_touchless,

    CASE
        WHEN COALESCE(la.rejection_count, 0) > 0 THEN 0
        WHEN h.is_posted = true THEN 1
        ELSE NULL
    END                                                             AS is_first_time_right,

    COALESCE(la.rejection_count, 0)                                 AS rejection_count,
    fr.first_rejection_reason                                       AS rejection_reason,

    CASE
        WHEN COALESCE(la.rejection_count, 0) = 0 THEN NULL
        WHEN fr.first_rejection_reason IS NULL THEN 'OTHER'
        WHEN fr.first_rejection_reason ILIKE '%wrong approver%'
          OR fr.first_rejection_reason ILIKE '%not my approval%'
          OR fr.first_rejection_reason ILIKE '%reroute%'
          OR fr.first_rejection_reason ILIKE '%reassign%'
            THEN 'ROUTING_ERROR'
        WHEN fr.first_rejection_reason ILIKE '%amount%'
          OR fr.first_rejection_reason ILIKE '%GL%'
          OR fr.first_rejection_reason ILIKE '%coding%'
          OR fr.first_rejection_reason ILIKE '%vendor%'
          OR fr.first_rejection_reason ILIKE '%duplicate line%'
          OR fr.first_rejection_reason ILIKE '%wrong account%'
          OR fr.first_rejection_reason ILIKE '%fix%'
          OR fr.first_rejection_reason ILIKE '%correct%'
            THEN 'DATA_CORRECTION'
        WHEN fr.first_rejection_reason ILIKE '%duplicate invoice%'
          OR fr.first_rejection_reason ILIKE '%not authorized%'
          OR fr.first_rejection_reason ILIKE '%unauthorized%'
          OR fr.first_rejection_reason ILIKE '%over budget%'
          OR fr.first_rejection_reason ILIKE '%disputed%'
          OR fr.first_rejection_reason ILIKE '%do not pay%'
          OR fr.first_rejection_reason ILIKE '%cancelled%'
            THEN 'BUSINESS_REJECTION'
        ELSE 'OTHER'
    END                                                             AS rejection_category,

    r.routing_assigned_timestamp,

    /* system_processing_hours: degrades to NULL for now because rule_stop_results
       isn't mirrored (see file header note #6). */
    CAST(NULL AS NUMERIC)                                           AS system_processing_hours,

    CASE
        WHEN h.approved_on IS NOT NULL
            THEN ROUND(
                EXTRACT(EPOCH FROM (h.approved_on - h.created_on)) / 3600.0
            , 2)
    END                                                             AS approver_wait_hours,

    lc.release_track                                                AS client_release_track,
    CASE
        WHEN cu_units.total_units >= 500      THEN 'Enterprise'
        WHEN cu_units.total_units >= 100      THEN 'Mid-Market'
        WHEN cu_units.total_units IS NOT NULL THEN 'Small'
        ELSE 'Unknown'
    END                                                             AS client_segment,
    cu_units.total_units                                            AS client_total_units,

FROM live_invoices h
INNER JOIN live_clients lc
    ON lc.cid = h.cid
LEFT JOIN client_units cu_units
    ON cu_units.cid = h.cid
LEFT JOIN invoice_properties ip
    ON ip.cid = h.cid AND ip.ap_header_id = h.id
LEFT JOIN invoice_attachments ia
    ON ia.cid = h.cid AND ia.ap_header_id = h.id
LEFT JOIN invoice_plus_linked ipl
    ON ipl.cid = h.cid AND ipl.ap_header_id = h.id
LEFT JOIN invoice_imported imp
    ON imp.cid = h.cid AND imp.ap_header_id = h.id
LEFT JOIN created_from_po cfp
    ON cfp.cid = h.cid AND cfp.ap_header_id = h.id
LEFT JOIN log_agg la
    ON la.cid = h.cid AND la.ap_header_id = h.id
LEFT JOIN first_rejection fr
    ON fr.cid = h.cid AND fr.ap_header_id = h.id
LEFT JOIN routing r
    ON r.cid = h.cid AND r.ap_header_id = h.id
LEFT JOIN posted_events pe
    ON pe.cid = h.cid AND pe.ap_header_id = h.id
LEFT JOIN entrata_entrata.company_users cu_api
    ON cu_api.cid = h.cid
   AND cu_api.id = h.created_by
   AND cu_api.company_user_type_id = 16
   AND cu_api.id NOT IN (21, 48, 67, 77)
LEFT JOIN entrata_entrata.company_users cu_app
    ON cu_app.cid = h.cid
   AND cu_app.id = h.created_by
   AND cu_app.company_user_type_id = 9
)

SELECT
    invoice_id,
    header_number,
    client_id,
    property_id,
    creation_date,
    creation_month,
    invoice_type,
    invoice_status,
    source_channel,
    CASE
        WHEN source_channel IN (
            'Vendor Portal', 'UEM',
            'Invoice Processing (Manual Entry/Upload)',
            'ELI Invoice Entry', 'Recurring Transaction'
        ) THEN 'Automated'
        WHEN source_channel IN ('Invoice Import', 'API')
            THEN 'Import'
        WHEN source_channel IN (
            'Add Invoice (Manual)', 'Invoice Template',
            'Bulk Invoice Entry', 'Old Bulk Invoice Entry',
            'Purchase Orders: Create Invoice', 'App User'
        ) THEN 'Manual'
        ELSE 'Manual'
    END                                                             AS entry_method_group,
    invoice_total_amount,
    has_attachment,
    days_to_posted,
    days_to_approved,
    is_touchless,
    is_first_time_right,
    rejection_count,
    rejection_reason,
    rejection_category,
    routing_assigned_timestamp,
    system_processing_hours,
    approver_wait_hours,
    client_release_track,
    client_segment,
    client_total_units
FROM invoice_facts
ORDER BY invoice_id DESC;
