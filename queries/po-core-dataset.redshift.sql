/* =====================================================================================
   DATASET 1 — PO CORE DATASET (Domo) — PRODUCTION
   One row per PO. Live Rapid + Standard clients only.
   Test / demo / sandbox / template clients and test properties excluded.

   PM FLAGS:
   - source_category: 
        It is not possible to track following sources for now as we are not maintaining any field or log for this. 
        Vendor Profile (System UI)
        Dashboard (System UI)
        Duplicate / Use Previous
        PO Template (manual loading template)
   - reroute_count: It is not possible to get reroute_count i.e. how many time PO is rerouted and is_rerouted field. (no dedicated reassignment log event).
   - is_first_time_right: We can not consider reroute here because there is no way to check if PO is rerouted 
   - system_routing_hours: This will be mostly 0 because we have almost same time when PO created and time when approval routing is assigned                  
   - property_id: In case of multiproperty PO, property id for the first line item will be displayed
   - Rejection includes 'Returned To Previous' / 'Returned To Beginning'.
   - TO check for perticular client use condition AND c.id = {client_id} in live_clients CTE
   ===================================================================================== */

WITH
live_clients AS (
    -- NOTE (Redshift adaptation): c.details JSONB is NOT mirrored to Redshift,
    -- so the Rapid/Standard cluster_id split is unavailable here. We keep the
    -- live-client filter (company_status_type_id = 4) and set release_track
    -- to NULL until DBRE surfaces cluster_id (or a client_release_tracks table).
    SELECT
        c.id AS cid,
        CAST(NULL AS VARCHAR) AS release_track
    FROM entrata_entrata.clients c
    WHERE c.company_status_type_id = 4
),

-- 2) Base PO set: every downstream CTE references this (live clients only) ------------
live_pos AS (
    SELECT h.*
    FROM entrata_entrata.ap_headers h
    INNER JOIN live_clients lc ON lc.cid = h.cid
    WHERE h.ap_header_type_id     = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template  = false
),

-- 3) Managed units per live client -> client_segment ---------------------------------
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

-- 4) Property IDs from line items (multi-property POs); excludes test properties ------
po_properties AS (
    -- Redshift adaptation: ARRAY_AGG(... ORDER BY ...) with [1] indexing is
    -- not supported. Use ROW_NUMBER() over the qualifying line items instead.
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
        INNER JOIN live_pos lp
            ON lp.cid = ad.cid AND lp.id = ad.ap_header_id
        JOIN entrata_entrata.properties p
            ON p.cid = ad.cid AND p.id = ad.property_id
           AND p.is_test = 0
           AND p.is_disabled = 0
           AND p.termination_date IS NULL
        WHERE ad.deleted_on IS NULL
    ) WHERE rn = 1
),

-- 5) Work Order detection (line-level signal) ----------------------------------------
po_work_order AS (
    SELECT DISTINCT
        ad.cid,
        ad.ap_header_id,
        mrm.maintenance_request_id AS work_order_id
    FROM entrata_entrata.ap_details ad
    INNER JOIN live_pos lp
        ON lp.cid = ad.cid AND lp.id = ad.ap_header_id
    INNER JOIN entrata_entrata.maintenance_request_materials mrm
        ON mrm.cid = ad.cid
       AND mrm.ap_detail_id = ad.id
       AND mrm.deleted_by IS NULL
    INNER JOIN entrata_entrata.maintenance_requests mr
        ON mr.cid = mrm.cid
       AND mr.id = mrm.maintenance_request_id
       AND mr.parent_maintenance_request_id IS NULL
    WHERE ad.deleted_on IS NULL
),

-- 6) Attachment presence -------------------------------------------------------------
po_attachments AS (
    SELECT
        fa.cid,
        fa.ap_header_id,
        COUNT(*) AS attachment_count
    FROM entrata_entrata.file_associations fa
    INNER JOIN live_pos lp
        ON lp.cid = fa.cid AND lp.id = fa.ap_header_id
    WHERE fa.ap_header_id IS NOT NULL
      AND fa.deleted_on IS NULL
    GROUP BY fa.cid, fa.ap_header_id
),

-- 7) Rejection = approver sends back to submitter (includes returns) ------------------
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
    INNER JOIN live_pos lp
        ON lp.cid = ahl.cid AND lp.id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 4
    GROUP BY ahl.cid, ahl.ap_header_id
),

