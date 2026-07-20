/* =====================================================================================
   INVOICE MONTHLY KPIs (Redshift-adapted) — DASHBOARD-READY AGGREGATION
   Aggregates the per-invoice fact from invoice-core-dataset.redshift.sql
   to (creation_month × client_release_track × client_segment × source_channel
       × rejection_category) grain.

   SOURCE:   queries/invoice-core-dataset.redshift.sql (which is the Redshift-adapted
             port of Pallavi's Domo Dataset 1 attached to DEV-253879, 2026-07-20).
   PURPOSE:  Portfolio-wide, dashboard-ready aggregation that stays under a few
             thousand rows and is executable through the Redshift MCP in a
             single query. Powers Focus/Overview/Adoption/Health tiles.

   FIELDS RETURNED per group:
     - invoice_count               COUNT(*)
     - total_amount                SUM(invoice_total_amount)
     - attachment_count            SUM(has_attachment)
     - ftr_denom / ftr_count       SUM(is_first_time_right IS NOT NULL) / SUM(is_first_time_right = 1)
     - touchless_denom / _count    same shape for is_touchless
     - rejected_count              SUM(rejection_count > 0)
     - total_rejection_events      SUM(rejection_count)
     - avg_days_to_posted          AVG(days_to_posted)
     - median_days_to_posted       MEDIAN(days_to_posted)  -- Redshift-native
     - active_clients              COUNT(DISTINCT client_id)

   Client-side hydration in scripts/fetch_invoice_kpis.mjs (or .py) rolls this up
   into: (a) headline monthly trend, (b) source-channel mix, (c) rejection-category
   mix, (d) segment breakdown.

   INHERITED CAVEATS: see invoice-core-dataset.redshift.sql header (routing gap,
   no is_exception, no reroute count, dashboard-shortcut source unknown).

   MIRROR-GAP CAVEATS discovered 2026-07-20 when running against the Redshift
   mirror:
     - invoice_plus_file_processors is NOT mirrored to entrata_entrata.
     - invoice_plus_batches.ap_header_ids column is NOT present in the mirror.
   Neither ELI detection path (direct link or batch-array) works today. The
   invoice_plus_linked CTE is removed and source_channel buckets 'ELI Invoice
   Entry' + 'Bulk Invoice Entry' will never fire. Those invoices fall through
   to Add Invoice (Manual) / API / App User based on created_by. Restore once
   DBRE mirrors either signal.
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
    WHERE h.ap_header_type_id = 5
      AND h.ap_header_sub_type_id IN (5, 6, 7, 8, 12, 17, 18)
      AND COALESCE(h.is_template, false) = false
      /* Restrict to trailing 24 months so the aggregate doesn't scan the full
         history on every run. Widen or remove for full-history backfills. */
      AND h.created_on >= DATEADD(month, -24, CURRENT_DATE)
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

