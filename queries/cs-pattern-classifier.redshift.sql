-- Classify PO rejection notes across the top-25 CS Toolkit clients into pattern buckets.
-- Powers the `pattern` field on data/cs-top-clients.json.
--
-- Rules for pattern assignment (applied client-side after this query runs):
--   pattern = category with highest event count among the 9 tracked categories
--   IF (top_category events / total rejections at client) < 5%           → 'insufficient signal'
--   ELIF (top_category events / total classified events) >= 60%          → '<top>-heavy'
--   ELSE                                                                  → 'mixed'
--
-- Category list (2026-07-07 v4 — Rockstar Capital deep-dive extension):
--   1. duplicate            — create-time dedupe territory
--   2. policy               — CSM workflow conversation
--   3. ownership_changed    — property lifecycle / data hygiene
--   4. budget_guardrail     — v2 (surfaced at IRT) — Advanced Budgeting integration territory
--   5. turn_timing          — v2 (surfaced at IRT) — turn/make-ready workflow integration
--   6. not_needed           — v2 (surfaced at IRT + 200 W) — active-contract awareness territory
--   7. post_month           — v2 (surfaced at IRT + 200 W) — accounting-period default territory
--   8. chargeback_recovery  — v3 (surfaced at Incore) — CBR field / FMO attachment on turn/damage POs
--   9. photo_required       — NEW v4 (surfaced at Rockstar) — required photo attachment at PO entry
--  10. quote_required       — NEW v4 (surfaced at Rockstar) — required quote/estimate attachment at PO entry
--  11. coaching             — entry-form validation territory (GL / unit / general docs)
--   other                   — unclassified fallback
--
-- Provenance:
--   - v1 (4 categories): initial rollout before deep-dives
--   - v2 (added 4):   budget_guardrail, turn_timing, not_needed, post_month
--                     surfaced by IRT (17541) and 200 W Washington (100353) deep-dives 2026-07-06
--   - v3 (added 1):   chargeback_recovery — surfaced by Incore Residential (16706) deep-dive 2026-07-06
--   - v4 (added 2):   photo_required, quote_required
--                     surfaced by Rockstar Capital Management (101469) deep-dive 2026-07-07
--                     Rockstar's rejection log shows 52% of first-rejections are doc-attachment
--                     problems (photos 226, FMO/chargeback 264, quotes 125 of 946 total).
--                     Extending the classifier to catch photo/quote patterns lets us size the
--                     required-attachment-matrix opportunity cross-portfolio.
--                     Note: photo/quote WHEN clauses ordered BEFORE coaching so specific
--                     patterns win over the generic coaching catch-all. Photo/quote phrases
--                     removed from coaching bucket.
--
-- Note on chargeback_recovery matching: Redshift LIKE is case-sensitive by default; input is LOWER()'d
-- upstream. `%cbr%` alone could false-positive on names like "cabri", "cbrand". We use explicit variants
-- observed at Incore + boundary patterns to avoid overmatch.
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

            -- 8. CHARGEBACK RECOVERY (v3 — from Incore deep-dive; extended v4 with Rockstar FMO patterns)
            -- Explicit variants only to avoid false positives on names/words containing "cbr" substrings.
            -- Note: Rockstar's "fmo to show chargeback" phrasing is already caught by the "chargeback"
            -- clause; adding "fmo" alone would over-match (FMO is Rockstar-specific shorthand).
            WHEN note LIKE '%missing cbr%'
                OR note LIKE '%need cbr%'
                OR note LIKE '%any cbr%'
                OR note LIKE '%cbr?%'
                OR note LIKE '%cbr $%'
                OR note LIKE '%cbr amount%'
                OR note LIKE '%no cbr%'
                OR note LIKE '%add cbr%'
                OR note LIKE '%chargeback%'
                OR note LIKE '%charge back%'
                OR note LIKE '%charge-back%'
                OR note LIKE '%bill back%'
                OR note LIKE '%billback%'
                OR note LIKE '%bill-back%'
                OR note LIKE '%resident bill%'
                OR note LIKE '%damage recovery%'
                OR note LIKE '%missing fmo%'
                OR note LIKE '%upload%fmo%'
                OR note LIKE '%attach%fmo%'
                THEN 'chargeback_recovery'

            -- 9. PHOTO REQUIRED (NEW v4 — from Rockstar deep-dive)
            -- Rockstar 226 events. Doc-attachment pattern: approvers demand photos on turn/damage POs.
            -- Ordered BEFORE coaching so specific photo phrasing wins over generic "please attach".
            WHEN note LIKE '%need pic%'
                OR note LIKE '%need photo%'
                OR note LIKE '%need image%'
                OR note LIKE '%missing pic%'
                OR note LIKE '%missing photo%'
                OR note LIKE '%missing image%'
                OR note LIKE '%upload pic%'
                OR note LIKE '%upload photo%'
                OR note LIKE '%upload image%'
                OR note LIKE '%attach pic%'
                OR note LIKE '%attach photo%'
                OR note LIKE '%attach image%'
                OR note LIKE '%send pic%'
                OR note LIKE '%send photo%'
                OR note LIKE '%include pic%'
                OR note LIKE '%include photo%'
                OR note LIKE '%add pic%'
                OR note LIKE '%add photo%'
                OR note LIKE '%more pic%'
                OR note LIKE '%more photo%'
                OR note LIKE '%no pic%'
                OR note LIKE '%no photo%'
                OR note LIKE '%without pic%'
                OR note LIKE '%without photo%'
                OR note LIKE '%pictures please%'
                OR note LIKE '%photos please%'
                OR note LIKE '%pls upload pic%'
                OR note LIKE '%pls upload photo%'
                OR note LIKE '%please upload pic%'
                OR note LIKE '%please upload photo%'
                OR note LIKE '%show pic%'
                OR note LIKE '%show photo%'
                THEN 'photo_required'

            -- 10. QUOTE REQUIRED (NEW v4 — from Rockstar deep-dive)
            -- Rockstar 125 events. Doc-attachment pattern: approvers demand quotes/estimates
            -- for POs above threshold amounts.
            WHEN note LIKE '%need quote%'
                OR note LIKE '%need a quote%'
                OR note LIKE '%need estimate%'
                OR note LIKE '%need an estimate%'
                OR note LIKE '%missing quote%'
                OR note LIKE '%missing estimate%'
                OR note LIKE '%upload quote%'
                OR note LIKE '%upload estimate%'
                OR note LIKE '%attach quote%'
                OR note LIKE '%attach estimate%'
                OR note LIKE '%send quote%'
                OR note LIKE '%send estimate%'
                OR note LIKE '%include quote%'
                OR note LIKE '%include estimate%'
                OR note LIKE '%where is%quote%'
                OR note LIKE '%where is%estimate%'
                OR note LIKE '%provide quote%'
                OR note LIKE '%provide estimate%'
                OR note LIKE '%no quote%'
                OR note LIKE '%no estimate%'
                OR note LIKE '%please upload quote%'
                OR note LIKE '%pls upload quote%'
                OR note LIKE '%please attach quote%'
                OR note LIKE '%pls attach quote%'
                OR note LIKE '%quote please%'
                OR note LIKE '%estimate please%'
                THEN 'quote_required'

            -- 11. COACHING (general entry-form validation — with photos/quotes removed to v4 categories above)
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
