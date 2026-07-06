/*
  ============================================================
  Invoice Core Dataset — Domo AP Invoice Performance Dashboard
  ============================================================
  Scope:    Live Rapid and Standard clients only
  Excludes: Test, demo, and sandbox sites
  Grain:    One row per Invoice_ID

  NOTE: source_id values (1-13) are placeholders.
  Dev must confirm actual system IDs or flags that map
  to each channel before running in production.
  ============================================================
*/

-- ============================================================
-- DATASET 1: Invoice Core Dataset (HIGHEST PRIORITY)
-- ============================================================

SELECT
    i.invoice_id,
    i.client_id,
    i.property_id,
    i.creation_date,
    DATE_FORMAT(i.creation_date, '%Y-%m')        AS creation_month,
    i.invoice_type,
    i.invoice_status,

    /* ── SOURCE CHANNEL MAPPING (14 channels) ── */
    CASE
        WHEN i.source_id = 1  THEN 'Add Invoice (Manual)'
        WHEN i.source_id = 2  THEN 'Bulk Invoice Entry'
        WHEN i.source_id = 3  THEN 'ELI Invoice Entry'
        WHEN i.source_id = 4  THEN 'Invoice Processing'
        WHEN i.source_id = 5  THEN 'Invoice Import'
        WHEN i.source_id = 6  THEN 'Purchase Orders: Create Invoice'
        WHEN i.source_id = 7  THEN 'Dashboard Shortcut'
        WHEN i.source_id = 8  THEN 'Vendor Portal'
        WHEN i.source_id = 9  THEN 'Invoice Template'
        WHEN i.source_id = 10 THEN 'Recurring Transaction'
        WHEN i.source_id = 11 THEN 'Duplicate / Use Previous'
        WHEN i.source_id = 12 THEN 'API'
        WHEN i.source_id = 13 THEN 'UEM'
        ELSE                       'Other'  -- Document unidentified sources
    END                                          AS source_channel,

    /* ── FINANCIAL ── */
    i.invoice_total_amount,                      -- Required, no nulls

    /* ── PDF COMPLIANCE ── */
    CASE
        WHEN ia.invoice_id IS NOT NULL THEN 1
        ELSE 0
    END                                          AS has_attachment,

    /* ── VELOCITY ── */
    CASE
        WHEN i.invoice_status = 'Posted'
        THEN DATEDIFF(i.posted_date, i.creation_date)
        ELSE NULL                                -- NULL if not yet posted
    END                                          AS days_to_posted,

    /* ── APPROVAL VELOCITY (NEW) ── */
    CASE
        WHEN i.approved_date IS NOT NULL
        THEN DATEDIFF(i.approved_date, i.creation_date)
        ELSE NULL                                -- NULL if not yet approved
    END                                          AS days_to_approved,

    /* ── TOUCHLESS FLAG ── */
    CASE
        WHEN i.invoice_status = 'Posted'
         AND NOT EXISTS (
             SELECT 1
             FROM invoice_audit_log al
             WHERE al.invoice_id = i.invoice_id
               AND al.action IN ('Edit', 'Save')
               AND al.performed_by_user IS NOT NULL
         )
        THEN 1
        ELSE 0
    END                                          AS is_touchless,

    /* ── EXCEPTION FLAG ── */
    CASE
        WHEN i.has_exception_flag = 1
          OR i.is_duplicate       = 1
          OR i.tax_mismatch       = 1
        THEN 1
        ELSE 0
    END                                          AS is_exception,

    /* ── FIRST-TIME-RIGHT (NEW) ── */
    CASE
        WHEN i.invoice_status = 'Posted'
         AND NOT EXISTS (
             SELECT 1
             FROM invoice_audit_log al
             WHERE al.invoice_id = i.invoice_id
               AND al.action = 'Reject'
         )
        THEN 1
        ELSE 0
    END                                          AS is_first_time_right,

    /* ── REJECTION TRACKING (NEW) ── */
    COALESCE(rej.rejection_count, 0)             AS rejection_count,
    rej.rejection_reason,                        -- Most recent rejection reason; NULL if never rejected

    /* ── CLIENT SEGMENTATION (NEW) ── */
    CASE
        WHEN cs.total_units >= 500 THEN 'Enterprise'
        WHEN cs.total_units >= 100 THEN 'Mid-Market'
        ELSE                            'Small'
    END                                          AS client_segment,

    /* ── ENTRY METHOD ROLLUP (NEW) ── */
    CASE
        WHEN i.source_id IN (1, 2, 7)           THEN 'Manual'
        WHEN i.source_id IN (3, 4, 8, 10)       THEN 'Automated'
        WHEN i.source_id IN (5, 12, 13)          THEN 'Import'
        ELSE                                          'Other'
    END                                          AS entry_method_group

FROM invoices i

/* PDF Attachment — LEFT JOIN to flag presence only */
LEFT JOIN (
    SELECT DISTINCT invoice_id
    FROM invoice_attachments
) ia ON ia.invoice_id = i.invoice_id

/* Rejection history — count + most recent reason */
LEFT JOIN (
    SELECT
        al.invoice_id,
        COUNT(*)                                 AS rejection_count,
        MAX_BY(al.rejection_reason, al.action_date) AS rejection_reason
    FROM invoice_audit_log al
    WHERE al.action = 'Reject'
    GROUP BY al.invoice_id
) rej ON rej.invoice_id = i.invoice_id

