-- Incore Residential (New) (cid=16706) — PO rejection deep-dive
-- Powers data/local/cs-incore-deep-dive.json and knowledge/csm-quick-wins/incore-residential/
--
-- Run 2026-07-06. Findings summarized in:
--   client-wins-incore-2026-07-06.md   (CSM-facing)
--   product-ops-wins-incore-2026-07-06.md (PM/product-facing)
--
-- Fifth client-level deep-dive. Coaching-heavy per classifier v2, but the interesting
-- finding is a NEW rejection sub-pattern: CBR (Chargeback Recovery) — 96 events / 6.2%
-- of all rejections. Currently uncategorized by the v2 classifier. Recommend extending
-- to v3.
--
-- Also flags a client-health concern: PO volume down 52% year-over-year. Not a product
-- problem per se, but a canary the CSM should investigate before we frame anything as
-- a retention-value story.
--
-- HAVING thresholds: vendors >= 20 (mid-scale), properties >= 30 (mid-scale).

-- ============================================================================
-- 1) Top rejection notes for Incore (first rejection per PO, last 12mo)
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 16706
      AND h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= CURRENT_DATE - INTERVAL '12 months'
),
rej AS (
    SELECT ahl.cid, ahl.ap_header_id,
        LOWER(TRIM(ahl.approval_note)) AS note,
        ROW_NUMBER() OVER (PARTITION BY ahl.cid, ahl.ap_header_id ORDER BY ahl.log_datetime ASC) AS rn
    FROM entrata_entrata.ap_header_logs ahl
    INNER JOIN po_scope ps ON ps.cid = ahl.cid AND ps.ap_header_id = ahl.ap_header_id
    WHERE ahl.ap_header_type_id = 4
      AND ahl.log_datetime >= CURRENT_DATE - INTERVAL '13 months'
      AND ahl.action IN ('Rejected', 'Returned To Previous', 'Returned To Beginning')
)
SELECT COALESCE(NULLIF(note, ''), '(empty)') AS note, COUNT(*) AS occurrences
FROM rej
WHERE rn = 1
GROUP BY note
ORDER BY occurrences DESC
LIMIT 30;

-- ============================================================================
-- 2) Incore monthly rejection trend (13 months) — reveals 52% volume drop + April 2026 rate spike
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid, TO_CHAR(h.created_on, 'YYYY-MM') AS ym
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 16706
      AND h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '13 months')
),
po_rej AS (
    SELECT ahl.cid, ahl.ap_header_id,
        SUM(CASE WHEN ahl.action IN ('Rejected','Returned To Previous','Returned To Beginning') THEN 1 ELSE 0 END) AS rej
    FROM entrata_entrata.ap_header_logs ahl
    WHERE ahl.cid = 16706
      AND ahl.ap_header_type_id = 4
      AND ahl.log_datetime >= CURRENT_DATE - INTERVAL '14 months'
    GROUP BY ahl.cid, ahl.ap_header_id
)
SELECT ps.ym,
    COUNT(*) AS pos,
    SUM(CASE WHEN COALESCE(pr.rej, 0) > 0 THEN 1 ELSE 0 END) AS rejected
FROM po_scope ps
LEFT JOIN po_rej pr ON pr.cid = ps.cid AND pr.ap_header_id = ps.ap_header_id
GROUP BY ps.ym
ORDER BY ps.ym;

-- ============================================================================
-- 3) Top rejecters (users) — VP does 46% of rejections
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 16706
      AND h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= CURRENT_DATE - INTERVAL '12 months'
)
SELECT ahl.updated_by AS rejecter_user_id,
    COUNT(*) AS reject_events,
    COUNT(DISTINCT ahl.ap_header_id) AS distinct_pos_rejected
FROM entrata_entrata.ap_header_logs ahl
INNER JOIN po_scope ps ON ps.cid = ahl.cid AND ps.ap_header_id = ahl.ap_header_id
WHERE ahl.ap_header_type_id = 4
  AND ahl.log_datetime >= CURRENT_DATE - INTERVAL '13 months'
  AND ahl.action IN ('Rejected', 'Returned To Previous', 'Returned To Beginning')
