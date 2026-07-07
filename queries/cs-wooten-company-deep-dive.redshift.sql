-- The Wooten Company, LLC (cid=16991) — PO rejection deep-dive
-- Powers data/local/cs-wooten-company-deep-dive.json and knowledge/csm-quick-wins/wooten-company/
--
-- Run 2026-07-07. Seventh client-level deep-dive.
-- First single-signal photo-required client.
--
-- Why Wooten matters:
--   - RANK 2 in top-25 by rejection rate: 18.0% on 1,982 POs = 357 rejected POs / 398 rejection events
--     (second only to EPC at 45.5%; higher than IRT/Incore/Rockstar despite smaller volume)
--   - v4 classifier: photo_required 47 / duplicate 14 / coaching 5 / quote 5 / turn_timing 4 / other 281
--     47 of 76 classified = 62% photo-dominance (above 60% threshold)
--   - CLEANEST photo-required client in the portfolio — third data point for the photo epic
--     after Rockstar (broad doc-attachment) and IRT (multi-pattern)
--
-- HAVING thresholds: vendors >= 8 (small-scale), properties >= 15.

-- ============================================================================
-- 1) Top rejection notes (first rejection per PO, last 12mo)
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 16991
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
-- 2) Photo decode — full range of photo-related phrasing to validate v4 catches it
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 16991
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
SELECT note, COUNT(*) AS occurrences
FROM rej
WHERE rn = 1
  AND (note LIKE '%pic%'
    OR note LIKE '%photo%'
    OR note LIKE '%image%')
GROUP BY note
ORDER BY occurrences DESC
LIMIT 40;

-- ============================================================================
-- 3) Monthly rejection trend (13 months)
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid, TO_CHAR(h.created_on, 'YYYY-MM') AS ym
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 16991
      AND h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '13 months')
),
po_rej AS (
    SELECT ahl.cid, ahl.ap_header_id,
        SUM(CASE WHEN ahl.action IN ('Rejected','Returned To Previous','Returned To Beginning') THEN 1 ELSE 0 END) AS rej
    FROM entrata_entrata.ap_header_logs ahl
    WHERE ahl.cid = 16991
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
-- 4) Top rejecters (users) — who's demanding the photos?
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 16991
      AND h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= CURRENT_DATE - INTERVAL '12 months'
)
SELECT ahl.updated_by AS rejecter_user_id,
    COUNT(*) AS reject_events,
    COUNT(DISTINCT ahl.ap_header_id) AS distinct_pos_rejected,
    SUM(CASE WHEN LOWER(ahl.approval_note) LIKE '%pic%'
              OR LOWER(ahl.approval_note) LIKE '%photo%'
              OR LOWER(ahl.approval_note) LIKE '%image%'
              THEN 1 ELSE 0 END) AS photo_related_rejections
FROM entrata_entrata.ap_header_logs ahl
INNER JOIN po_scope ps ON ps.cid = ahl.cid AND ps.ap_header_id = ahl.ap_header_id
WHERE ahl.ap_header_type_id = 4
  AND ahl.log_datetime >= CURRENT_DATE - INTERVAL '13 months'
  AND ahl.action IN ('Rejected', 'Returned To Previous', 'Returned To Beginning')
GROUP BY ahl.updated_by
ORDER BY reject_events DESC
LIMIT 20;

-- ============================================================================
-- 5) Top rejected vendors (min 8 rejections) — are photo rejections vendor-clustered?
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid, h.ap_payee_id
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 16991
      AND h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= CURRENT_DATE - INTERVAL '12 months'
),
po_rej AS (
    SELECT ahl.cid, ahl.ap_header_id,
        SUM(CASE WHEN ahl.action IN ('Rejected','Returned To Previous','Returned To Beginning') THEN 1 ELSE 0 END) AS rej,
        SUM(CASE WHEN LOWER(ahl.approval_note) LIKE '%pic%'
                  OR LOWER(ahl.approval_note) LIKE '%photo%'
                  OR LOWER(ahl.approval_note) LIKE '%image%'
                  THEN 1 ELSE 0 END) AS photo_rej
    FROM entrata_entrata.ap_header_logs ahl
    WHERE ahl.cid = 16991
      AND ahl.ap_header_type_id = 4
      AND ahl.log_datetime >= CURRENT_DATE - INTERVAL '13 months'
    GROUP BY ahl.cid, ahl.ap_header_id
)
SELECT ps.ap_payee_id AS vendor_id,
    COUNT(*) AS pos_created,
    SUM(CASE WHEN COALESCE(pr.rej, 0) > 0 THEN 1 ELSE 0 END) AS pos_rejected,
    ROUND(100.0 * SUM(CASE WHEN COALESCE(pr.rej, 0) > 0 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS rejection_rate_pct,
    SUM(CASE WHEN COALESCE(pr.photo_rej, 0) > 0 THEN 1 ELSE 0 END) AS photo_rejected_pos
FROM po_scope ps
LEFT JOIN po_rej pr ON pr.cid = ps.cid AND pr.ap_header_id = ps.ap_header_id
GROUP BY ps.ap_payee_id
HAVING SUM(CASE WHEN COALESCE(pr.rej, 0) > 0 THEN 1 ELSE 0 END) >= 8
ORDER BY pos_rejected DESC
LIMIT 25;

-- ============================================================================
-- 6) Rejection by property (min 15 POs) — are photo rejections property-clustered?
-- ============================================================================
WITH po_scope AS (
    SELECT h.id AS ap_header_id, h.cid
    FROM entrata_entrata.ap_headers h
    WHERE h.cid = 16991
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
        SUM(CASE WHEN ahl.action IN ('Rejected','Returned To Previous','Returned To Beginning') THEN 1 ELSE 0 END) AS rej,
        SUM(CASE WHEN LOWER(ahl.approval_note) LIKE '%pic%'
                  OR LOWER(ahl.approval_note) LIKE '%photo%'
                  OR LOWER(ahl.approval_note) LIKE '%image%'
                  THEN 1 ELSE 0 END) AS photo_rej
    FROM entrata_entrata.ap_header_logs ahl
    WHERE ahl.cid = 16991
      AND ahl.ap_header_type_id = 4
      AND ahl.log_datetime >= CURRENT_DATE - INTERVAL '13 months'
    GROUP BY ahl.cid, ahl.ap_header_id
)
SELECT COALESCE(pp.property_id, -1) AS property_id,
    COUNT(*) AS pos_created,
    SUM(CASE WHEN COALESCE(pr.rej, 0) > 0 THEN 1 ELSE 0 END) AS pos_rejected,
    ROUND(100.0 * SUM(CASE WHEN COALESCE(pr.rej, 0) > 0 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS rejection_rate_pct,
    SUM(CASE WHEN COALESCE(pr.photo_rej, 0) > 0 THEN 1 ELSE 0 END) AS photo_rejected_pos
FROM po_scope ps
LEFT JOIN po_prop pp ON pp.cid = ps.cid AND pp.ap_header_id = ps.ap_header_id
LEFT JOIN po_rej pr ON pr.cid = ps.cid AND pr.ap_header_id = ps.ap_header_id
GROUP BY pp.property_id
HAVING COUNT(*) >= 15
ORDER BY pos_rejected DESC
LIMIT 25;

-- Resolve names (run separately after we have IDs):
-- SELECT id, company_name FROM entrata_entrata.ap_payees WHERE cid = 16991 AND id IN (<vendor_ids>);
-- SELECT id, property_name FROM entrata_entrata.properties WHERE cid = 16991 AND id IN (<property_ids>);