/* Client segmentation by total managed units */
LEFT JOIN (
    SELECT client_id, SUM(unit_count) AS total_units
    FROM properties
    GROUP BY client_id
) cs ON cs.client_id = i.client_id

/* Exclude test/demo/sandbox */
JOIN clients c ON c.client_id = i.client_id
WHERE c.client_type  IN ('Rapid', 'Standard')
  AND c.is_test_site  = 0
  AND c.is_demo_site  = 0
  AND c.is_sandbox    = 0

ORDER BY i.creation_date DESC;


-- ============================================================
-- TOP 20 CLIENTS VIEW
-- Supports both all-time and trailing 30 days.
-- Uncomment the date filter below for trailing 30 days.
-- ============================================================

SELECT
    i.client_id,
    c.client_name,
    CASE
        WHEN cs.total_units >= 500 THEN 'Enterprise'
        WHEN cs.total_units >= 100 THEN 'Mid-Market'
        ELSE                            'Small'
    END                              AS client_segment,
    COUNT(i.invoice_id)              AS invoice_count,
    SUM(i.invoice_total_amount)      AS total_dollar_volume,
    AVG(
        CASE
            WHEN i.invoice_status = 'Posted'
            THEN DATEDIFF(i.posted_date, i.creation_date)
        END
    )                                AS avg_days_to_posted

FROM invoices i
JOIN clients c ON c.client_id = i.client_id
LEFT JOIN (
    SELECT client_id, SUM(unit_count) AS total_units
    FROM properties
    GROUP BY client_id
) cs ON cs.client_id = i.client_id

WHERE c.client_type  IN ('Rapid', 'Standard')
  AND c.is_test_site  = 0
  AND c.is_demo_site  = 0
  AND c.is_sandbox    = 0
  -- AND i.creation_date >= DATE_SUB(CURDATE(), INTERVAL 30 DAY)  -- Trailing 30 days

GROUP BY i.client_id, c.client_name, client_segment
ORDER BY invoice_count DESC
LIMIT 20;


-- ============================================================
-- DATASET 2: Early Pay Discount Capture
-- Requires JOIN with payment/discount tables.
-- Dev to confirm table and column names.
-- ============================================================

SELECT
    p.invoice_id,
    p.client_id,
    DATE_FORMAT(p.payment_date, '%Y-%m')   AS payment_month,
    p.discount_available,
    p.discount_captured,
    CASE
        WHEN p.discount_available > 0
        THEN ROUND((p.discount_captured / p.discount_available) * 100, 2)
        ELSE NULL
    END                                    AS capture_rate_pct

FROM payments p
JOIN clients c ON c.client_id = p.client_id
WHERE c.client_type  IN ('Rapid', 'Standard')
  AND c.is_test_site  = 0
  AND c.is_demo_site  = 0
  AND c.is_sandbox    = 0
  AND p.discount_available > 0

ORDER BY p.payment_date DESC;


-- ============================================================
-- DATASET 3: PO-to-Invoice Cycle Time
-- Requires JOIN between PO and Invoice tables.
-- Dev to confirm matching key between PO and Invoice.
-- ============================================================

SELECT
    po.po_id,
    i.invoice_id,
    po.client_id,
    DATE_FORMAT(po.approved_date, '%Y-%m')  AS period_month,
    po.approved_date                        AS po_approved_date,
    i.posted_date                           AS invoice_posted_date,
    DATEDIFF(i.posted_date, po.approved_date) AS cycle_time_days

FROM purchase_orders po
JOIN invoices i        ON i.po_id      = po.po_id
JOIN clients c         ON c.client_id  = po.client_id

WHERE c.client_type    IN ('Rapid', 'Standard')
  AND c.is_test_site    = 0
  AND c.is_demo_site    = 0
  AND c.is_sandbox      = 0
  AND po.approved_date  IS NOT NULL
  AND i.posted_date     IS NOT NULL

ORDER BY po.approved_date DESC;


-- ============================================================
-- DATASET 4: User Penetration Rate
-- Requires licensed user count per client as denominator.
-- Dev to confirm licensed user table and column names.
-- ============================================================

SELECT
    u.client_id,
    c.client_name,
    DATE_FORMAT(CURDATE(), '%Y-%m')              AS period_month,
    COUNT(DISTINCT u.user_id)                    AS total_licensed_users,
    COUNT(DISTINCT i.created_by_user_id)         AS active_invoice_users,
    ROUND(
        COUNT(DISTINCT i.created_by_user_id)
        / NULLIF(COUNT(DISTINCT u.user_id), 0) * 100
    , 2)                                         AS penetration_rate_pct

FROM licensed_users u
JOIN clients c ON c.client_id = u.client_id

LEFT JOIN invoices i
    ON  i.client_id        = u.client_id
    AND i.created_by_user_id = u.user_id
    AND i.creation_date   >= DATE_SUB(CURDATE(), INTERVAL 30 DAY)

WHERE c.client_type  IN ('Rapid', 'Standard')
  AND c.is_test_site  = 0
  AND c.is_demo_site  = 0
  AND c.is_sandbox    = 0

GROUP BY u.client_id, c.client_name
ORDER BY penetration_rate_pct DESC;
