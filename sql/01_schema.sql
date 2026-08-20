-- Five systems that do not know about each other, which is the normal state
-- of a club ticketing estate rather than an unusual one.

DROP TABLE IF EXISTS product_catalogue;
DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS ticket_line;
DROP TABLE IF EXISTS ticket_transfer;
DROP TABLE IF EXISTS access_scan;
DROP TABLE IF EXISTS cashless_transaction;
DROP TABLE IF EXISTS fan;

-- Ticketing system: what is for sale.
-- Match tickets, season tickets, parking and vouchers all live here together,
-- so any revenue or volume query that filters on fixture name rather than
-- product type silently mixes inventory with ancillaries.
CREATE TABLE product_catalogue (
    product_id      INTEGER PRIMARY KEY,
    product_name    TEXT NOT NULL,
    product_type    TEXT NOT NULL,   -- Match | SeasonTicket | Parking | Voucher
    product_date    TEXT NOT NULL
);

-- Ticketing system: the payment envelope.
-- payment_date is free text and arrives in several encodings.
CREATE TABLE transactions (
    transaction_id  INTEGER PRIMARY KEY,
    status          INTEGER,
    price           REAL,
    payment_date    TEXT
);

-- Ticketing system: one row per ticket sold.
-- status is nullable. A null is not a cancellation and it is not a sale;
-- it is an unclassified record, and it is invisible to `WHERE status = 1`.
CREATE TABLE ticket_line (
    ticket_line_id      INTEGER PRIMARY KEY,
    transaction_id      INTEGER,
    product_id          INTEGER,
    product_type        TEXT,
    status              INTEGER,          -- 1 = live, 2 = cancelled, NULL = unclassified
    operation           INTEGER,
    price               REAL,
    purchaser_fan_id    INTEGER,
    category_label      TEXT,             -- as captured, in whichever language
    category_canonical  TEXT,             -- ground truth, for scoring only
    ticket_identifier   TEXT
);

-- Ticketing system: transfers and shares.
-- The ticket_line still names the purchaser. The person who walks through
-- the turnstile is whoever holds the ticket at kick-off.
CREATE TABLE ticket_transfer (
    ticket_line_id      INTEGER,
    product_id          INTEGER,   -- NULL = whole ticket reassigned
                                   -- populated = seat shared for one fixture only
    from_fan_id         INTEGER,
    to_fan_id           INTEGER,
    transferred_at      TEXT
);

-- Access control: one row per turnstile event.
-- ticket_identifier is the only link back to ticketing, and it is not always
-- populated, because the webhook that carries it can fire without it.
CREATE TABLE access_scan (
    scan_id             INTEGER PRIMARY KEY,
    product_id          INTEGER,
    ticket_identifier   TEXT,             -- nullable: this is the whole problem
    scanned_at          TEXT,
    gate                TEXT
);

-- Cashless payment: concessions and retail spend inside the ground.
-- order_reference is the only route back to a fan and it is not always present.
CREATE TABLE cashless_transaction (
    cashless_id         INTEGER PRIMARY KEY,
    product_id          INTEGER,
    order_reference     TEXT,             -- nullable
    status              TEXT,
    action              TEXT,
    value_cents         INTEGER,
    occurred_at         TEXT
);

-- CRM: the fan record everything is supposed to resolve to.
CREATE TABLE fan (
    fan_id      INTEGER PRIMARY KEY,
    email       TEXT
);