-- CSV/file import detection via history log (is_initial_import is NOT set on PO CSV import)
po_imported AS (
    SELECT DISTINCT
        ahl.cid,
        ahl.ap_header_id
    FROM entrata_entrata.ap_header_logs ahl
    INNER JOIN live_pos lp
        ON lp.cid = ahl.cid AND lp.id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 4
      AND ahl.action = 'Imported'          -- CApHeaderLog::ACTION_IMPORTED
),

-- 7b) FIRST rejection reason (root cause) --------------------------------------------
first_rejection AS (
    -- Redshift adaptation: DISTINCT ON is not supported; use ROW_NUMBER() window.
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
        INNER JOIN live_pos lp
            ON lp.cid = ahl.cid AND lp.id = ahl.ap_header_id
        WHERE ahl.ap_header_type_id = 4
          AND ahl.action IN ('Rejected', 'Returned To Previous', 'Returned To Beginning')
    ) WHERE rn = 1
),

-- 8) Routing events: header (type 1) + line item (type 2) ----------------------------
-- Redshift adaptation: entrata_entrata.rule_stop_results is NOT mirrored to
-- Redshift, so we cannot compute system_routing_hours / approver_wait_hours
-- from routing events. We emit an empty CTE with the same shape so downstream
-- joins produce NULL for routing_assigned_timestamp — that maps to the
-- "routing OFF: no system delay" branch in Pallavi's original CASE.
-- Restore the real routing CTEs once DBRE mirrors rule_stop_results.
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
)


