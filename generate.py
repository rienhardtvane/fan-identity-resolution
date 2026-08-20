"""
Builds a synthetic season for a mid-size European club and injects the data
defects that actually occur in club ticketing estates.

No real club data is used. Volumes are set to a realistic mid-table top-flight
club: ~4,600 season-ticket holders, ~5,000 single-match tickets per fixture,
~33,000 cashless transactions per fixture, 12 home fixtures.

Every defect injected here mirrors a class of problem found in production
ticketing / access-control / cashless estates:

  D1  scan events arriving with no ticket identifier
  D2  ticket transfers, so the attendee is not the purchaser
  D3  NULL status on ticket lines that a naive filter silently drops
  D4  the same ticket category spelled several ways across two languages
  D5  free-text datetimes with non-breaking spaces, ISO offsets and zero-dates
  D6  ancillary products (parking, vouchers) sharing the catalogue with tickets
  D7  cashless transactions with no order reference back to a fan

Seeded, so every run reproduces the same numbers.
"""

import random
import sqlite3
from datetime import datetime, timedelta

SEED = 20260820
random.seed(SEED)

N_STH = 4600
N_FIXTURES = 12
SINGLE_TICKETS_PER_FIXTURE = 5000
CASHLESS_PER_FIXTURE = 33000

# defect rates
RATE_SCAN_NO_IDENTIFIER = 0.062     # D1
RATE_TICKET_TRANSFERRED = 0.11      # D2
RATE_NULL_STATUS = 0.045            # D3
RATE_CASHLESS_NO_ORDER = 0.084      # D7
RATE_SEAT_SHARED = 0.05             # D2b: share of season seats lent out per fixture

# STH attendance behaviour: most attend most games, a tail rarely attends
STH_ATTEND_PROB = None


def dirty_datetime(dt: datetime, i: int) -> str:
    """D5: return the same instant in one of several messy string encodings."""
    mode = i % 7
    if mode == 0:
        return dt.strftime("%Y-%m-%d %H:%M:%S")
    if mode == 1:
        return dt.strftime("%Y-%m-%d\u00a0%H:%M:%S")          # non-breaking space
    if mode == 2:
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")              # ISO with Z
    if mode == 3:
        return dt.strftime("%Y-%m-%dT%H:%M:%S+02:00")         # ISO with offset
    if mode == 4:
        return dt.strftime("%d/%m/%Y %H:%M:%S")               # day-first
    if mode == 5:
        return dt.strftime("%Y-%m-%d %H:%M")                  # no seconds
    return "0000-00-00 00:00:00"                              # zero-date


# D4: one commercial category, several surface spellings across two languages
CATEGORY_VARIANTS = {
    "Adult":      ["Adult", "adult", "ADULT", "Volwassene", "Volwassene ", "Adulte"],
    "Youth":      ["Youth", "Jeugd", "youth", "Jeune"],
    "Senior":     ["Senior", "Senior ", "Senioren"],
    "Invitation": ["Invitation", "Uitnodiging", "INVITATION", "Invitation "],
}


def pick_category():
    canonical = random.choices(
        list(CATEGORY_VARIANTS), weights=[0.68, 0.14, 0.11, 0.07]
    )[0]
    return canonical, random.choice(CATEGORY_VARIANTS[canonical])