/* ELI (invoice_plus) detection: DISABLED against the Redshift mirror.
   Two mirror gaps discovered 2026-07-20:
     - invoice_plus_file_processors table is NOT mirrored to entrata_entrata.
     - invoice_plus_batches.ap_header_ids array column is NOT mirrored
       (only id, cid, property_id, is_ai_processed, batch metadata are present).
   Both signals are required to link a specific invoice to an ELI batch.
   Result: 'ELI Invoice Entry' and 'Bulk Invoice Entry' source_channel buckets
   never fire; those invoices fall through to Add Invoice (Manual) / API / App
   User branches based on created_by. Restore once DBRE mirrors the link table
   or the ap_header_ids array. */

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
            'Rejected', 'Returned To Previous', 'Returned To Beginning'
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
        h.id                                                        AS invoice_id,
        h.cid                                                       AS client_id,
        TO_CHAR(h.created_on, 'YYYY-MM')                            AS creation_month,
        lc.release_track                                            AS client_release_track,
        CASE
            WHEN cu_units.total_units >= 500      THEN 'Enterprise'
            WHEN cu_units.total_units >= 100      THEN 'Mid-Market'
            WHEN cu_units.total_units IS NOT NULL THEN 'Small'
            ELSE 'Unknown'
        END                                                         AS client_segment,

        CASE
            WHEN h.created_by = 21                                  THEN 'Vendor Portal'
            WHEN h.created_by = 48                                  THEN 'UEM'
            WHEN h.created_by IN (77, 67)                           THEN 'Invoice Processing (Manual Entry/Upload)'
            WHEN h.template_ap_header_id IS NOT NULL AND h.created_by = 16 THEN 'Recurring Transaction'
            WHEN h.template_ap_header_id IS NOT NULL                THEN 'Invoice Template'
            WHEN imp.ap_header_id IS NOT NULL OR COALESCE(h.is_initial_import, false) = true THEN 'Invoice Import'
            /* ELI Invoice Entry / Bulk Invoice Entry branches disabled — see
               header note above the CTEs. */
            WHEN h.ap_batch_id IS NOT NULL                          THEN 'Old Bulk Invoice Entry'
            WHEN cfp.ap_header_id IS NOT NULL                       THEN 'Purchase Orders: Create Invoice'
            WHEN cu_api.id IS NOT NULL                              THEN 'API'
            WHEN cu_app.id IS NOT NULL                              THEN 'App User'
            ELSE 'Add Invoice (Manual)'
        END                                                         AS source_channel,

        COALESCE(h.transaction_amount, 0)                           AS invoice_total_amount,

        CASE
            WHEN h.is_posted = false THEN NULL
            WHEN h.is_posted = true AND COALESCE(la.edit_count, 0) = 0 THEN 1
            ELSE 0
        END                                                         AS is_touchless,

        CASE
            WHEN COALESCE(la.rejection_count, 0) > 0 THEN 0
            WHEN h.is_posted = true THEN 1
            ELSE NULL
        END                                                         AS is_first_time_right,

        COALESCE(la.rejection_count, 0)                             AS rejection_count,

        CASE
            WHEN COALESCE(la.rejection_count, 0) = 0 THEN NULL
            WHEN fr.first_rejection_reason IS NULL THEN 'OTHER'
            WHEN fr.first_rejection_reason ILIKE '%wrong approver%'
              OR fr.first_rejection_reason ILIKE '%not my approval%'
              OR fr.first_rejection_reason ILIKE '%reroute%'
              OR fr.first_rejection_reason ILIKE '%reassign%'         THEN 'ROUTING_ERROR'
            WHEN fr.first_rejection_reason ILIKE '%amount%'
              OR fr.first_rejection_reason ILIKE '%GL%'
              OR fr.first_rejection_reason ILIKE '%coding%'
              OR fr.first_rejection_reason ILIKE '%vendor%'
              OR fr.first_rejection_reason ILIKE '%duplicate line%'
              OR fr.first_rejection_reason ILIKE '%wrong account%'
              OR fr.first_rejection_reason ILIKE '%fix%'
              OR fr.first_rejection_reason ILIKE '%correct%'           THEN 'DATA_CORRECTION'
            WHEN fr.first_rejection_reason ILIKE '%duplicate invoice%'
              OR fr.first_rejection_reason ILIKE '%not authorized%'
              OR fr.first_rejection_reason ILIKE '%unauthorized%'
              OR fr.first_rejection_reason ILIKE '%over budget%'
              OR fr.first_rejection_reason ILIKE '%disputed%'
              OR fr.first_rejection_reason ILIKE '%do not pay%'
              OR fr.first_rejection_reason ILIKE '%cancelled%'          THEN 'BUSINESS_REJECTION'
            ELSE 'OTHER'
        END                                                         AS rejection_category,

        CASE
            WHEN h.is_posted = true
             AND COALESCE(h.posted_on, pe.posted_timestamp) IS NOT NULL
                THEN ROUND(EXTRACT(EPOCH FROM (
                    COALESCE(h.posted_on, pe.posted_timestamp) - h.created_on
                )) / 86400.0, 2)
        END                                                         AS days_to_posted

    FROM live_invoices h
    INNER JOIN live_clients lc
        ON lc.cid = h.cid
    LEFT JOIN client_units cu_units
        ON cu_units.cid = h.cid
    LEFT JOIN invoice_imported imp
        ON imp.cid = h.cid AND imp.ap_header_id = h.id
    LEFT JOIN created_from_po cfp
        ON cfp.cid = h.cid AND cfp.ap_header_id = h.id
    LEFT JOIN log_agg la
        ON la.cid = h.cid AND la.ap_header_id = h.id
    LEFT JOIN first_rejection fr
        ON fr.cid = h.cid AND fr.ap_header_id = h.id
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
    creation_month,
    client_release_track,
    client_segment,
    source_channel,
    COALESCE(rejection_category, 'NONE')                        AS rejection_category,

    COUNT(*)                                                    AS invoice_count,
    SUM(invoice_total_amount)                                   AS total_amount,

    SUM(CASE WHEN is_first_time_right IS NOT NULL THEN 1 ELSE 0 END) AS ftr_denom,
    SUM(CASE WHEN is_first_time_right = 1 THEN 1 ELSE 0 END)    AS ftr_count,

    SUM(CASE WHEN is_touchless IS NOT NULL THEN 1 ELSE 0 END)   AS touchless_denom,
    SUM(CASE WHEN is_touchless = 1 THEN 1 ELSE 0 END)           AS touchless_count,

    SUM(CASE WHEN rejection_count > 0 THEN 1 ELSE 0 END)        AS rejected_count,
    SUM(rejection_count)                                        AS total_rejection_events,

    /* Emit both AVG and the underlying SUM + non-null COUNT so that when
       results are chunked (e.g. 3-month slices to fit MCP timeout), the
       transformer can compute a correct weighted average across chunks. */
    AVG(days_to_posted)                                         AS avg_days_to_posted,
    SUM(days_to_posted)                                         AS days_to_posted_sum,
    SUM(CASE WHEN days_to_posted IS NOT NULL THEN 1 ELSE 0 END) AS days_to_posted_denom,
    /* MEDIAN(days_to_posted) removed: Redshift disallows LISTAGG/PERCENTILE_CONT/
       MEDIAN aggregates in the same SELECT as COUNT(DISTINCT ...). Compute
       portfolio median with a separate query if needed. */

    COUNT(DISTINCT client_id)                                   AS active_clients

FROM invoice_facts
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1 DESC, 3, 4, 5;
