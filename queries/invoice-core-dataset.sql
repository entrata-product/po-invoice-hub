/* =====================================================================================
   DATASET 1 — INVOICE CORE DATASET (Domo) — PRODUCTION
   One row per Invoice. Live Rapid + Standard clients only.
   Test / demo / template clients and test properties excluded.

   SOURCE:   Attachment on Jira DEV-253879 (Pallavi Nawale, 2026-07-20).
             https://entrata.atlassian.net/browse/DEV-253879
             filename: dataset_1_invoice_core.sql

   DIALECT:  PostgreSQL / Domo source (bare table names, `->>` JSONB operator,
             FILTER (WHERE ...) aggregate syntax, CROSS JOIN LATERAL UNNEST).
             To run in the hub's Redshift MCP, this needs the same adaptations
             we did for po-core-dataset.redshift.sql:
               1. Prefix all tables with `entrata_entrata.` (or the equivalent
                  Redshift schema for the target cluster).
               2. Drop the `c.details->>'cluster_id'` split — Redshift doesn't
                  mirror the JSONB details column. Set release_track = NULL
                  and filter live clients by company_status_type_id = 4 only.
               3. Replace `COUNT(*) FILTER (WHERE ...)` with
                  `SUM(CASE WHEN ... THEN 1 ELSE 0 END)`.
               4. Replace `CROSS JOIN LATERAL UNNEST(...)` with the
                  Redshift-compatible variant (or PIVOT-friendly rewrite).
               5. Remove `AND c.id = 12742` single-client filter on live_clients.

   PALLAVI'S CAVEATS (from ticket comments, 2026-07-18 and 2026-07-20):
     - reroute_count / is_rerouted: NOT available. Reroute events cannot be
       correctly counted for multi-property invoices, so this column is dropped.
     - is_first_time_right: therefore defined as "posted AND rejection_count = 0"
       only (rejection here = Rejected / Returned To Previous / Returned To
       Beginning). It does NOT deduct for reroutes.
     - is_exception: NOT available. Validation errors aren't persisted.
     - Source-channel breakdown gaps: "Dashboard Shortcut" and
       "Duplicate / Use Previous" cannot be tracked (no field or log).
     - property_id: for multi-property invoices, this is the first line item's
       property, not a true multi-property indicator.
     - rejection_count includes: Rejected, Returned To Previous, Returned To
       Beginning (all three flavors of "sent back").
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
      AND c.id = 12742   -- REMOVE for production / single-client test only
),

live_invoices AS (
    SELECT h.*
    FROM ap_headers h
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
      AND COALESCE(h.is_template, false)  = false
),

client_units AS (
    SELECT
        p.cid,
        SUM(p.number_of_units) AS total_units
    FROM properties p
    INNER JOIN live_clients lc ON lc.cid = p.cid
    WHERE p.is_test = 0
      AND p.is_disabled = 0
      AND p.termination_date IS NULL
    GROUP BY p.cid
),

invoice_properties AS (
    SELECT
        ad.cid,
        ad.ap_header_id,
        (ARRAY_AGG(ad.property_id ORDER BY ad.id))[1] AS first_property_id
    FROM ap_details ad
    INNER JOIN live_invoices li
        ON li.cid = ad.cid AND li.id = ad.ap_header_id
    JOIN properties p
        ON p.cid = ad.cid AND p.id = ad.property_id
       AND p.is_test = 0
       AND p.is_disabled = 0
       AND p.termination_date IS NULL
    WHERE ad.deleted_on IS NULL
    GROUP BY ad.cid, ad.ap_header_id
),

invoice_attachments AS (
    SELECT
        fa.cid,
        fa.ap_header_id,
        COUNT(*) AS attachment_count
    FROM file_associations fa
    INNER JOIN live_invoices li
        ON li.cid = fa.cid AND li.id = fa.ap_header_id
    WHERE fa.ap_header_id IS NOT NULL
      AND fa.deleted_on IS NULL
    GROUP BY fa.cid, fa.ap_header_id
),

invoice_plus_linked AS (
    SELECT
        x.cid,
        x.ap_header_id,
        BOOL_OR(x.is_ai_processed) AS is_ai_processed
    FROM (
        SELECT
            ipfp.cid,
            ipfp.ap_header_id,
            COALESCE(ipb.is_ai_processed, false) AS is_ai_processed
        FROM invoice_plus_file_processors ipfp
        INNER JOIN live_invoices li
            ON li.cid = ipfp.cid AND li.id = ipfp.ap_header_id
        LEFT JOIN invoice_plus_batches ipb
            ON ipb.cid = ipfp.cid
           AND ipb.id = ipfp.invoice_plus_batch_id
        WHERE ipfp.ap_header_id IS NOT NULL

        UNION ALL

        SELECT
            ipb.cid,
            inv_id AS ap_header_id,
            COALESCE(ipb.is_ai_processed, false) AS is_ai_processed
        FROM invoice_plus_batches ipb
        INNER JOIN live_invoices li ON li.cid = ipb.cid
        CROSS JOIN LATERAL UNNEST(COALESCE(ipb.ap_header_ids, ARRAY[]::int[])) AS inv_id
        WHERE inv_id = li.id
    ) x
    GROUP BY x.cid, x.ap_header_id
),

invoice_imported AS (
    SELECT DISTINCT
        ahl.cid,
        ahl.ap_header_id
    FROM ap_header_logs ahl
    INNER JOIN live_invoices li
        ON li.cid = ahl.cid AND li.id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 5
      AND ahl.action = 'Imported'
),

created_from_po AS (
    SELECT DISTINCT
        ahl.cid,
        ahl.ap_header_id
    FROM ap_header_logs ahl
    INNER JOIN live_invoices li
        ON li.cid = ahl.cid AND li.id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 5
      AND ahl.action = 'Created'
      AND ahl.po_ap_header_ids IS NOT NULL
      AND cardinality(ARRAY_REMOVE(ahl.po_ap_header_ids, 0)) > 0
),

log_agg AS (
    SELECT
        ahl.cid,
        ahl.ap_header_id,
        COUNT(*) FILTER (WHERE ahl.action IN (
            'Rejected',
            'Returned To Previous',
            'Returned To Beginning'
        )) AS rejection_count,
        COUNT(*) FILTER (WHERE ahl.action = 'Edited') AS edit_count
    FROM ap_header_logs ahl
    INNER JOIN live_invoices li
        ON li.cid = ahl.cid AND li.id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 5
    GROUP BY ahl.cid, ahl.ap_header_id
),

first_rejection AS (
    SELECT DISTINCT ON (ahl.cid, ahl.ap_header_id)
        ahl.cid,
        ahl.ap_header_id,
        ahl.approval_note AS first_rejection_reason
    FROM ap_header_logs ahl
    INNER JOIN live_invoices li
        ON li.cid = ahl.cid AND li.id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 5
      AND ahl.action IN ('Rejected', 'Returned To Previous', 'Returned To Beginning')
    ORDER BY ahl.cid, ahl.ap_header_id, ahl.log_datetime ASC
),

routing_events AS (
    SELECT
        rsr.cid,
        rsr.reference_id AS ap_header_id,
        rsr.created_on
    FROM rule_stop_results rsr
    INNER JOIN live_invoices li
        ON li.cid = rsr.cid AND li.id = rsr.reference_id
    WHERE rsr.route_type_id = 3
     
    UNION ALL
    SELECT
        rsr.cid,
        ad.ap_header_id,
        rsr.created_on
    FROM rule_stop_results rsr
    JOIN ap_details ad
        ON ad.cid = rsr.cid
       AND ad.id = rsr.reference_id
       AND ad.deleted_on IS NULL
    INNER JOIN live_invoices li
        ON li.cid = ad.cid AND li.id = ad.ap_header_id
    WHERE rsr.route_type_id = 4     
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
    FROM ap_header_logs ahl
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
         COALESCE(h.posted_on, pe.posted_timestamp) as posted_timestamp,
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
        END AS invoice_status,

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
        END AS days_to_posted,

        CASE WHEN h.approved_on IS NOT NULL
            THEN ROUND(EXTRACT(EPOCH FROM (h.approved_on - h.created_on)) / 86400.0, 2)
        END                                                             AS days_to_approved,

        CASE
            WHEN h.is_posted = false THEN NULL
            WHEN h.is_posted = true
             AND COALESCE(la.edit_count, 0) = 0 THEN 1
            ELSE 0
        END AS is_touchless,

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

        CASE
            WHEN h.is_posted IS NOT TRUE
              OR COALESCE(h.posted_on, pe.posted_timestamp) IS NULL THEN NULL
            WHEN r.routing_assigned_timestamp IS NOT NULL
             AND h.approved_on IS NOT NULL
                THEN ROUND(
                    (EXTRACT(EPOCH FROM (r.routing_assigned_timestamp - h.created_on))
                   + EXTRACT(EPOCH FROM (
                        COALESCE(h.posted_on, pe.posted_timestamp) - h.approved_on
                     ))) / 3600.0
                , 2)
            WHEN r.routing_assigned_timestamp IS NULL
             AND h.approved_on IS NOT NULL
                THEN ROUND(
                    EXTRACT(EPOCH FROM (
                        COALESCE(h.posted_on, pe.posted_timestamp) - h.approved_on
                    )) / 3600.0
                , 2)
            ELSE NULL
        END AS system_processing_hours,

        CASE
            WHEN h.approved_on IS NOT NULL
             AND r.routing_assigned_timestamp IS NOT NULL
                THEN ROUND(
                    EXTRACT(EPOCH FROM (h.approved_on - r.routing_assigned_timestamp)) / 3600.0
                , 2)
            WHEN h.approved_on IS NOT NULL
             AND r.routing_assigned_timestamp IS NULL
                THEN ROUND(
                    EXTRACT(EPOCH FROM (h.approved_on - h.created_on)) / 3600.0
                , 2)
            ELSE NULL
        END                                                             AS approver_wait_hours,

        lc.release_track                                                AS client_release_track,
        CASE
            WHEN cu_units.total_units >= 500      THEN 'Enterprise'
            WHEN cu_units.total_units >= 100      THEN 'Mid-Market'
            WHEN cu_units.total_units IS NOT NULL THEN 'Small'
            ELSE 'Unknown'
        END                                                             AS client_segment,
        cu_units.total_units                                            AS client_total_units

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
    LEFT JOIN company_users cu_api
        ON cu_api.cid = h.cid
       AND cu_api.id = h.created_by
       AND cu_api.company_user_type_id = 16
       AND cu_api.id NOT IN (21, 48, 67, 77)
    LEFT JOIN company_users cu_app
        ON cu_app.cid = h.cid
       AND cu_app.id = h.created_by
       AND cu_app.company_user_type_id = 9    -- APP / OAuth
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
            'Add Invoice (Manual)',
            'Bulk Invoice Entry',
            'Old Bulk Invoice Entry'
        ) THEN 'Manual'
        WHEN source_channel IN (
            'Invoice Processing (Manual Entry/Upload)',
            'ELI Invoice Entry',
            'Recurring Transaction',
            'Vendor Portal'
        ) THEN 'Automated'
        WHEN source_channel IN (
            'Invoice Import',
            'API',
            'UEM'
        ) THEN 'Import'
        ELSE 'Other'
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