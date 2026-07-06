-- Independence Realty Trust (cid=17541) — PO rejection deep-dive
-- Powers data/local/cs-irt-deep-dive.json and knowledge/csm-quick-wins/irt/
--
-- Run 2026-07-06. Findings summarized in the two markdown artifacts:
--   client-wins-irt-2026-07-06.md   (CSM-facing)
--   product-ops-wins-irt-2026-07-06.md   (PM/product-facing)
--
-- Third client after EPC and RL. Surfaces two NEW pattern categories not present at the first two:
--   1. Budget-guardrail rejections (Advanced Budgeting integration story)
--   2. Turn/timing workflow rejections (make-ready + notice + move-out dates)
--
-- Approval organization is multi-tier geographic: 8 Regional Managers do 51% of rejections.
-- HD Supply alone is 12,141 POs at IRT (11% of ALL IRT POs).
--
-- Query 5 has HAVING COUNT(*) >= 200 (vs. 50 at EPC/RL) because IRT has 100+ properties and
-- would otherwise return an enormous result set.

-- ============================================================================
-- 1) Top rejection notes for IRT (first rejection per PO, last 12mo)
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 17541
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
-- 2) IRT monthly rejection trend (13 months)
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid, TO_CHAR(h.created_on, 'YYYY-MM') AS ym
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 17541
      AND h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '13 months')
),
po_rej AS (
    SELECT ahl.cid, ahl.ap_header_id,
        SUM(CASE WHEN ahl.action IN ('Rejected','Returned To Previous','Returned To Beginning') THEN 1 ELSE 0 END) AS rej
    FROM entrata_entrata.ap_header_logs ahl
    WHERE ahl.cid = 17541
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
-- 3) Top rejecters (users) at IRT
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 17541
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

-- Resolve user titles (names NOT mirrored to Redshift):
-- SELECT cu.id, ce.title, cu.last_login FROM entrata_entrata.company_users cu
-- LEFT JOIN entrata_entrata.company_employees ce ON ce.cid = cu.cid AND ce.id = cu.company_employee_id
-- WHERE cu.cid = 17541 AND cu.id IN (<user_ids>);

-- ============================================================================
-- 4) Top rejected vendors at IRT (min 50 rejections)
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid, h.ap_payee_id
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 17541
      AND h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= CURRENT_DATE - INTERVAL '12 months'
),
po_rej AS (
    SELECT ahl.cid, ahl.ap_header_id,
        SUM(CASE WHEN ahl.action IN ('Rejected','Returned To Previous','Returned To Beginning') THEN 1 ELSE 0 END) AS rej
    FROM entrata_entrata.ap_header_logs ahl
    WHERE ahl.cid = 17541
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
HAVING SUM(CASE WHEN COALESCE(pr.rej, 0) > 0 THEN 1 ELSE 0 END) >= 50
ORDER BY pos_rejected DESC
LIMIT 25;

-- Resolve vendor names:
-- SELECT id, company_name FROM entrata_entrata.ap_payees WHERE cid = 17541 AND id IN (<vendor_ids>);

-- ============================================================================
-- 5) IRT rejection by property (via ap_details.property_id — HAVING >= 200 for IRT)
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 17541
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
    WHERE ahl.cid = 17541
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
HAVING COUNT(*) >= 200
ORDER BY pos_rejected DESC
LIMIT 30;

-- Resolve property names:
-- SELECT id, property_name FROM entrata_entrata.properties WHERE cid = 17541 AND id IN (<property_ids>);
