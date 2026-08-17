/* =====================================================================================
   INVOICE EARLY-PAY — Redshift-adapted for dashboard.
   Source: Pallavi Nawale's Dataset 1 in Jira DEV-318886.
   Adapted 2026-08-17.

   PURPOSE
     Quantify how much early-payment discount value clients are (a) exposing
     themselves to by configuring discount terms, and (b) actually capturing
     when they pay those invoices before the deadline.

     Two independent aggregations live in this file. Run them as two MCP
     calls (they share CTEs but Redshift MCP wants one statement per call).
     Both emit narrow rows ready to hand straight to the transformer.

       (A) CONFIG COVERAGE — one row per live client
       (B) CAPTURE (client x month) — one row per (client, month) with an
           eligible invoice

   MIRROR CAVEAT (critical — carry into _notes on emitted JSON)
     ap_payee_terms has been removed from the live mirror. We use the
     archived snapshot ap_payee_terms_removed_03_21_25, which reflects
     discount config as of 2025-03-21. Anything a client configured or
     changed after that date is invisible here. The eligible-invoice set is
     therefore small (~75 discount-configured payee_term rows portfolio-wide
     in the snapshot). Framing on the dashboard: this is a
     "config adoption gap" chart first, "capture rate" chart second.

   SCOPE / FILTERS
     - Live-client scope (clients.company_status_type_id = 4).
     - Invoices only (ap_header_type_id = 5), posted, non-deleted,
       non-template, non-temporary, non-reversal.
     - Trailing 12 months on post_date for the CAPTURE query.
     - Discount terms must have percentage > 0 AND discount_period_days > 0
       AND not deleted (in the snapshot).

   REDSHIFT NOTES
     - Interval add: `post_date + (N || ' days')::interval` -> DATEADD(day, N, post_date).
     - Schema-prefix every table with entrata_entrata.
     - IS TRUE / IS FALSE work but we use `= TRUE / = FALSE` with COALESCE to be safe.
   ===================================================================================== */


/* -------------------------------------------------------------------------------------
   QUERY (A) — CONFIG COVERAGE
   Row shape: client_id, discount_terms_active, distinct_vendors_covered
   Semantics: "How many discount payee-term DEFINITIONS does this client
   have in the snapshot, and how many distinct vendors are actually TAGGED
   with one of those discount terms in ap_headers (trailing 12 mo)?"
   NOTE: ap_payee_terms is a lookup table (no vendor FK). Vendor coverage
   is derived by joining ap_headers.ap_payee_term_id back to the discount
   term set. A client with zero rows in the result has no discount terms
   configured as of the snapshot.
   ------------------------------------------------------------------------------------- */

WITH
live_clients AS (
    SELECT c.id AS cid
    FROM entrata_entrata.clients c
    WHERE c.company_status_type_id = 4
),
discount_terms AS (
    SELECT apt.cid AS client_id, apt.id AS term_id
    FROM entrata_entrata.ap_payee_terms_removed_03_21_25 apt
    INNER JOIN live_clients lc ON lc.cid = apt.cid
    WHERE apt.deleted_by IS NULL
      AND apt.deleted_on IS NULL
      AND COALESCE(apt.percentage, 0) > 0
      AND COALESCE(apt.discount_period_days, 0) > 0
),
term_counts AS (
    SELECT client_id, COUNT(*) AS discount_terms_active
    FROM discount_terms
    GROUP BY client_id
),
vendor_coverage AS (
    SELECT
        ah.cid AS client_id,
        COUNT(DISTINCT ah.ap_payee_id) AS distinct_vendors_covered
    FROM entrata_entrata.ap_headers ah
    INNER JOIN discount_terms dt
        ON dt.client_id = ah.cid
       AND dt.term_id = ah.ap_payee_term_id
    WHERE ah.ap_header_type_id = 5
      AND ah.post_date >= DATEADD(month, -12, CURRENT_DATE)
      AND COALESCE(ah.is_deleted, false) = false
      AND COALESCE(ah.is_template, false) = false
      AND ah.ap_payee_id IS NOT NULL
    GROUP BY ah.cid
)
SELECT
    tc.client_id,
    tc.discount_terms_active,
    COALESCE(vc.distinct_vendors_covered, 0) AS distinct_vendors_covered
FROM term_counts tc
LEFT JOIN vendor_coverage vc ON vc.client_id = tc.client_id
ORDER BY tc.client_id;


/* -------------------------------------------------------------------------------------
   QUERY (B) — CAPTURE (client x month)
   Row shape: client_id, period_month, eligible_invoice_count,
              discount_available_sum, discount_captured_sum,
              past_deadline_or_paid_count
   Semantics: For the trailing 12 months (bucketed by capture-date if
   captured, else deadline-date), how much discount was on the table and
   how much did the client actually capture? Denominator uses only invoices
   with discount_available > 0 whose deadline is past OR that were captured.
   ------------------------------------------------------------------------------------- */

