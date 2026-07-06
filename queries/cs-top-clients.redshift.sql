-- CS Toolkit — top rejection concentration by client
-- Powers the "Client index" table on the CS Toolkit tab.
-- Scope: live clients (status=4) with 500+ POs in last 12mo, ordered by rejection_rate_pct DESC.
--
-- Findings (2026-07-06 run, top 25 shown on dashboard):
--   - EPC Real Estate Group: 45.5% rejection rate on 2,514 POs — massive outlier, 2.5x next client.
--   - IRT: only 8.4% rate but 112,892 POs → 9,502 rejected = largest absolute $ recovery.
--   - Median rejection rate across ranked list: ~7%.

WITH live_clients AS (
    SELECT id AS cid, company_name
    FROM entrata_entrata.clients
    WHERE company_status_type_id = 4
),
po_scope AS (
    SELECT h.id AS ap_header_id, h.cid, h.approved_on
    FROM entrata_entrata.ap_headers h
    INNER JOIN live_clients lc ON lc.cid = h.cid
    WHERE h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4, 11, 19, 20)
      AND h.is_template = false
      AND h.created_on >= CURRENT_DATE - INTERVAL '12 months'
),
po_logs AS (
    SELECT
        ahl.cid, ahl.ap_header_id,
        SUM(CASE WHEN ahl.action IN ('Rejected','Returned To Previous','Returned To Beginning') THEN 1 ELSE 0 END) AS rejection_count
    FROM entrata_entrata.ap_header_logs ahl
    WHERE ahl.ap_header_type_id = 4
      AND ahl.log_datetime >= CURRENT_DATE - INTERVAL '13 months'
    GROUP BY ahl.cid, ahl.ap_header_id
),
joined AS (
    SELECT ps.cid, ps.ap_header_id, COALESCE(pl.rejection_count, 0) AS rej
    FROM po_scope ps
    LEFT JOIN po_logs pl ON pl.cid = ps.cid AND pl.ap_header_id = ps.ap_header_id
),
client_agg AS (
    SELECT
        j.cid,
        COUNT(*) AS total_pos_12mo,
        SUM(CASE WHEN j.rej > 0 THEN 1 ELSE 0 END) AS pos_with_any_rejection,
        SUM(j.rej) AS total_rejection_events
    FROM joined j
    GROUP BY j.cid
)
SELECT
    ca.cid AS client_id,
    lc.company_name,
    ca.total_pos_12mo,
    ca.pos_with_any_rejection,
    ca.total_rejection_events,
    ROUND(100.0 * ca.pos_with_any_rejection / NULLIF(ca.total_pos_12mo, 0), 1) AS rejection_rate_pct
FROM client_agg ca
JOIN live_clients lc ON lc.cid = ca.cid
WHERE ca.total_pos_12mo >= 500
ORDER BY rejection_rate_pct DESC NULLS LAST, total_rejection_events DESC
LIMIT 25;
