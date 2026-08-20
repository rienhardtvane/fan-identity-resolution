# Fan identity resolution on a club ticketing estate

A working demonstration of what happens to marketing segmentation when ticketing, access control and cashless payment data do not resolve to the same fan, and of which half of that problem can be fixed downstream.

Built on synthetic data. No club's data is used anywhere in this repository.

```
python3 run.py
```

No installation. SQLite ships with Python, so the whole thing runs on a standard interpreter and finishes in under a minute.

---

## Why this exists

I spent a season club-side reconciling a ticketing system, a CRM, an access-control feed and a cashless payment platform that disagreed with each other. The commercially important numbers were usually right. The fan record underneath them frequently was not, and nothing in the reporting layer said so.

That failure mode is hard to describe in a cover letter, because the symptom is that nothing looks wrong. So this rebuilds it from scratch, with the defects injected deliberately at known rates, and measures what they cost.

## What is modelled

A season for a mid-size top-flight club: 4,600 season-ticket holders, twelve home fixtures, roughly 5,000 single-match tickets and 33,000 cashless transactions per fixture. Around 64,600 ticket lines, 88,500 turnstile events and 396,000 payment rows.

Five systems that hold no reference to each other, which is the ordinary condition of a club estate rather than an unusual one.

Seven defects, each a class of problem that occurs in production:

| | Defect | Rate |
|---|---|---|
| D1 | Turnstile events arriving with no ticket identifier | 6.1% of scans |
| D2 | Tickets transferred, so the attendee is not the purchaser | 11% of single tickets |
| D2b | Season seats lent out for one fixture, scan still carries the holder's identifier | 5% per fixture |
| D3 | Ticket lines with an unclassified status, invisible to `WHERE status = 1` | 4.3% of lines |
| D4 | One commercial category captured under seventeen surface labels across two languages | 17 labels, 4 categories |
| D5 | Free-text datetimes: non-breaking spaces, ISO offsets, day-first, zero-dates | 42.9% fail a naive cast |
| D6 | Parking and vouchers sharing the catalogue with match inventory | 24 of 37 products |
| D7 | Cashless rows with no order reference back to a fan | 8.4% of rows |

## What the resolution does

```
access_scan.ticket_identifier
   -> ticket_line
   -> ticket_transfer  (fixture-scoped seat share, else whole-ticket transfer)
   -> effective attendee
```

A fixture-scoped share beats a whole-ticket transfer, which beats the purchaser.

The decision that matters is what to do with a scan carrying no identifier. It is not discarded, because a person did come through the turnstile and attendance has to stay right. It is not assigned a probable owner either. It is retained and marked unattributable, so it counts once toward attendance and never toward anyone's engagement history. Dropping it understates attendance. Guessing at an owner corrupts segmentation. Saying plainly that the record exists and cannot be attributed is the only defensible option.

## The result

A renewal campaign targets season-ticket holders with no attendance across the last four home fixtures. Built against the raw tables, and then against the resolved layer:

| | Naive | Resolved |
|---|---|---|
| Holders in the lapsed segment | 470 | 602 |

**132 holders, 21.9% of the true segment, are invisible to the naive query.** They have genuinely stopped attending. Their seats were used by someone else, the turnstile fired, the scan carried the season ticket's identifier, and the visit was credited back to them. They look engaged. They are the holders least likely to renew and they never receive the campaign built to retain them.

That part the resolved layer fixes.

**1,777 scans in the same four-fixture window, 6% of all attendance, carry no identifier and cannot be attributed by any query.** Those are visits that happened, to people who are now carrying an understated engagement record for the rest of the season. No amount of downstream SQL recovers them, because the information was never captured. The only place that error can be addressed is at the point of capture, before the event is written.

The second finding is the more expensive one, and it is the one that looks like nothing. Aggregate attendance is unaffected. Revenue reconciles. Every dashboard agrees with every other dashboard. That is precisely why it survives.

## Files

```
run.py                        end to end, prints the report
generate.py                   synthetic season and defect injection, seeded
sql/01_schema.sql             five systems that do not know about each other
sql/02_defect_audit.sql       quantify the damage before touching it
sql/03_identity_resolution.sql  cleaned layer and the resolution chain
sql/04_segment_impact.sql     what resolution fixes, and what it cannot
```

Seeded at 20260820, so every run reproduces the same figures.

## What this is not

The resolution chain here is deterministic: an identifier either joins or it does not. Production identity resolution across a CDP involves probabilistic matching, household logic and consent boundaries, none of which is modelled. The point of the exercise is the failure mode and its commercial consequence, not a complete matching engine.

Rienhardt van Eeden
