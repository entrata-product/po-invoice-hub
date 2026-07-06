-- Classify PO rejection notes across the top-25 CS Toolkit clients into pattern buckets.
-- Powers the `pattern` field on data/cs-top-clients.json.
--
-- Rules for pattern assignment (applied client-side after this query runs):
--   pattern = category with highest event count among the 8 tracked categories
--   IF (top_category events / total rejections at client) < 5%           → 'insufficient signal'
--   ELIF (top_category events / total classified events) >= 60%          → '<top>-heavy'
--   ELSE                                                                  → 'mixed'
--
-- Category list (2026-07-06 v2 — post-deep-dive expansion):
--   1. duplicate           — create-time dedupe territory
--   2. coaching            — entry-form validation territory (GL / unit / docs)
--   3. policy              — CSM workflow conversation
--   4. ownership_changed   — property lifecycle / data hygiene
--   5. budget_guardrail    — NEW (surfaced at IRT) — Advanced Budgeting integration territory
--   6. turn_timing         — NEW (surfaced at IRT) — turn/make-ready workflow integration
--   7. not_needed          — NEW (surfaced at IRT + 200 W) — active-contract awareness territory
--   8. post_month          — NEW (surfaced at IRT + 200 W) — accounting-period default territory
--   other                  — unclassified fallback
--
-- Provenance of the four new categories:
--   - budget_guardrail: IRT deep-dive 2026-07-06 (199 events at that client alone)
--   - turn_timing:      IRT deep-dive 2026-07-06 (180 events at that client alone)
--   - not_needed:       IRT deep-dive 2026-07-06 (99 events) + 200 W deep-dive (3 events with contract signal)
--   - post_month:       IRT deep-dive 2026-07-06 (49 events) + 200 W deep-dive (4 events)
--
-- Snapshot classifier, not a governance rule set. When new deep-dives surface new phrasing,
-- extend the WHEN clauses below. Keep ORDER of WHEN clauses stable (first match wins).

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
            -- 1. DUPLICATE (existing + variants seen at IRT/200 W)
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
                OR note LIKE '%duplicate po%'
                OR note LIKE '%dup po%'
                OR note LIKE '%po already%'
                OR note LIKE '%already have a po%'
                OR note LIKE '%already open%po%'
                THEN 'duplicate'

            -- 2. POLICY (existing, keep tight)
            WHEN note LIKE '%do not use%po%'
                OR note LIKE '%don''t use%po%'
                OR note LIKE '%we do not use%'
                OR note LIKE '%no longer using%po%'
                OR note LIKE '%stop%making%po%'
                OR note = 'do not use'
                OR note = 'don''t use'
                OR note LIKE '%do not use them%'
                THEN 'policy'

            -- 3. OWNERSHIP CHANGED
            WHEN note LIKE '%no longer manage%'
                OR note LIKE '%community sold%'
                OR note LIKE '%no longer own%'
                OR note LIKE '%property sold%'
                OR note LIKE '%- sold%'
                THEN 'ownership_changed'

            -- 4. BUDGET GUARDRAIL (NEW — from IRT deep-dive)
            WHEN note LIKE '%budget%detail%'
                OR note LIKE '%budget%number%'
                OR note LIKE '%where are we saving%'
                OR note LIKE '%list savings%'
                OR note LIKE '%need savings%'
                OR note LIKE '%over budget%'
                OR note LIKE '%get within budget%'
                OR note LIKE '%get in budget%'
                OR note LIKE '%where is%overage%'
                OR note LIKE '%where is overage%'
                OR note LIKE '%explain overage%'
                OR note LIKE '%budget overage%'
                OR note LIKE '%not budgeted%'
                OR note LIKE '%exceeds budget%'
                OR note LIKE '%above budget%'
                OR note LIKE '%budget issue%'
                THEN 'budget_guardrail'

            -- 5. TURN/TIMING WORKFLOW (NEW — from IRT deep-dive)
            WHEN note LIKE '%need dates%'
                OR note LIKE '%missing dates%'
                OR note LIKE '%need%date%'
                OR note LIKE '%add%date%'
                OR note LIKE '%make ready date%'
                OR note LIKE '%make-ready date%'
                OR note LIKE '%moving out%'
                OR note LIKE '%move out date%'
                OR note LIKE '%move-out date%'
                OR note LIKE '%notice date%'
                OR note LIKE '%turn date%'
                OR note LIKE '%turnover date%'
                OR note LIKE '%mr date%'
                THEN 'turn_timing'

            -- 6. NOT NEEDED / CONTRACT COVERED (NEW — from IRT + 200 W deep-dives)
            WHEN note LIKE '%not needed%'
                OR note LIKE '%po not needed%'
                OR note LIKE '%no need to generate%'
                OR note LIKE '%no need for%po%'
                OR note LIKE '%please cancel%'
                OR note LIKE '%cancel po%'
                OR note LIKE '%cancel this po%'
                OR note LIKE '%mtm contract%'
                OR note LIKE '%annual contract%'
                OR note LIKE '%included in%contract%'
                OR note LIKE '%covered by contract%'
                OR note LIKE '%as per contract%'
                OR note LIKE '%per contract%'
                THEN 'not_needed'

            -- 7. POST MONTH (NEW — from IRT + 200 W deep-dives)
            WHEN note LIKE '%post month/year has passed%'
                OR note LIKE '%post month has passed%'
                OR note LIKE '%change post month%'
                OR note LIKE '%correct post month%'
                OR note LIKE '%wrong post month%'
                OR note LIKE '%post month is wrong%'
                OR note LIKE '%change post period%'
                OR note LIKE '%adjust post month%'
                OR note LIKE '%wrong period%'
                OR note LIKE '%period closed%'
                THEN 'post_month'

            -- 8. COACHING (existing + extensions from RL and IRT deep-dives)
            WHEN note LIKE '%pls code%'
                OR note LIKE '%please code%'
                OR note LIKE '%recode%'
                OR note LIKE '%re-code%'
                OR note LIKE '%coded to%'
                OR note LIKE '%code to%'
                OR note LIKE '%should be coded%'
                OR note LIKE '%wrong gl%'
                OR note LIKE '%correct gl%'
                OR note LIKE '%change gl%'
                OR note LIKE '%please correct gl%'
                OR note LIKE '%gl code%'
                OR note LIKE '%pls add unit%'
                OR note LIKE '%please add unit%'
                OR note LIKE '%need unit%'
                OR note LIKE '%missing unit%'
                OR note LIKE '%no unit%'
                OR note LIKE '%add unit #%'
                OR note LIKE '%pls attach%'
                OR note LIKE '%please attach%'
                OR note LIKE '%attach contract%'
                OR note LIKE '%attach receipt%'
                OR note LIKE '%attach documentation%'
                OR note LIKE '%attach photos%'
                OR note LIKE '%add photos%'
                OR note LIKE '%please add photos%'
                OR note LIKE '%pls add support%'
                OR note LIKE '%missing capex%'
                OR note LIKE '%see teams%'
                THEN 'coaching'

            ELSE 'other'
        END AS category
    FROM rej
    WHERE rn = 1
)
SELECT cid, category, COUNT(*) AS events
FROM classified
GROUP BY cid, category
ORDER BY cid, events DESC;