WITH
live_clients AS (
    SELECT c.id AS cid
    FROM entrata_entrata.clients c
    WHERE c.company_status_type_id = 4
),
eligible_invoices AS (
    SELECT
        ah.cid                                                             AS client_id,
        ah.id                                                              AS invoice_id,
        ah.ap_payee_id                                                     AS vendor_id,
        ah.post_date::date                                                 AS post_date,
        ah.transaction_amount,
        apt.id                                                             AS ap_payee_term_id,
        apt.percentage,
        apt.discount_period_days,
        DATEADD(day, apt.discount_period_days, ah.post_date::date)         AS discount_deadline,
        ROUND(ah.transaction_amount * apt.percentage / 100.0, 2)           AS discount_available
    FROM entrata_entrata.ap_headers ah
    INNER JOIN live_clients lc
        ON lc.cid = ah.cid
    INNER JOIN entrata_entrata.ap_payee_terms_removed_03_21_25 apt
        ON apt.cid = ah.cid
       AND apt.id = ah.ap_payee_term_id
    WHERE ah.ap_header_type_id = 5
      AND ah.post_date >= DATEADD(month, -12, CURRENT_DATE)
      AND COALESCE(ah.is_posted, false) = true
      AND COALESCE(ah.is_deleted, false) = false
      AND ah.deleted_by IS NULL
      AND COALESCE(ah.is_template, false) = false
      AND COALESCE(ah.is_temporary, false) = false
      AND ah.reversal_ap_header_id IS NULL
      AND apt.deleted_by IS NULL
      AND apt.deleted_on IS NULL
      AND COALESCE(apt.percentage, 0) > 0
      AND COALESCE(apt.discount_period_days, 0) > 0
      AND COALESCE(ah.transaction_amount, 0) <> 0
),
captured AS (
    SELECT
        ad.cid                                                             AS client_id,
        ad.ap_header_id                                                    AS invoice_id,
        SUM(ABS(aa.allocation_amount))                                     AS discount_amount_captured,
        MIN(ap.payment_date)::date                                         AS first_capture_payment_date
    FROM entrata_entrata.ap_allocations aa
    INNER JOIN entrata_entrata.ap_details ad
        ON ad.cid = aa.cid
       AND ad.id = aa.charge_ap_detail_id
    LEFT JOIN entrata_entrata.ap_headers pay_ah
        ON pay_ah.cid = aa.cid
       AND pay_ah.id = aa.lump_ap_header_id
    LEFT JOIN entrata_entrata.ap_payments ap
        ON ap.cid = pay_ah.cid
       AND ap.id = pay_ah.ap_payment_id
    WHERE aa.charge_ap_detail_id = aa.credit_ap_detail_id
      AND aa.allocation_amount < 0
      AND COALESCE(aa.is_deleted, false) = false
      AND aa.gl_transaction_type_id = 4
    GROUP BY ad.cid, ad.ap_header_id
),
per_invoice AS (
    SELECT
        ei.client_id,
        ei.invoice_id,
        ei.discount_available::numeric(18, 2)                              AS discount_available,
        COALESCE(c.discount_amount_captured, 0)::numeric(18, 2)            AS discount_captured,
        c.first_capture_payment_date                                       AS payment_date,
        ei.discount_deadline,
        TO_CHAR(
            COALESCE(c.first_capture_payment_date, ei.discount_deadline),
            'YYYY-MM'
        )                                                                  AS period_month
    FROM eligible_invoices ei
    LEFT JOIN captured c
        ON c.client_id = ei.client_id
       AND c.invoice_id = ei.invoice_id
    WHERE ei.discount_available > 0
      AND (
            c.first_capture_payment_date IS NOT NULL
            OR ei.discount_deadline < CURRENT_DATE
          )
)
SELECT
    pi.client_id,
    pi.period_month,
    COUNT(*)                                                               AS eligible_invoice_count,
    SUM(pi.discount_available)                                             AS discount_available_sum,
    SUM(pi.discount_captured)                                              AS discount_captured_sum,
    SUM(CASE WHEN pi.payment_date IS NOT NULL THEN 1 ELSE 0 END)          AS captured_invoice_count,
    CASE
        WHEN SUM(pi.discount_available) = 0 THEN NULL
        ELSE ROUND(100.0 * SUM(pi.discount_captured) / SUM(pi.discount_available), 2)
    END                                                                    AS capture_rate_pct
FROM per_invoice pi
GROUP BY pi.client_id, pi.period_month
ORDER BY pi.client_id, pi.period_month;
