-- ---------------------------------------------------------------------------
-- 04  SEGMENT IMPACT
--
-- The point of the exercise. A renewal campaign targets season-ticket holders
-- who have stopped turning up, on the reasonable theory that a holder who has
-- not attended lately is a holder who will not renew.
--
-- The segment definition is recency based, which is how these campaigns are
-- actually written: no attendance across the last four home fixtures. A
-- whole-season definition would be almost empty and would hide the problem,
-- because a holder only has to appear once in nine months to escape it.
--
-- Two versions of that segment are built below.
--
--   naive     joins scans straight to the ticket record and credits the
--             purchaser, which is what a query written against the raw tables
--             does by default
--
--   resolved  runs the resolution chain: seat shares and transfers move the
--             visit to whoever actually used the ticket, and scans with no
--             identifier are excluded from attribution rather than guessed
--
-- Two separate findings come out of this, and they need different responses.
--
--   Query A  the transfer and seat-share error, which resolution fixes.
--            Holders who have genuinely stopped attending look engaged,
--            because somebody else used their seat and the visit was credited
--            back to them. They are invisible to the naive segment.
--
--   Query B  the missing-identifier error, which resolution does not fix and
--            cannot fix. A scan with no identifier is unattributable to the
--            naive query and to the resolved one alike. The information was
--            never captured, so there is nothing downstream to recover. The
--            only available fix is upstream, at the point of capture.
--
-- The second finding is the more important one, because it is the one that
-- looks like nothing. Aggregate attendance is unaffected, every dashboard
-- reconciles, and a share of the fanbase quietly carries an understated
-- engagement history for the rest of the season.
-- ---------------------------------------------------------------------------

-- ======================= QUERY A: what resolution fixes ====================

WITH recent_fixtures AS (
    -- the last four home fixtures of the season
    SELECT product_id
    FROM product_catalogue
    WHERE product_type = 'Match'
    ORDER BY product_date DESC
    LIMIT 4
),

season_holders AS (
    SELECT DISTINCT purchaser_fan_id AS fan_id, ticket_line_id, ticket_identifier
    FROM v_ticket_line_clean
    WHERE product_type = 'SeasonTicket'
),

-- Naive: every scan is credited to whoever bought the ticket.
naive_attendance AS (
    SELECT sh.fan_id, COUNT(DISTINCT s.product_id) AS fixtures_attended
    FROM season_holders sh
    LEFT JOIN access_scan s
           ON s.ticket_identifier = sh.ticket_identifier
          AND s.product_id IN (SELECT product_id FROM recent_fixtures)
    GROUP BY sh.fan_id
),

-- Resolved: seat shares and transfers reassign the visit, unidentified scans
-- are not attributed to anyone.
resolved_attendance AS (
    SELECT sh.fan_id, COUNT(DISTINCT a.product_id) AS fixtures_attended
    FROM season_holders sh
    LEFT JOIN v_fan_fixture_attendance a
           ON a.fan_id = sh.fan_id
          AND a.product_id IN (SELECT product_id FROM recent_fixtures)
    GROUP BY sh.fan_id
),

compared AS (
    SELECT
        n.fan_id,
        n.fixtures_attended AS naive_fixtures,
        r.fixtures_attended AS resolved_fixtures,
        CASE WHEN n.fixtures_attended = 0 THEN 1 ELSE 0 END AS in_naive_segment,
        CASE WHEN r.fixtures_attended = 0 THEN 1 ELSE 0 END AS in_resolved_segment
    FROM naive_attendance n
    JOIN resolved_attendance r ON r.fan_id = n.fan_id
)

SELECT
    SUM(in_naive_segment)                                      AS naive_segment_size,
    SUM(in_resolved_segment)                                   AS resolved_segment_size,

    -- Genuinely disengaged, and the naive segment misses them, because
    -- somebody else used their seat and the visit was credited back to them.
    -- These are holders at real risk of not renewing who never receive the
    -- campaign built to retain them.
    SUM(CASE WHEN in_naive_segment = 0 AND in_resolved_segment = 1
             THEN 1 ELSE 0 END)                                AS missed_by_naive,

    ROUND(100.0 * SUM(CASE WHEN in_naive_segment = 0 AND in_resolved_segment = 1 THEN 1 ELSE 0 END)
          / NULLIF(SUM(in_resolved_segment), 0), 1)            AS pct_of_true_segment_missed
FROM compared;


-- ============ QUERY B: what resolution cannot fix, and never will ==========
--
-- Season-ticket holders with at least one scan in the campaign window that
-- carried no identifier. Each of these is a visit that happened and that no
-- query will ever attribute. Their engagement history is understated, the
-- understatement is permanent, and nothing in the reporting layer flags it.

WITH recent_fixtures AS (
    SELECT product_id
    FROM product_catalogue
    WHERE product_type = 'Match'
    ORDER BY product_date DESC
    LIMIT 4
)
SELECT
    COUNT(*)                                          AS unattributable_scans_in_window,
    (SELECT COUNT(*) FROM access_scan s2
      WHERE s2.product_id IN (SELECT product_id FROM recent_fixtures))
                                                      AS total_scans_in_window,
    ROUND(100.0 * COUNT(*) /
          (SELECT COUNT(*) FROM access_scan s3
            WHERE s3.product_id IN (SELECT product_id FROM recent_fixtures)), 2)
                                                      AS pct_of_window
FROM access_scan s
WHERE s.product_id IN (SELECT product_id FROM recent_fixtures)
  AND s.ticket_identifier IS NULL;
