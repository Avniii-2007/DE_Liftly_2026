-- =====================================================================
-- Zomato Food Delivery Database: partitioning for 100x growth (Phase 5)
--
-- Run AFTER sql/01_schema.sql, sql/02_load_data.sql (or the large_data
-- equivalent) and sql/05_indexes.sql:
--
--   createdb zomato_partitioned
--   psql -d zomato_partitioned -v ON_ERROR_STOP=1 \
--        -f sql/01_schema.sql -f sql/02_load_data.sql \
--        -f sql/05_indexes.sql  -f sql/08_partitioning.sql
--
-- WHAT THIS DOES
--   Replaces the single heap `orders` table with a RANGE-partitioned table
--   keyed on `placed_at` (one partition per calendar month, plus a DEFAULT
--   partition for rows outside the month list). Every row and every index
--   from Phase 4 is preserved, so the 30 queries do not change.
--
-- WHY orders, AND WHY RANGE(placed_at)
--   * orders is the largest table (357 MB heap / 754 MB index at 3M rows) and
--     it is the only table every hot query touches.
--   * 26 of the 30 queries filter on a time window (last 7 days, a single
--     day, May 2026, last 8 weeks, 2026). RANGE on placed_at lets the planner
--     prune whole months: R10 (June 2026) reads 1 of 25 partitions instead of
--     the whole table.
--   * Old months are the natural archive unit: `DETACH PARTITION` moves a
--     month to cheap storage, and `DROP PARTITION` deletes it instantly with
--     no VACUUM debt. LIST(month) is the same idea but needs one DDL per month
--     anyway; RANGE is the idiomatic form and supports a DEFAULT partition.
--   * HASH(order_id) would split writes evenly but would make every date-range
--     query read every partition, which is the opposite of what this workload
--     needs. Partitioning by status/city would create skew (DELIVERED and
--     Bengaluru dominate).
--
-- PRIMARY-KEY RULE FOR PARTITIONED TABLES (important)
--   PostgreSQL requires every UNIQUE / PRIMARY KEY constraint on a partitioned
--   table to contain the partition key. A primary key on (order_id) alone is
--   therefore rejected. We use PRIMARY KEY (order_id, placed_at), which is
--   still unique because order_id is allocated by one global sequence, and it
--   also gives each partition a usable index for `WHERE order_id = ...`.
--   Consequence: `order_items`, `payments` and `reviews` cannot reference a
--   composite key with only order_id, so their foreign keys are dropped here.
--   Global order_id uniqueness and orphan prevention move to the ingestion
--   path (the same single writer that allocates order_id) or to a trigger.
--   This is the documented cost of partitioning; it is a 100x-architecture
--   choice, not something to apply to the 150k seed database.
--
-- IDENTITY / IDS
--   No ids are generated here; rows are copied as-is. In production the
--   sequence that allocates order_id must stay global across partitions.
-- =====================================================================

\set ON_ERROR_STOP on
BEGIN;

SET LOCAL search_path TO zomato;
SET LOCAL maintenance_work_mem = '1GB';
SET LOCAL synchronous_commit = off;

-- ---------------------------------------------------------------------
-- 1. Children can no longer hold a single-column FK to the compositely
--    keyed partitioned parent (see the primary-key rule above).
-- ---------------------------------------------------------------------
ALTER TABLE order_items DROP CONSTRAINT IF EXISTS order_items_order_id_fkey;
ALTER TABLE payments    DROP CONSTRAINT IF EXISTS payments_order_id_fkey;
ALTER TABLE reviews     DROP CONSTRAINT IF EXISTS reviews_order_id_fkey;

-- ---------------------------------------------------------------------
-- 2. Move the heap table aside (same columns, same CHECK constraints).
-- ---------------------------------------------------------------------
ALTER TABLE orders RENAME TO orders_unpartitioned;
ALTER TABLE orders_unpartitioned RENAME CONSTRAINT orders_pkey TO orders_unpartitioned_pkey;

