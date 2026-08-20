-- ---------------------------------------------------------------------------
-- 02  DEFECT AUDIT
--
-- Before resolving anything, establish what is broken and how much of it there
-- is. Every figure below is a count of records that a routine query would
-- either drop silently or attribute to the wrong fan.
-- ---------------------------------------------------------------------------

-- A. Scan events that carry no ticket identifier.
-- These are real people through a real turnstile. They are countable as
-- attendance and unattributable to a fan, which is why they damage
-- segmentation without moving the attendance total.
SELECT
    'A. scans with no ticket identifier'              AS check_name,
    COUNT(*)                                          AS total_scans,
    SUM(CASE WHEN ticket_identifier IS NULL THEN 1 ELSE 0 END)
                                                      AS unattributable,
    ROUND(100.0 * SUM(CASE WHEN ticket_identifier IS NULL THEN 1 ELSE 0 END)
          / COUNT(*), 2)                              AS pct
FROM access_scan;

-- B. Ticket lines with an unclassified status.
-- Not a sale, not a cancellation. `WHERE status = 1` returns a clean-looking
-- number and never mentions these rows.
SELECT
    'B. ticket lines with NULL status'                AS check_name,
    COUNT(*)                                          AS total_lines,
    SUM(CASE WHEN status IS NULL THEN 1 ELSE 0 END)   AS unclassified,
    ROUND(100.0 * SUM(CASE WHEN status IS NULL THEN 1 ELSE 0 END)
          / COUNT(*), 2)                              AS pct
FROM ticket_line;

-- C. Category labels.
-- The commercial world has four ticket categories. The database has more,
-- because the same category is captured in two languages and several casings.
-- Any segmentation grouped on the raw label fragments the audience.
SELECT
    'C. distinct category labels vs real categories'  AS check_name,
    COUNT(DISTINCT category_label)                    AS labels_in_data,
    COUNT(DISTINCT category_canonical)                AS actual_categories
FROM ticket_line;

-- D. Payment dates that will not cast.
-- Free-text datetimes arrive as ISO with Z, ISO with an offset, day-first,
-- with a non-breaking space, or as a zero-date standing in for null.
SELECT
    'D. payment dates failing a naive cast'           AS check_name,
    COUNT(*)                                          AS total_transactions,
    SUM(CASE WHEN DATE(payment_date) IS NULL THEN 1 ELSE 0 END)
                                                      AS uncastable,
    ROUND(100.0 * SUM(CASE WHEN DATE(payment_date) IS NULL THEN 1 ELSE 0 END)
          / COUNT(*), 2)                              AS pct
FROM transactions;

-- E. Cashless spend with no route back to a fan.
-- Revenue reporting is unaffected. Spend-per-fan and lifetime value are.
SELECT
    'E. cashless rows with no order reference'        AS check_name,
    COUNT(*)                                          AS total_rows,
    SUM(CASE WHEN order_reference IS NULL THEN 1 ELSE 0 END)
                                                      AS unattributable,
    ROUND(100.0 * SUM(CASE WHEN order_reference IS NULL THEN 1 ELSE 0 END)
          / COUNT(*), 2)                              AS pct
FROM cashless_transaction;

-- F. Ancillary products sharing the catalogue with match inventory.
-- A volume query filtered on fixture name rather than product type counts
-- parking spaces and vouchers as attendance.
SELECT
    'F. catalogue composition'                        AS check_name,
    product_type,
    COUNT(*)                                          AS products
FROM product_catalogue
GROUP BY product_type
ORDER BY products DESC;

-- G. Tickets that changed hands.
-- Whole-ticket reassignment, plus season seats lent out for a single fixture.
-- In both cases the ticket record still names the purchaser.
SELECT
    'G. transfers and seat shares'                    AS check_name,
    SUM(CASE WHEN product_id IS NULL THEN 1 ELSE 0 END) AS whole_ticket_transfers,
    SUM(CASE WHEN product_id IS NOT NULL THEN 1 ELSE 0 END) AS single_fixture_seat_shares,
    COUNT(*)                                          AS total
FROM ticket_transfer;
