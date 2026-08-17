/* =====================================================================================
   USER PENETRATION (POs + Invoices, unified) — Redshift-adapted for dashboard.
   Sources: Pallavi Nawale's Dataset 2 in Jira DEV-310770 (POs) and DEV-318886 (Invoices).
   Adapted 2026-08-17.

   PURPOSE
     "Of the licensed non-system users at a client, what share touched a real
     PO / Invoice in a given month?" (Created OR edited via ap_header_logs.)

     Emits one row per (client × month × doc_type) where doc_type is 'PO' or
     'INVOICE'. Powers the Adoption tab tiles and cross-suite penetration
     comparisons.

   SCOPE / FILTERS
     - Live-client scope (clients.company_status_type_id = 4).
     - Non-template PO / Invoice activity only.
     - Trailing 12 calendar months (portfolio-wide; scan is lean because we
       hit ap_header_logs pre-filtered by ap_header_type_id).
     - System users excluded from the "active" numerator: 21 (Vendor Portal
       proxy), 48 (UEM), 67 (Invoice Processing manual), 77 (Invoice
       Processing upload).
     - Licensed users = company_users.company_user_type_id = 2, not disabled.
       This is a portfolio-current count (not point-in-time per month), so
       penetration for old months is measured against today's roster.

   REDSHIFT NOTES
     - Schema-prefix every table with entrata_entrata.
     - date_trunc('month', ...)::date -> DATE_TRUNC('month', ...) then cast.
     - to_char(..., 'YYYY-MM') is supported.
     - Flag columns (is_template, is_disabled, etc.) are INTEGER 0/1 in
       the mirror, not BOOLEAN. Compare with `COALESCE(col, 0) = 0`.

   CAVEATS (carried through to _notes on the emitted JSON)
     - Licensed-user denominator is portfolio-current (see above).
   ===================================================================================== */

WITH
live_clients AS (
    SELECT c.id AS cid
    FROM entrata_entrata.clients c
    WHERE c.company_status_type_id = 4
),
licensed_users AS (
    SELECT
        cu.cid AS client_id,
        COUNT(*) AS total_licensed_users
    FROM entrata_entrata.company_users cu
    INNER JOIN live_clients lc ON lc.cid = cu.cid
    WHERE cu.company_user_type_id = 2
      AND COALESCE(cu.is_disabled, 0) = 0
    GROUP BY cu.cid
),
po_activity AS (
    SELECT
        ah.cid AS client_id,
        ah.id AS doc_id,
        ah.created_by AS user_id,
        ah.created_on AS activity_on,
        'PO' AS doc_type
    FROM entrata_entrata.ap_headers ah
    INNER JOIN live_clients lc ON lc.cid = ah.cid
    WHERE ah.ap_header_type_id = 4
      AND COALESCE(ah.is_template, false) = false
      AND ah.created_by IS NOT NULL
      AND ah.created_on >= DATEADD(month, -12, CURRENT_DATE)

    UNION ALL

    SELECT
        ahl.cid AS client_id,
        ahl.ap_header_id AS doc_id,
        ahl.updated_by AS user_id,
        COALESCE(ahl.log_datetime, ahl.updated_on) AS activity_on,
        'PO' AS doc_type
    FROM entrata_entrata.ap_header_logs ahl
    INNER JOIN live_clients lc ON lc.cid = ahl.cid
    WHERE ahl.ap_header_type_id = 4
      AND COALESCE(ahl.is_template, false) = false
      AND ahl.updated_by IS NOT NULL
      AND COALESCE(ahl.log_datetime, ahl.updated_on) >= DATEADD(month, -12, CURRENT_DATE)
),
invoice_activity AS (
    SELECT
        ah.cid AS client_id,
        ah.id AS doc_id,
        ah.created_by AS user_id,
        ah.created_on AS activity_on,
        'INVOICE' AS doc_type
    FROM entrata_entrata.ap_headers ah
    INNER JOIN live_clients lc ON lc.cid = ah.cid
    WHERE ah.ap_header_type_id = 5
      AND COALESCE(ah.is_template, false) = false
      AND ah.created_by IS NOT NULL
      AND ah.created_on >= DATEADD(month, -12, CURRENT_DATE)

    UNION ALL

    SELECT
        ahl.cid AS client_id,
        ahl.ap_header_id AS doc_id,
        ahl.updated_by AS user_id,
        COALESCE(ahl.log_datetime, ahl.updated_on) AS activity_on,
        'INVOICE' AS doc_type
    FROM entrata_entrata.ap_header_logs ahl
    INNER JOIN live_clients lc ON lc.cid = ahl.cid
    WHERE ahl.ap_header_type_id = 5
      AND COALESCE(ahl.is_template, false) = false
      AND ahl.updated_by IS NOT NULL
      AND COALESCE(ahl.log_datetime, ahl.updated_on) >= DATEADD(month, -12, CURRENT_DATE)
),
combined_activity AS (
    SELECT * FROM po_activity
    UNION ALL
    SELECT * FROM invoice_activity
),
active_users_monthly AS (
    SELECT
        ca.client_id,
        ca.doc_type,
        DATE_TRUNC('month', ca.activity_on)::date AS month_start,
        COUNT(DISTINCT ca.user_id) AS active_users
    FROM combined_activity ca
    WHERE ca.user_id NOT IN (21, 48, 67, 77)
    GROUP BY ca.client_id, ca.doc_type, DATE_TRUNC('month', ca.activity_on)::date
)
SELECT
    aum.client_id,
    aum.doc_type,
    TO_CHAR(aum.month_start, 'YYYY-MM')                                  AS period_month,
    COALESCE(lu.total_licensed_users, 0)                                 AS total_licensed_users,
    aum.active_users                                                     AS active_users,
    CASE
        WHEN COALESCE(lu.total_licensed_users, 0) = 0 THEN NULL
        ELSE ROUND(100.0 * aum.active_users / lu.total_licensed_users, 2)
    END                                                                  AS penetration_pct
FROM active_users_monthly aum
LEFT JOIN licensed_users lu
    ON lu.client_id = aum.client_id
ORDER BY aum.client_id, aum.doc_type, aum.month_start;
