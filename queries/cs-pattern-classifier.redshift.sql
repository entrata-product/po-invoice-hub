-- Classify PO rejection notes across the top-25 CS Toolkit clients into pattern buckets.
-- Powers the `pattern` field on data/cs-top-clients.json.
--
-- Rules for pattern assignment (applied client-side after this query runs):
--   pattern = category with highest event count among (duplicate, coaching, policy, ownership_changed)
--   IF (top_category events / total rejections at client) < 5%           → 'insufficient signal'
--   ELIF (top_category events / total classified events) >= 60%          → '<top>-heavy'
--   ELSE                                                                  → 'mixed'
--
-- Run 2026-07-06. This is a snapshot classifier, not a governance rule set — expand keyword buckets
-- when new deep-dives surface new phrasing (e.g., when we deep-dive a client whose notes are all
-- 'no PO — pex' style like EPC, extend the 'policy' bucket accordingly).

WITH po_scope AS (
    SELECT h.cid, h.id AS ap_header_id
    FROM entrata_entrata.ap_headers h
    WHERE h.cid IN (15769,16991,5422,10502,100880,17994,16706,101072,15489,101469,
                    19613,101585,17541,17623,17988,101084,100142,101578,19770,18675,
                    14900,17651,17989,100353,14687)
      AND h.ap_header_type_id = 4
      AND h.ap_header_sub_type_id IN (4,11,19,20)
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
      AND ahl.action IN ('Rejected','Returned To Previous','Returned To Beginning')
      AND ahl.approval_note IS NOT NULL
      AND LENGTH(TRIM(ahl.approval_note)) > 0
),
classified AS (
    SELECT cid,
        CASE
            WHEN note LIKE '%duplicate%'
                OR note LIKE '%dupe%'
                OR note = 'double'
                OR note LIKE '%invoice%enter%'
                OR note LIKE '%invoice entered%'
                OR note LIKE '%added as invoice%'
                OR note LIKE '%invoice created%'
                OR note LIKE '%posted as invoice%'
                OR note LIKE '%invoices posted%'
                OR note LIKE '%already added as invoice%'
                OR note LIKE '%invoices entered%'
                OR note LIKE '%added as invoices%'
                THEN 'duplicate'
            WHEN note LIKE '%do not use%po%'
                OR note LIKE '%don''t use%po%'
                OR note LIKE '%we do not use%'
                OR note LIKE '%no longer using%po%'
                OR note LIKE '%stop%making%po%'
                OR note = 'do not use'
                OR note = 'don''t use'
                OR note LIKE '%do not use them%'
                THEN 'policy'
            WHEN note LIKE '%pls code%'
                OR note LIKE '%please code%'
                OR note LIKE '%pls add unit%'
                OR note LIKE '%please add unit%'
                OR note LIKE '%pls attach%'
                OR note LIKE '%please attach%'
                OR note LIKE '%pls add support%'
                OR note LIKE '%need unit%'
                OR note LIKE '%missing unit%'
                OR note LIKE '%missing capex%'
                OR note LIKE '%wrong gl%'
                OR note LIKE '%correct gl%'
                OR note LIKE '%attach receipt%'
                OR note LIKE '%attach documentation%'
                OR note LIKE '%should be coded%'
                OR note LIKE '%coded to%'
                OR note LIKE '%code to%'
                THEN 'coaching'
            WHEN note LIKE '%no longer manage%'
                OR note LIKE '%community sold%'
                OR note LIKE '%no longer own%'
                OR note LIKE '%property sold%'
                THEN 'ownership_changed'
            ELSE 'other'
        END AS category
    FROM rej
    WHERE rn = 1
)
SELECT cid, category, COUNT(*) AS events
FROM classified
GROUP BY cid, category
ORDER BY cid, events DESC;