-- ====================================================================================
SELECT
    h.id                                                            AS po_id,
    h.cid                                                           AS client_id,
    h.header_number,

    -- Property: single vs multi-property ---------------------------------------------
    COALESCE(h.bulk_property_id, pp.first_property_id) AS property_id,

    h.created_on::date                                             AS creation_date,
    TO_CHAR(h.created_on, 'YYYY-MM')                                AS creation_month,

    CASE h.ap_header_sub_type_id
        WHEN 4  THEN 'Standard'
        WHEN 11 THEN 'Catalog'
        WHEN 19 THEN 'Job Costing'
        WHEN 20 THEN 'Job Costing'
        ELSE 'Other'
    END                                                             AS po_type,

     CASE
        WHEN h.is_deleted = true OR h.ap_financial_status_type_id = 8 OR h.deleted_on IS NOT NULL THEN 'Deleted'
        WHEN h.ap_financial_status_type_id = 6                        THEN 'Rejected'
        WHEN h.ap_financial_status_type_id = 5                        THEN 'Cancelled'
        WHEN h.is_posted = true                                       THEN 'Posted'
        WHEN h.ap_financial_status_type_id = 4                        THEN 'Closed'
        WHEN h.ap_financial_status_type_id = 3                        THEN 'Partially Invoiced'
        WHEN h.ap_financial_status_type_id = 2                        THEN 'Approved'
        WHEN h.ap_financial_status_type_id = 1                        THEN 'Pending'
        ELSE 'Other'
    END                                                               AS po_status,

    -- source_category ----------------------------------------------------------------
    CASE
        WHEN imp.ap_header_id IS NOT NULL
            THEN 'PO/CSV Import'                              -- via 'Imported' history log
        WHEN h.is_initial_import = true
            THEN 'PO/CSV Import'                              -- migration/historical import (kept as fallback)
        WHEN h.source = 1
            THEN 'Vendor Marketplace'
        WHEN h.source = 2
            THEN 'Punchout'
        WHEN h.scheduled_ap_header_id IS NOT NULL
            THEN 'Recurring Transaction'
        WHEN h.template_ap_header_id IS NOT NULL
            THEN 'Recurring Transaction'      -- recurring template path
        WHEN wo.ap_header_id IS NOT NULL
            THEN 'Work Order > Add PO (System UI)'
        WHEN cu_api.id IS NOT NULL
            THEN 'API'
        ELSE 'Add PO (System UI)'
    END                                                             AS source_category,

    h.transaction_amount                                           AS po_total_amount,
    CASE WHEN pa.ap_header_id IS NOT NULL THEN 1 ELSE 0 END        AS has_attachment,

    -- Velocity (days) ----------------------------------------------------------------
    CASE WHEN h.approved_on IS NOT NULL
        THEN ROUND(EXTRACT(EPOCH FROM (h.approved_on - h.created_on)) / 86400.0, 2)
    END                                                             AS days_to_approve,

    CASE WHEN h.ap_financial_status_type_id = 1
              AND h.is_posted = false AND h.deleted_on IS NULL
        THEN ROUND(EXTRACT(EPOCH FROM (NOW() - h.created_on)) / 86400.0, 2)
    END                                                             AS status_age_days,

   CASE
        WHEN h.approved_on IS NULL THEN NULL                                      -- not yet determinable
        WHEN h.approved_on IS NOT NULL AND COALESCE(la.edit_count, 0) = 0 THEN 1  -- approved, never edited
        ELSE 0                                                                    -- approved but manually touched
    END                                                             AS is_touchless,

    -- Time decomposition (hours) -----------------------------------------------------
    r.routing_assigned_timestamp,

    CASE
        WHEN r.routing_assigned_timestamp IS NOT NULL
            THEN ROUND(EXTRACT(EPOCH FROM (r.routing_assigned_timestamp - h.created_on)) / 3600.0, 2)
        WHEN h.approved_on IS NOT NULL
            THEN 0                                                  -- routing OFF: no system delay
    END                                                             AS system_routing_hours,

    CASE
        WHEN h.approved_on IS NOT NULL AND r.routing_assigned_timestamp IS NOT NULL
            THEN ROUND(EXTRACT(EPOCH FROM (h.approved_on - r.routing_assigned_timestamp)) / 3600.0, 2)
        WHEN h.approved_on IS NOT NULL AND r.routing_assigned_timestamp IS NULL
            THEN ROUND(EXTRACT(EPOCH FROM (h.approved_on - h.created_on)) / 3600.0, 2)
    END                                                             AS approver_wait_hours,

    -- Rejection ----------------------------------------------------------------------
    COALESCE(la.rejection_count, 0)                                AS rejection_count,
    fr.first_rejection_reason                                      AS rejection_reason,
    CASE
        WHEN fr.first_rejection_reason IS NULL THEN NULL
        WHEN fr.first_rejection_reason ILIKE '%wrong approver%'
          OR fr.first_rejection_reason ILIKE '%reassign%'
            THEN 'ROUTING_ERROR'
        WHEN fr.first_rejection_reason ILIKE '%amount%'
          OR fr.first_rejection_reason ILIKE '%GL%'
          OR fr.first_rejection_reason ILIKE '%coding%'
          OR fr.first_rejection_reason ILIKE '%vendor%'
            THEN 'DATA_CORRECTION'
        WHEN fr.first_rejection_reason ILIKE '%duplicate%'
          OR fr.first_rejection_reason ILIKE '%over budget%'
          OR fr.first_rejection_reason ILIKE '%unauthorized%'
          OR fr.first_rejection_reason ILIKE '%cancelled%'
          OR fr.first_rejection_reason ILIKE '%declined%'
            THEN 'BUSINESS_REJECTION'
        ELSE 'OTHER'
    END                                                             AS rejection_category,

    CASE
        WHEN h.approved_on IS NULL
         AND COALESCE(la.rejection_count, 0) = 0
            THEN NULL                                                             -- pending, no failure yet → unknown
        WHEN h.approved_on IS NOT NULL
         AND COALESCE(la.rejection_count, 0) = 0
            THEN 1                                                                -- approved, clean path
        ELSE 0                                                                    -- failed (rejected/rerouted), incl. pending-but-failed
    END                                                            AS is_first_time_right,

    -- Client segmentation ------------------------------------------------------------
    lc.release_track                                               AS client_release_track,
    CASE
        WHEN cu_units.total_units >= 500      THEN 'Enterprise'
        WHEN cu_units.total_units >= 100      THEN 'Mid-Market'
        WHEN cu_units.total_units IS NOT NULL THEN 'Small'
        ELSE 'Unknown'
    END                                                             AS client_segment,
    cu_units.total_units                                           AS client_total_units

FROM live_pos h
INNER JOIN live_clients lc
    ON lc.cid = h.cid
LEFT JOIN client_units cu_units
    ON cu_units.cid = h.cid
LEFT JOIN po_properties pp
    ON pp.cid = h.cid AND pp.ap_header_id = h.id
LEFT JOIN po_work_order wo
    ON wo.cid = h.cid AND wo.ap_header_id = h.id
LEFT JOIN entrata_entrata.company_users cu_api
    ON cu_api.cid = h.cid
   AND cu_api.id = h.created_by
   AND cu_api.company_user_type_id = 16          -- CCompanyUserType::API_USER
LEFT JOIN po_attachments pa
    ON pa.cid = h.cid AND pa.ap_header_id = h.id
LEFT JOIN log_agg la
    ON la.cid = h.cid AND la.ap_header_id = h.id
LEFT JOIN first_rejection fr
    ON fr.cid = h.cid AND fr.ap_header_id = h.id
LEFT JOIN routing r
    ON r.cid = h.cid AND r.ap_header_id = h.id
LEFT JOIN po_imported imp
    ON imp.cid = h.cid AND imp.ap_header_id = h.id