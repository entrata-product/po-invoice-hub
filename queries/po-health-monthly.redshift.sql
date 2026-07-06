-- PO monthly health trend
-- Powers the Health tab's "PO Health Trend" line chart.
-- Metrics: approval rate, touchless rate (approved with zero edits), FTR (approved with zero rejections), rejection rate.
-- Scope: 13 months of created POs; log window is 14 months to capture straddling events.
--
-- Findings (2026-07-06 run):
--   - Approval / FTR / touchless rates are remarkably stable: 95-96% approval, 94-95% FTR, 80-81% touchless.
--   - 2026-01 dip: rejection rate briefly hit 3.8% (from ~2.8% baseline); FTR dropped to 92.9%.
--   - Recent (2026-06): 158k POs, largest single month in the window.

WITH live_clients AS (
    SELECT id AS cid FROM entrata_entrata.clients WHERE company_status_type_id = 4
),
po_scope AS (
    SELECT h.id AS ap_header_id, h.cid, h.approved_on, TO_CHAR(h.created_on, 'YYYY-MM') AS ym
    FROM entrata_entrata.ap_headers h
    INNER JOIN live_clients lc ON lc.cid = h.cid
    WHERE h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '13 months')
),
po_logs AS (
    SELECT
        ahl.cid, ahl.ap_header_id,
        SUM(CASE WHEN ahl.action IN ('Rejected','Returned To Previous','Returned To Beginning') THEN 1 ELSE 0 END) AS rej,
        SUM(CASE WHEN ahl.action = 'Edited' THEN 1 ELSE 0 END) AS edits
    FROM entrata_entrata.ap_header_logs ahl
    WHERE ahl.ap_header_type_id = 4
      AND ahl.log_datetime >= CURRENT_DATE - INTERVAL '14 months'
    GROUP BY ahl.cid, ahl.ap_header_id
),
joined AS (
    SELECT ps.ym, ps.approved_on, COALESCE(pl.rej, 0) AS rej, COALESCE(pl.edits, 0) AS edits
    FROM po_scope ps
    LEFT JOIN po_logs pl ON pl.cid = ps.cid AND pl.ap_header_id = ps.ap_header_id
)
SELECT
    ym,
    COUNT(*) AS po_count,
    SUM(CASE WHEN approved_on IS NOT NULL THEN 1 ELSE 0 END) AS approved,
    SUM(CASE WHEN approved_on IS NOT NULL AND edits = 0 THEN 1 ELSE 0 END) AS touchless,
    SUM(CASE WHEN approved_on IS NOT NULL AND rej = 0 THEN 1 ELSE 0 END) AS ftr,
    SUM(CASE WHEN rej > 0 THEN 1 ELSE 0 END) AS with_rejection
FROM joined
GROUP BY ym
ORDER BY ym;