-- ---------------------------------------------------------------------
-- 3. Partitioned parent: identical columns and CHECK constraints to
--    sql/01_schema.sql, plus PARTITION BY RANGE (placed_at).
-- ---------------------------------------------------------------------
CREATE TABLE orders (
    order_id       INTEGER       NOT NULL,
    customer_id    INTEGER       NOT NULL REFERENCES customers(customer_id)     ON DELETE RESTRICT,
    restaurant_id  INTEGER       NOT NULL REFERENCES restaurants(restaurant_id) ON DELETE RESTRICT,
    partner_id     INTEGER       REFERENCES delivery_partners(partner_id)       ON DELETE RESTRICT,
    coupon_code    VARCHAR(20)   REFERENCES coupons(coupon_code)                ON DELETE RESTRICT,
    placed_at      TIMESTAMPTZ   NOT NULL,
    accepted_at    TIMESTAMPTZ,
    picked_up_at   TIMESTAMPTZ,
    delivered_at   TIMESTAMPTZ,
    distance_km    NUMERIC(4,1)  NOT NULL,
    item_total     NUMERIC(10,2) NOT NULL,
    delivery_fee   NUMERIC(10,2) NOT NULL,
    discount       NUMERIC(10,2) NOT NULL DEFAULT 0,
    total_amount   NUMERIC(10,2) NOT NULL,
    status         VARCHAR(30)   NOT NULL,

    CONSTRAINT chk_orders_status CHECK (status IN
        ('PLACED', 'ACCEPTED', 'PREPARING', 'OUT_FOR_DELIVERY', 'DELIVERED',
         'CANCELLED_BY_CUSTOMER', 'CANCELLED_BY_RESTAURANT')),
    CONSTRAINT chk_orders_distance  CHECK (distance_km > 0),
    CONSTRAINT chk_orders_amounts   CHECK (item_total > 0 AND delivery_fee >= 0 AND discount >= 0),
    CONSTRAINT chk_orders_total     CHECK (total_amount = item_total + delivery_fee - discount),
    CONSTRAINT chk_orders_t_accept  CHECK (accepted_at  IS NULL OR accepted_at  >= placed_at),
    CONSTRAINT chk_orders_t_pickup  CHECK (picked_up_at IS NULL OR (accepted_at IS NOT NULL AND picked_up_at >= accepted_at)),
    CONSTRAINT chk_orders_t_deliver CHECK (delivered_at IS NULL OR (picked_up_at IS NOT NULL AND delivered_at >= picked_up_at)),
    CONSTRAINT chk_orders_delivered CHECK (status <> 'DELIVERED' OR
        (partner_id IS NOT NULL AND accepted_at IS NOT NULL AND picked_up_at IS NOT NULL AND delivered_at IS NOT NULL)),
    CONSTRAINT chk_orders_ofd       CHECK (status <> 'OUT_FOR_DELIVERY' OR
        (partner_id IS NOT NULL AND picked_up_at IS NOT NULL AND delivered_at IS NULL)),
    CONSTRAINT chk_orders_preparing CHECK (status <> 'PREPARING' OR
        (partner_id IS NOT NULL AND accepted_at IS NOT NULL AND picked_up_at IS NULL)),
    CONSTRAINT chk_orders_accepted  CHECK (status <> 'ACCEPTED' OR (accepted_at IS NOT NULL AND picked_up_at IS NULL)),
    CONSTRAINT chk_orders_fresh     CHECK (status NOT IN ('PLACED', 'CANCELLED_BY_RESTAURANT') OR
        (partner_id IS NULL AND accepted_at IS NULL AND picked_up_at IS NULL AND delivered_at IS NULL)),
    CONSTRAINT chk_orders_deliv_only CHECK (delivered_at IS NULL OR status = 'DELIVERED'),

    -- the partition key must be part of every unique constraint
    CONSTRAINT orders_pkey PRIMARY KEY (order_id, placed_at)
) PARTITION BY RANGE (placed_at);

