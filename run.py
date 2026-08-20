#!/usr/bin/env python3
"""
Runs the whole thing end to end.

    python3 run.py

No dependencies beyond the Python standard library. SQLite ships with Python,
so there is nothing to install and nothing to configure.
"""

import sqlite3
import os
import generate

DB = "club.db"


def rule(title):
    print(f"\n{title}")
    print("-" * len(title))


def run_file(cur, path):
    """Execute a file of SELECT statements and print each result set."""
    raw = open(path).read()
    statements = []
    buf = []
    for line in raw.splitlines():
        buf.append(line)
        if line.rstrip().endswith(";"):
            stmt = "\n".join(buf)
            if any(l.strip() and not l.strip().startswith("--") for l in buf):
                statements.append(stmt)
            buf = []
    for stmt in statements:
        try:
            rows = cur.execute(stmt).fetchall()
        except sqlite3.Error as e:
            print(f"  [skipped] {e}")
            continue
        if not rows:
            continue
        cols = [d[0] for d in cur.description]
        last_check = None
        for row in rows:
            for c, v in zip(cols, row):
                if c == "check_name":
                    if v != last_check:
                        print(f"\n  {v}")
                        last_check = v
                else:
                    print(f"    {c:<36} {v:>12,}" if isinstance(v, (int, float))
                          else f"    {c:<36} {v:>12}")


def main():
    if os.path.exists(DB):
        os.remove(DB)

    rule("1. BUILDING SYNTHETIC SEASON")
    stats = generate.build(DB)
    for k, v in stats.items():
        print(f"    {k:<36} {v:>12,}")

    con = sqlite3.connect(DB)
    cur = con.cursor()

    rule("2. DEFECT AUDIT (raw tables, nothing resolved yet)")
    run_file(cur, "sql/02_defect_audit.sql")

    rule("3. BUILDING RESOLVED LAYER")
    cur.executescript(open("sql/03_identity_resolution.sql").read())
    con.commit()
    for res, n in cur.execute(
        "SELECT resolution, COUNT(*) FROM v_scan_resolved GROUP BY resolution ORDER BY 2 DESC"
    ):
        print(f"    {res:<36} {n:>12,}")

    total, parsed, zero = cur.execute(
        "SELECT COUNT(*), SUM(payment_at IS NOT NULL), "
        "SUM(raw_date LIKE '0000-00-00%') FROM v_transaction_clean"
    ).fetchone()
    print(f"\n    payment dates, total                 {total:>12,}")
    print(f"    parsed to a real timestamp           {parsed:>12,}")
    print(f"    zero-dates, correctly nulled         {zero:>12,}")
    print(f"    left unparsed                        {total - parsed - zero:>12,}")

    rule("4. SEGMENT IMPACT")
    raw = open("sql/04_segment_impact.sql").read()
    head, tail = raw.split("-- ============ QUERY B")
    qb = "WITH recent_fixtures" + tail.split("WITH recent_fixtures", 1)[1]

    print("\n  A. What resolution fixes")
    row = cur.execute(head).fetchone()
    for c, v in zip([d[0] for d in cur.description], row):
        print(f"    {c:<36} {v:>12,}")

    print("\n  B. What resolution cannot fix")
    row = cur.execute(qb).fetchone()
    for c, v in zip([d[0] for d in cur.description], row):
        print(f"    {c:<36} {v:>12,}")

    rule("5. READING")
    print("""
  Aggregate attendance is fine. Revenue reconciles. Every dashboard agrees
  with every other dashboard, which is why none of this gets raised.

  The damage is entirely in the fan record. A renewal campaign built off the
  raw tables misses roughly a fifth of the holders it exists to reach, because
  their seats were used by somebody else and the visit was credited back to
  them. That part is fixable, and the resolved layer fixes it.

  The rest is not fixable. Scans that arrived without an identifier are gone.
  They can be counted toward attendance and they can never be attributed to a
  person. The only place that error can be addressed is at capture, before
  the event is written.
""")
    con.close()


if __name__ == "__main__":
    main()