GROUP BY ahl.updated_by
ORDER BY reject_events DESC
LIMIT 20;

-- Resolve user titles:
-- SELECT cu.id, ce.title, cu.last_login FROM entrata_entrata.company_users cu
-- LEFT JOIN entrata_entrata.company_employees ce ON ce.cid = cu.cid AND ce.id = cu.company_employee_id
-- WHERE cu.cid = 16706 AND cu.id IN (<user_ids>);

-- ============================================================================
-- 4) Top rejected vendors (min 20 rejections)
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid, h.ap_payee_id
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 16706
      AND h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= CURRENT_DATE - INTERVAL '12 months'
),
po_rej AS (
    SELECT ahl.cid, ahl.ap_header_id,
        SUM(CASE WHEN ahl.action IN ('Rejected','Returned To Previous','Returned To Beginning') THEN 1 ELSE 0 END) AS rej
    FROM entrata_entrata.ap_header_logs ahl
    WHERE ahl.cid = 16706
      AND ahl.ap_header_type_id = 4
      AND ahl.log_datetime >= CURRENT_DATE - INTERVAL '13 months'
    GROUP BY ahl.cid, ahl.ap_header_id
)
SELECT ps.ap_payee_id AS vendor_id,
    COUNT(*) AS pos_created,
    SUM(CASE WHEN COALESCE(pr.rej, 0) > 0 THEN 1 ELSE 0 END) AS pos_rejected,
    ROUND(100.0 * SUM(CASE WHEN COALESCE(pr.rej, 0) > 0 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS rejection_rate_pct
FROM po_scope ps
LEFT JOIN po_rej pr ON pr.cid = ps.cid AND pr.ap_header_id = ps.ap_header_id
GROUP BY ps.ap_payee_id
HAVING SUM(CASE WHEN COALESCE(pr.rej, 0) > 0 THEN 1 ELSE 0 END) >= 20
ORDER BY pos_rejected DESC
LIMIT 25;

-- Resolve vendor names:
-- SELECT id, company_name FROM entrata_entrata.ap_payees WHERE cid = 16706 AND id IN (<vendor_ids>);

-- ============================================================================
-- 5) Rejection by property (min 30 POs) — reveals dramatic high/low cluster split
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 16706
      AND h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= CURRENT_DATE - INTERVAL '12 months'
),
po_prop AS (
    SELECT ad.cid, ad.ap_header_id, MIN(ad.property_id) AS property_id
    FROM entrata_entrata.ap_details ad
    INNER JOIN po_scope ps ON ps.cid = ad.cid AND ps.ap_header_id = ad.ap_header_id
    GROUP BY ad.cid, ad.ap_header_id
),
po_rej AS (
    SELECT ahl.cid, ahl.ap_header_id,
        SUM(CASE WHEN ahl.action IN ('Rejected','Returned To Previous','Returned To Beginning') THEN 1 ELSE 0 END) AS rej
    FROM entrata_entrata.ap_header_logs ahl
    WHERE ahl.cid = 16706
      AND ahl.ap_header_type_id = 4
      AND ahl.log_datetime >= CURRENT_DATE - INTERVAL '13 months'
    GROUP BY ahl.cid, ahl.ap_header_id
)
SELECT COALESCE(pp.property_id, -1) AS property_id,
    COUNT(*) AS pos_created,
    SUM(CASE WHEN COALESCE(pr.rej, 0) > 0 THEN 1 ELSE 0 END) AS pos_rejected,
    ROUND(100.0 * SUM(CASE WHEN COALESCE(pr.rej, 0) > 0 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS rejection_rate_pct
FROM po_scope ps
LEFT JOIN po_prop pp ON pp.cid = ps.cid AND pp.ap_header_id = ps.ap_header_id
LEFT JOIN po_rej pr ON pr.cid = ps.cid AND pr.ap_header_id = ps.ap_header_id
GROUP BY pp.property_id
HAVING COUNT(*) >= 30
ORDER BY pos_rejected DESC
LIMIT 25;

-- Resolve property names:
-- SELECT id, property_name FROM entrata_entrata.properties WHERE cid = 16706 AND id IN (<property_ids>);