def build(db_path="club.db"):
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.executescript(open("sql/01_schema.sql").read())

    season_start = datetime(2025, 8, 2, 16, 0, 0)

    # ---------- product catalogue (D6: tickets, season tickets and ancillaries together)
    products = []
    SEASON_PRODUCT_ID = 500
    products.append((SEASON_PRODUCT_ID, "Season Ticket 2025-2026", "SeasonTicket",
                     season_start.strftime("%Y-%m-%d %H:%M:%S")))

    fixtures = []
    for f in range(N_FIXTURES):
        pid = 3600 + f * 10
        kickoff = season_start + timedelta(days=14 * f)
        fixtures.append((pid, kickoff))
        products.append((pid, f"Home Fixture {f + 1} 25-26", "Match",
                         kickoff.strftime("%Y-%m-%d %H:%M:%S")))
        # D6: ancillary products sitting in the same catalogue
        products.append((pid + 1, f"Parking Home Fixture {f + 1} 25-26", "Parking",
                         kickoff.strftime("%Y-%m-%d %H:%M:%S")))
        products.append((pid + 2, f"Voucher Home Fixture {f + 1} 25-26", "Voucher",
                         kickoff.strftime("%Y-%m-%d %H:%M:%S")))

    cur.executemany("INSERT INTO product_catalogue VALUES (?,?,?,?)", products)

    # ---------- fans
    fans = []
    for i in range(1, N_STH + 15001):
        fans.append((i, f"fan{i}@example.invalid"))
    cur.executemany("INSERT INTO fan VALUES (?,?)", fans)

    sth_ids = list(range(1, N_STH + 1))
    casual_ids = list(range(N_STH + 1, N_STH + 15001))

    # Per-holder attendance propensity. Real season-ticket bases are not one
    # population: most holders attend most games, and a meaningful minority
    # drift across a season. A single beta gives no lapsing tail and therefore
    # no segment worth building, so this mixes a committed and a drifting group.
    attend_prob = {}
    for fid in sth_ids:
        if random.random() < 0.78:
            attend_prob[fid] = random.betavariate(6, 2)      # committed
        else:
            attend_prob[fid] = random.betavariate(1.1, 4.0)  # drifting

    ticket_lines = []
    transactions = []
    scans = []
    cashless = []

    sth_line_by_fan = {}
    tid = 1
    txn = 1
    scan_id = 1
    cash_id = 1

    # ---------- season tickets: one line per holder
    for fid in sth_ids:
        canonical, surface = pick_category()
        # D3: some lines carry NULL status and are invisible to `WHERE status = 1`
        status = None if random.random() < RATE_NULL_STATUS else 1
        transactions.append((txn, 1, 420.00,
                             dirty_datetime(season_start - timedelta(days=40), txn)))
        ticket_lines.append((tid, txn, SEASON_PRODUCT_ID, "SeasonTicket", status, 1,
                             420.00, fid, surface, canonical,
                             f"s_{fid}_{SEASON_PRODUCT_ID}"))
        sth_line_by_fan[fid] = tid
        tid += 1
        txn += 1

    # ---------- per fixture
    for pid, kickoff in fixtures:
        # single-match tickets
        buyers = random.sample(casual_ids, SINGLE_TICKETS_PER_FIXTURE)
        fixture_lines = []
        for fid in buyers:
            canonical, surface = pick_category()
            status = None if random.random() < RATE_NULL_STATUS else 1
            price = round(random.choice([18.0, 25.0, 32.0, 45.0, 0.0]), 2)
            transactions.append((txn, 1, price,
                                 dirty_datetime(kickoff - timedelta(days=random.randint(1, 30)), txn)))
            ident = f"e_{tid}_{pid}"
            ticket_lines.append((tid, txn, pid, "Match", status, 1, price, fid,
                                 surface, canonical, ident))
            fixture_lines.append((tid, fid, ident, status))
            tid += 1
            txn += 1

        # D2: a share of single tickets is transferred to another fan before the match.
        # The transfer is recorded in its own table. The ticket line still names the buyer.
        for line_id, buyer, ident, status in fixture_lines:
            if random.random() < RATE_TICKET_TRANSFERRED:
                recipient = random.choice(casual_ids)
                if recipient != buyer:
                    cur.execute(
                        "INSERT INTO ticket_transfer VALUES (?,?,?,?,?)",
                        (line_id, None, buyer, recipient,
                         dirty_datetime(kickoff - timedelta(hours=random.randint(2, 72)), line_id)),
                    )

        # scans: season-ticket holders who turned up, plus single-ticket holders
        attending_sth = [fid for fid in sth_ids if random.random() < attend_prob[fid]]

        # D2b: season-seat sharing for this fixture only. The seat is used, the
        # turnstile fires, and the scan carries the season ticket's identifier,
        # so the holder is credited with a visit somebody else made.
        shared_sth = random.sample(sth_ids, int(N_STH * RATE_SEAT_SHARED))
        for fid in shared_sth:
            recipient = random.choice(casual_ids)
            cur.execute(
                "INSERT INTO ticket_transfer VALUES (?,?,?,?,?)",
                (sth_line_by_fan[fid], pid, fid, recipient,
                 dirty_datetime(kickoff - timedelta(hours=random.randint(2, 72)), fid)),
            )
        attending_sth = sorted(set(attending_sth) | set(shared_sth))
        for fid in attending_sth:
            ident = f"s_{fid}_{SEASON_PRODUCT_ID}"
            # D1: a share of scan events arrives with no ticket identifier at all
            if random.random() < RATE_SCAN_NO_IDENTIFIER:
                ident_out = None
            else:
                ident_out = ident
            scans.append((scan_id, pid, ident_out,
                          dirty_datetime(kickoff - timedelta(minutes=random.randint(5, 90)), scan_id),
                          random.choice(["N1", "N2", "S1", "S2", "E1", "W1"])))
            scan_id += 1

        for line_id, buyer, ident, status in fixture_lines:
            if random.random() < 0.88:
                ident_out = None if random.random() < RATE_SCAN_NO_IDENTIFIER else ident
                scans.append((scan_id, pid, ident_out,
                              dirty_datetime(kickoff - timedelta(minutes=random.randint(5, 90)), scan_id),
                              random.choice(["N1", "N2", "S1", "S2", "E1", "W1"])))
                scan_id += 1

        # cashless spend
        attendee_pool = attending_sth + [b for _, b, _, _ in fixture_lines]
        for _ in range(CASHLESS_PER_FIXTURE):
            fid = random.choice(attendee_pool)
            value_cents = random.choice([350, 450, 500, 650, 800, 1200])
            # D7: a share of cashless rows has no order reference back to a fan
            order_ref = None if random.random() < RATE_CASHLESS_NO_ORDER else f"o_{fid}_{pid}"
            cashless.append((cash_id, pid, order_ref, "V", "withdraw", value_cents,
                             dirty_datetime(kickoff + timedelta(minutes=random.randint(0, 110)), cash_id)))
            cash_id += 1

    cur.executemany("INSERT INTO transactions VALUES (?,?,?,?)", transactions)
    cur.executemany("INSERT INTO ticket_line VALUES (?,?,?,?,?,?,?,?,?,?,?)", ticket_lines)
    cur.executemany("INSERT INTO access_scan VALUES (?,?,?,?,?)", scans)
    cur.executemany("INSERT INTO cashless_transaction VALUES (?,?,?,?,?,?,?)", cashless)

    con.commit()
    con.close()
    return {
        "ticket_lines": len(ticket_lines),
        "scans": len(scans),
        "cashless": len(cashless),
        "fixtures": N_FIXTURES,
    }


if __name__ == "__main__":
    print(build())