-- Catch-all for rows outside the month list (late inserts, clock skew).
-- Keep it, but move rows into their month with a detach/attach cycle when it
-- grows: a large DEFAULT partition forces every new partition creation to
-- scan it.
CREATE TABLE orders_default PARTITION OF orders DEFAULT;

-- ---------------------------------------------------------------------
-- 4. One partition per month, sized for the seed + large data range
--    (2025-01-01 .. 2026-06-30) and room for next year's growth.
--    An empty month costs a few kB and no rows.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    m date;
BEGIN
    FOR m IN SELECT generate_series('2025-01-01'::date, '2026-12-01'::date, '1 month')::date
    LOOP
        EXECUTE format(
            'CREATE TABLE orders_%s PARTITION OF orders FOR VALUES FROM (%L) TO (%L)',
            to_char(m, 'YYYY_MM'), m, m + interval '1 month');
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 5. Move all rows, then drop the old heap.
-- ---------------------------------------------------------------------
INSERT INTO orders SELECT * FROM orders_unpartitioned;
DROP TABLE orders_unpartitioned;

-- ---------------------------------------------------------------------
-- 6. Recreate every Phase 4 index on the partitioned parent. PostgreSQL
--    creates the matching index on each partition, and the planner uses
--    the parent index in EXPLAIN while pruning.
-- ---------------------------------------------------------------------
CREATE INDEX idx_orders_customer_placed
    ON orders (customer_id, placed_at DESC)
    INCLUDE (status, total_amount);

CREATE INDEX idx_orders_restaurant_placed
    ON orders (restaurant_id, placed_at DESC)
    INCLUDE (status, item_total, order_id);

CREATE INDEX idx_orders_placed_desc
    ON orders (placed_at DESC, order_id DESC)
    INCLUDE (customer_id, restaurant_id, status, delivered_at);

CREATE INDEX idx_orders_partner_placed
    ON orders (partner_id, placed_at DESC)
    INCLUDE (status, delivery_fee)
    WHERE partner_id IS NOT NULL;

CREATE INDEX idx_orders_preparing_accepted
    ON orders (accepted_at)
    INCLUDE (order_id, restaurant_id)
    WHERE status = 'PREPARING';

CREATE INDEX idx_orders_unassigned_dispatch
    ON orders (placed_at)
    INCLUDE (order_id, restaurant_id, status)
    WHERE partner_id IS NULL AND status IN ('PLACED', 'ACCEPTED');

CREATE INDEX idx_orders_coupon_delivered
    ON orders (coupon_code)
    INCLUDE (order_id, discount, total_amount)
    WHERE status = 'DELIVERED' AND coupon_code IS NOT NULL;

ANALYZE orders;

COMMIT;

-- ---------------------------------------------------------------------
-- VERIFICATION (run by hand)
-- ---------------------------------------------------------------------
-- Row counts must be identical before and after:
--   SELECT count(*) FROM orders;
--
-- Partition pruning: this plan must list ONLY orders_2026_06, not 25 children.
--   EXPLAIN (ANALYZE, BUFFERS)
--   SELECT order_id, customer_id, restaurant_id, placed_at, delivered_at
--   FROM orders
--   WHERE delivered_at - placed_at > interval '60 minutes'
--     AND placed_at >= '2026-06-01' AND placed_at < '2026-07-01'
--   ORDER BY delivered_at - placed_at DESC
--   LIMIT 100;
--
-- Creating next year's partition (do it ahead of the month, in a maintenance
-- window; ATTACH still takes a brief lock on the parent):
--   CREATE TABLE orders_2027_01 PARTITION OF orders
--       FOR VALUES FROM ('2027-01-01') TO ('2027-02-01');
--
-- Archiving a finished month (no rewrite, no VACUUM):
--   ALTER TABLE orders DETACH PARTITION orders_2025_01;
--
-- plan-time pruning happens without PREPARE; for a prepared statement use
-- PREPARE ... then EXECUTE with a parameter and enable plan-time pruning.
