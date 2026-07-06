-- PO rejection reasons — categorized + top literal notes
-- Two queries used together:
--   1) Category rollup (Pallavi's ILIKE buckets)
--   2) Top literal notes (dominant free-text reasons)
-- Scope: first rejection event per PO, ap_header_type_id=4, headers created last 12 months.
-- Log window is 13 months so we capture events on POs created just before the 12-month window.
--
-- Findings (2026-07-06 run):
--   - Total classified: 48,259 first-rejection events across 12 months.
--   - 80.8% land in OTHER because ILIKE keywords don't match real free-text.
--   - Real top buckets (from top-20 literal notes): Duplicate PO (~2,035), No context (~913),
--     PO cancelled/not needed (~571), Missing supporting docs (~527), Missing property/unit (~416),
--     GL coding error (~328), Property changed hands (~219), Migration artifact (~114).

-- 1) Category rollup
WITH live_clients AS (
    SELECT id AS cid FROM entrata_entrata.clients WHERE company_status_type_id = 4
),
po_scope AS (
    SELECT h.id AS ap_header_id, h.cid
    FROM entrata_entrata.ap_headers h
    INNER JOIN live_clients lc ON lc.cid = h.cid
    WHERE h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= CURRENT_DATE - INTERVAL '12 months'
),
rejection_logs AS (
    SELECT ahl.cid, ahl.ap_header_id, ahl.approval_note, ahl.log_datetime,
        ROW_NUMBER() OVER (PARTITION BY ahl.cid, ahl.ap_header_id ORDER BY ahl.log_datetime ASC) AS rn
    FROM entrata_entrata.ap_header_logs ahl
    INNER JOIN po_scope ps ON ps.cid = ahl.cid AND ps.ap_header_id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 4
      AND ahl.log_datetime >= CURRENT_DATE - INTERVAL '13 months'
      AND ahl.action IN ('Rejected', 'Returned To Previous', 'Returned To Beginning')
),
first_rej AS ( SELECT cid, ap_header_id, approval_note FROM rejection_logs WHERE rn = 1 ),
categorized AS (
    SELECT
        approval_note,
        CASE
            WHEN approval_note IS NULL OR TRIM(approval_note) = '' THEN 'NO_REASON_GIVEN'
            WHEN approval_note ILIKE '%wrong approver%' OR approval_note ILIKE '%reassign%' THEN 'ROUTING_ERROR'
            WHEN approval_note ILIKE '%amount%' OR approval_note ILIKE '%GL%' OR approval_note ILIKE '%coding%' OR approval_note ILIKE '%vendor%' THEN 'DATA_CORRECTION'
            WHEN approval_note ILIKE '%duplicate%' OR approval_note ILIKE '%over budget%' OR approval_note ILIKE '%unauthorized%' OR approval_note ILIKE '%cancelled%' OR approval_note ILIKE '%declined%' THEN 'BUSINESS_REJECTION'
            ELSE 'OTHER'
        END AS rejection_category
    FROM first_rej
)
SELECT rejection_category, COUNT(*) AS po_count
FROM categorized
GROUP BY rejection_category
ORDER BY po_count DESC;

-- 2) Top literal notes (last 12mo, min 100 occurrences)
WITH live_clients AS (
    SELECT id AS cid FROM entrata_entrata.clients WHERE company_status_type_id = 4
),
po_scope AS (
    SELECT h.id AS ap_header_id, h.cid
    FROM entrata_entrata.ap_headers h
    INNER JOIN live_clients lc ON lc.cid = h.cid
    WHERE h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= CURRENT_DATE - INTERVAL '12 months'
),
rejection_logs AS (
    SELECT ahl.cid, ahl.ap_header_id, LOWER(TRIM(ahl.approval_note)) AS note,
        ROW_NUMBER() OVER (PARTITION BY ahl.cid, ahl.ap_header_id ORDER BY ahl.log_datetime ASC) AS rn
    FROM entrata_entrata.ap_header_logs ahl
    INNER JOIN po_scope ps ON ps.cid = ahl.cid AND ps.ap_header_id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 4
      AND ahl.log_datetime >= CURRENT_DATE - INTERVAL '13 months'
      AND ahl.action IN ('Rejected', 'Returned To Previous', 'Returned To Beginning')
      AND ahl.approval_note IS NOT NULL
      AND TRIM(ahl.approval_note) != ''
)
SELECT note, COUNT(*) AS occurrences
FROM rejection_logs
WHERE rn = 1
GROUP BY note
HAVING COUNT(*) >= 100
ORDER BY occurrences DESC
LIMIT 30;
