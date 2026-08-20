-- ---------------------------------------------------------------------------
-- 03  IDENTITY RESOLUTION
--
-- Builds the cleaned layer. Nothing reports off the raw tables.
--
-- The resolution chain is:
--
--     access_scan.ticket_identifier
--        -> ticket_line
--        -> ticket_transfer (fixture-scoped share, else whole-ticket transfer)
--        -> effective attendee fan_id
--
-- The important decision is what to do with a scan that has no identifier.
-- It is not discarded, because a person did walk through the turnstile and
-- attendance must still be right. It is retained and marked unattributable,
-- so it counts once toward attendance and never toward a fan's engagement
-- history. Silently dropping it would understate attendance; silently
-- guessing an owner would corrupt segmentation. Both are worse than saying
-- the record exists and cannot be attributed.
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS v_transaction_clean;
DROP VIEW IF EXISTS v_ticket_line_clean;
DROP VIEW IF EXISTS v_scan_resolved;
DROP VIEW IF EXISTS v_fan_fixture_attendance;

-- ---------------------------------------------------------------------------
-- Datetime normalisation.
-- Strips the non-breaking space, treats the zero-date as null, then tries each
-- known encoding in turn and takes the first that parses.
-- ---------------------------------------------------------------------------
CREATE VIEW v_transaction_clean AS
WITH stripped AS (
    SELECT
        transaction_id,
        status,
        price,
        payment_date AS raw_date,
        CASE
            WHEN TRIM(REPLACE(payment_date, CHAR(160), ' ')) = ''            THEN NULL
            WHEN payment_date LIKE '0000-00-00%'                             THEN NULL
            ELSE TRIM(REPLACE(payment_date, CHAR(160), ' '))
        END AS d
    FROM transactions
)
SELECT
    transaction_id,
    status,
    price,
    raw_date,
    COALESCE(
        -- yyyy-mm-dd hh:mm:ss
        CASE WHEN d GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] *'
             THEN DATETIME(d) END,
        -- ISO with a trailing Z
        CASE WHEN d GLOB '*T*Z'
             THEN DATETIME(REPLACE(REPLACE(d, 'T', ' '), 'Z', '')) END,
        -- ISO with a UTC offset
        CASE WHEN d GLOB '*T*+*'
             THEN DATETIME(REPLACE(SUBSTR(d, 1, INSTR(d, '+') - 1), 'T', ' ')) END,
        -- day-first
        CASE WHEN d GLOB '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]*'
             THEN DATETIME(SUBSTR(d, 7, 4) || '-' || SUBSTR(d, 4, 2) || '-'
                           || SUBSTR(d, 1, 2) || ' ' || SUBSTR(d, 12)) END,
        -- yyyy-mm-dd hh:mm, no seconds
        CASE WHEN LENGTH(d) = 16 THEN DATETIME(d || ':00') END
    ) AS payment_at
FROM stripped;

-- ---------------------------------------------------------------------------
-- Ticket lines: canonical category, explicit status vocabulary, and the
-- product type carried through so ancillaries can be excluded deliberately
-- rather than by accident.
-- ---------------------------------------------------------------------------
CREATE VIEW v_ticket_line_clean AS
SELECT
    tl.ticket_line_id,
    tl.transaction_id,
    tl.product_id,
    pc.product_type,
    pc.product_name,
    tl.purchaser_fan_id,
    tl.ticket_identifier,
    tl.price,
    -- Two languages and several casings collapse to one commercial category.
    CASE
        WHEN UPPER(TRIM(tl.category_label)) IN ('ADULT', 'VOLWASSENE', 'ADULTE')      THEN 'Adult'
        WHEN UPPER(TRIM(tl.category_label)) IN ('YOUTH', 'JEUGD', 'JEUNE')            THEN 'Youth'
        WHEN UPPER(TRIM(tl.category_label)) IN ('SENIOR', 'SENIOREN')                 THEN 'Senior'
        WHEN UPPER(TRIM(tl.category_label)) IN ('INVITATION', 'UITNODIGING')          THEN 'Invitation'
        ELSE 'Unmapped'
    END AS category,
    -- A null status is its own state. It is neither counted as a sale nor
    -- thrown away, because somebody has to decide what it is.
    CASE
        WHEN tl.status = 1    THEN 'live'
        WHEN tl.status = 2    THEN 'cancelled'
        WHEN tl.status IS NULL THEN 'unclassified'
        ELSE 'other'
    END AS status_label
FROM ticket_line tl
JOIN product_catalogue pc ON pc.product_id = tl.product_id;

-- ---------------------------------------------------------------------------
-- The resolution itself.
-- A fixture-scoped seat share beats a whole-ticket transfer, which beats the
-- purchaser. A scan with no identifier resolves to no fan and says so.
-- ---------------------------------------------------------------------------
CREATE VIEW v_scan_resolved AS
SELECT
    s.scan_id,
    s.product_id,
    s.gate,
    s.ticket_identifier,
    tl.ticket_line_id,
    tl.purchaser_fan_id,
    COALESCE(share.to_fan_id, whole.to_fan_id, tl.purchaser_fan_id) AS attendee_fan_id,
    CASE
        WHEN s.ticket_identifier IS NULL           THEN 'unattributable_no_identifier'
        WHEN tl.ticket_line_id IS NULL             THEN 'unattributable_orphan_identifier'
        WHEN share.to_fan_id IS NOT NULL           THEN 'resolved_seat_share'
        WHEN whole.to_fan_id IS NOT NULL           THEN 'resolved_transfer'
        ELSE                                            'resolved_purchaser'
    END AS resolution
FROM access_scan s
LEFT JOIN ticket_line tl
       ON tl.ticket_identifier = s.ticket_identifier
LEFT JOIN ticket_transfer share
       ON share.ticket_line_id = tl.ticket_line_id
      AND share.product_id     = s.product_id
LEFT JOIN ticket_transfer whole
       ON whole.ticket_line_id = tl.ticket_line_id
      AND whole.product_id IS NULL;

-- ---------------------------------------------------------------------------
-- One row per fan per fixture they were actually at.
-- This is the grain everything downstream should segment on.
-- ---------------------------------------------------------------------------
CREATE VIEW v_fan_fixture_attendance AS
SELECT DISTINCT
    attendee_fan_id AS fan_id,
    product_id
FROM v_scan_resolved
WHERE attendee_fan_id IS NOT NULL
  AND resolution LIKE 'resolved%';
