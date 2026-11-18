-- =====================================================================
-- Zomato Food Delivery Database: Indexes (Phase 4)
-- Run after sql/01_schema.sql and sql/02_load_data.sql:
--   psql -d zomato_db -f sql/05_indexes.sql
--
-- Every index below is justified with:
--   * Which queries it serves
--   * Why this index type (B-tree, partial, covering/INCLUDE, GIN)
--   * Why this column order (equality columns first, range/sort columns next)
-- =====================================================================

-- Enable trigram extension for substring ILIKE '%...%' queries (R02, R18).
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

SET search_path TO zomato, public;

-- ---------------------------------------------------------------------
-- 1. localities
-- ---------------------------------------------------------------------

-- Serves: R01 (lookup locality_id by locality_name = 'Koramangala')
-- Type & order: Covering B-tree on (locality_name) INCLUDE (locality_id).
-- The existing UNIQUE constraint is on (city_id, locality_name), whose leading
-- column is city_id, so lookups by locality_name alone cannot use it.
CREATE INDEX IF NOT EXISTS idx_localities_name
    ON localities (locality_name)
    INCLUDE (locality_id);

-- ---------------------------------------------------------------------
-- 2. restaurants
-- ---------------------------------------------------------------------

-- Serves: R01 (open restaurants in a locality sorted by rating DESC NULLS LAST),
--         R25 (open restaurants in Pune localities sorted by rating DESC NULLS LAST)
-- Type & order: Partial B-tree on (locality_id, rating DESC NULLS LAST) WHERE status = 'OPEN'.
-- Equality column (locality_id) comes first, followed by the exact ORDER BY key
-- (rating DESC NULLS LAST) so PostgreSQL avoids sorting. Partial predicate excludes
-- TEMPORARILY_CLOSED and DELISTED restaurants.
CREATE INDEX IF NOT EXISTS idx_restaurants_locality_open_rating
    ON restaurants (locality_id, rating DESC NULLS LAST)
    WHERE status = 'OPEN';

-- Serves: R02, R08, R19, R22 (join localities -> restaurants by locality_id across all statuses)
-- Type & order: Covering B-tree on (locality_id) INCLUDE (restaurant_id, name).
-- These queries do not filter status = 'OPEN', so they cannot use the partial index above.
-- Including (restaurant_id, name) enables Index Only Scans without touching the heap,
-- and omitting rating avoids write overhead during W04.
CREATE INDEX IF NOT EXISTS idx_restaurants_locality
    ON restaurants (locality_id)
    INCLUDE (restaurant_id, name);

-- Serves: R25 (open restaurants serving a specific cuisine via cuisines @> ARRAY['Chinese'])
-- Type & order: Partial GIN index on TEXT[] column cuisines WHERE status = 'OPEN'.
-- B-tree cannot index elements inside an array; GIN indexes each cuisine element so
-- array containment (@>) works in O(matches) and scales cleanly at 20x volume.
CREATE INDEX IF NOT EXISTS idx_restaurants_cuisines_gin
    ON restaurants USING gin (cuisines)
    WHERE status = 'OPEN';

-- ---------------------------------------------------------------------
-- 3. menu_items
-- ---------------------------------------------------------------------

-- Serves: R02 (type-ahead dish search: item_name ILIKE '%paneer%' AND is_available)
-- Type & order: Partial GIN trigram index (gin_trgm_ops) on item_name WHERE is_available.
-- Leading-wildcard ILIKE '%...%' cannot use a B-tree; pg_trgm breaks item_name into
-- 3-character trigrams so GIN finds candidate rows directly. Partial predicate skips
-- unavailable dishes.
CREATE INDEX IF NOT EXISTS idx_menu_items_name_trgm
    ON menu_items USING gin (item_name gin_trgm_ops)
    WHERE is_available;

-- Serves: R03 (restaurant menu page filtered by restaurant_id & is_available, ordered by
--              category, is_bestseller DESC, item_name),
--         W03 (UPDATE menu_items WHERE restaurant_id = 217 AND category = 'Desserts')
-- Type & order: Covering B-tree on (restaurant_id, category, is_bestseller DESC, item_name)
-- INCLUDE (price, is_veg, is_available).
-- Leading (restaurant_id, category) gives W03 a direct Index Scan and lets R03 read a
-- restaurant's menu in exact display order via an Index Only Scan with no Sort node.
CREATE INDEX IF NOT EXISTS idx_menu_items_rest_cat
    ON menu_items (restaurant_id, category, is_bestseller DESC, item_name)
    INCLUDE (price, is_veg, is_available);

-- ---------------------------------------------------------------------
-- 4. customers
-- ---------------------------------------------------------------------

-- Serves: R14 (expiring Gold members who ordered in June),
--         W05 (nightly job ending expired Gold memberships)
-- Type & order: Partial covering B-tree on (gold_expires_on) INCLUDE (customer_id, full_name)
-- WHERE is_gold_member.
-- Only ~15% of customers are Gold members; the partial index is small, matches the exact
-- range filter (gold_expires_on < '2026-07-01'), and gives R14 an Index Only Scan.
CREATE INDEX IF NOT EXISTS idx_customers_gold_expires
    ON customers (gold_expires_on)
    INCLUDE (customer_id, full_name)
    WHERE is_gold_member;

-- Serves: R20 (top 20 Mumbai customers by lifetime spend)
-- Type & order: Covering B-tree on (city_id) INCLUDE (customer_id, full_name).
-- Equality filter on city_id returns Mumbai's customers via an Index Only Scan.
CREATE INDEX IF NOT EXISTS idx_customers_city
    ON customers (city_id)
    INCLUDE (customer_id, full_name);

-- ---------------------------------------------------------------------
-- 5. delivery_partners
-- ---------------------------------------------------------------------

-- Serves: R13 (active Bengaluru partners with no recent orders)
-- Type & order: Partial covering B-tree on (city_id) INCLUDE (partner_id, full_name, phone)
-- WHERE status = 'ACTIVE'.
-- Equality on city_id with partial filter status = 'ACTIVE' returns candidate riders via
-- an Index Only Scan without touching inactive/blocked partners.
CREATE INDEX IF NOT EXISTS idx_delivery_partners_city_active
    ON delivery_partners (city_id)
    INCLUDE (partner_id, full_name, phone)
    WHERE status = 'ACTIVE';

-- ---------------------------------------------------------------------
-- 6. orders
-- ---------------------------------------------------------------------

-- Serves: R04 (customer's last 10 orders),
--         R14 (EXISTS check for a customer's June orders),
--         R20 (Mumbai customers' delivered order totals)
-- Type & order: Covering B-tree on (customer_id, placed_at DESC) INCLUDE (status, total_amount).
-- Equality column customer_id first, sort/range column placed_at DESC second: R04 reads
-- at most 10 entries with no Sort, R14 probes via Index Only Scan, and R20 sums
-- total_amount for delivered orders via Index Only Scan.
CREATE INDEX IF NOT EXISTS idx_orders_customer_placed
    ON orders (customer_id, placed_at DESC)
    INCLUDE (status, total_amount);

-- Serves: R06 (restaurant's orders on one day),
--         R07 (restaurant's delivered orders in May),
--         R08 (Pune restaurants' delivered orders in last 30 days),
--         R19 (Bengaluru restaurants' last order time and delivered count),
--         R22 (Bengaluru orders by weekday/hour in last 8 weeks)
-- Type & order: Covering B-tree on (restaurant_id, placed_at DESC)
-- INCLUDE (status, item_total, order_id).
-- Equality column restaurant_id first, range/sort column placed_at DESC second.
-- Including (status, item_total, order_id) turns R06, R07, R08, R19, and R22 into
-- Index Only Scans on orders with zero heap fetches.
CREATE INDEX IF NOT EXISTS idx_orders_restaurant_placed
    ON orders (restaurant_id, placed_at DESC)
    INCLUDE (status, item_total, order_id);

-- Serves: R09 (2026 delivered orders avg delivery time per city/month),
--         R10 (June 2026 deliveries over 60 minutes),
--         R21 (May 2026 repeat customers per city),
--         R23 (admin pagination ordered by placed_at DESC, order_id DESC)
-- Type & order: Covering B-tree on (placed_at DESC, order_id DESC)
-- INCLUDE (customer_id, restaurant_id, status, delivered_at).
-- Leading (placed_at DESC, order_id DESC) serves keyset pagination (R23) in O(log N)
-- and date-range scans (R09, R10, R21). Including the needed columns enables Index Only
-- Scans for R09, R10, and R21 without scanning older months in the heap.
CREATE INDEX IF NOT EXISTS idx_orders_placed_desc
    ON orders (placed_at DESC, order_id DESC)
    INCLUDE (customer_id, restaurant_id, status, delivered_at);

-- Serves: R11 (partner's weekly earnings),
--         R13 (NOT EXISTS check for partners assigned orders since 25 Jun 2026)
-- Type & order: Partial covering B-tree on (partner_id, placed_at DESC)
-- INCLUDE (status, delivery_fee) WHERE partner_id IS NOT NULL.
-- Equality on partner_id first, time range placed_at DESC second. Partial predicate
-- skips unassigned/cancelled orders and incurs zero write overhead on W01 (new PLACED orders).
CREATE INDEX IF NOT EXISTS idx_orders_partner_placed
    ON orders (partner_id, placed_at DESC)
    INCLUDE (status, delivery_fee)
    WHERE partner_id IS NOT NULL;

-- Serves: R05 (kitchen-delay alert: orders stuck in PREPARING for > 40 minutes)
-- Type & order: Partial covering B-tree on (accepted_at) INCLUDE (order_id, restaurant_id)
-- WHERE status = 'PREPARING'.
-- Only ~0.025% of orders (37 rows in seed data) are in PREPARING at any moment, so this
-- index is tiny (~16 kB), gives an Index Only Scan in accepted_at order, and adds zero
-- overhead to W01.
CREATE INDEX IF NOT EXISTS idx_orders_preparing_accepted
    ON orders (accepted_at)
    INCLUDE (order_id, restaurant_id)
    WHERE status = 'PREPARING';

-- Serves: R12 (dispatch queue: unassigned PLACED/ACCEPTED orders, oldest first),
--         W02 (assign partner 150 to oldest unassigned ACCEPTED order)
-- Type & order: Partial covering B-tree on (placed_at) INCLUDE (order_id, restaurant_id, status)
-- WHERE partner_id IS NULL AND status IN ('PLACED', 'ACCEPTED').
-- Only ~0.05% of orders (75 rows in seed data) are waiting for a rider, so both R12 and
-- W02 read a tiny (~16 kB) index already ordered by placed_at with no Sort.
CREATE INDEX IF NOT EXISTS idx_orders_unassigned_dispatch
    ON orders (placed_at)
    INCLUDE (order_id, restaurant_id, status)
    WHERE partner_id IS NULL AND status IN ('PLACED', 'ACCEPTED');

-- Serves: R15 (coupon effectiveness across delivered orders)
-- Type & order: Partial covering B-tree on (coupon_code) INCLUDE (order_id, discount, total_amount)
-- WHERE status = 'DELIVERED' AND coupon_code IS NOT NULL.
-- Only ~11.7% of orders (17,623 of 150,000) are delivered with a coupon; this index lets
-- R15 aggregate coupon stats via an Index Only Scan over 11.7% of rows and adds zero
-- overhead to W01.
CREATE INDEX IF NOT EXISTS idx_orders_coupon_delivered
    ON orders (coupon_code)
    INCLUDE (order_id, discount, total_amount)
    WHERE status = 'DELIVERED' AND coupon_code IS NOT NULL;

-- ---------------------------------------------------------------------
-- 7. payments
-- ---------------------------------------------------------------------

-- Serves: R24 (bill page: lookup successful payment for one order_id)
-- Type & order: Covering B-tree on (order_id, payment_status) INCLUDE (method).
-- Equality on order_id and payment_status, with method included for an Index Only Scan.
-- Also indexes the foreign key payments(order_id).
CREATE INDEX IF NOT EXISTS idx_payments_order_status
    ON payments (order_id, payment_status)
    INCLUDE (method);

-- Serves: R16 (failed payments per method in last 7 days),
--         R17 (customers with >= 2 failed payment attempts all time)
-- Type & order: Partial covering B-tree on (attempted_at) INCLUDE (method, order_id)
-- WHERE payment_status = 'FAILED'.
-- Only ~5.1% of payments (6,965 of 137,378) are FAILED. R16 does a tiny Index Only Scan
-- on attempted_at >= '2026-06-24' (82 rows), and R17 scans only the 6,965 failed entries.
CREATE INDEX IF NOT EXISTS idx_payments_failed_attempted
    ON payments (attempted_at)
    INCLUDE (method, order_id)
    WHERE payment_status = 'FAILED';

-- ---------------------------------------------------------------------
-- 8. reviews
-- ---------------------------------------------------------------------

-- Serves: R19 (Bengaluru restaurants' average food rating),
--         W04 (nightly job recomputing every restaurant's rating from reviews)
-- Type & order: Covering B-tree on (restaurant_id) INCLUDE (food_rating).
-- Enables Index Only Scans grouped by restaurant_id without reading review_text/heap pages.
CREATE INDEX IF NOT EXISTS idx_reviews_restaurant_rating
    ON reviews (restaurant_id)
    INCLUDE (food_rating);

-- Serves: R18 (review moderation: newest reviews matching '%cold%' OR '%late%')
-- Type & order: Partial GIN trigram index on (review_text gin_trgm_ops) WHERE review_text IS NOT NULL.
-- Over half of reviews have NULL review_text; excluding NULLs halves index size while
-- accelerating arbitrary substring ILIKE searches.
CREATE INDEX IF NOT EXISTS idx_reviews_text_trgm
    ON reviews USING gin (review_text gin_trgm_ops)
    WHERE review_text IS NOT NULL;

-- Serves: R18 (ORDER BY created_at DESC LIMIT 50 over non-null review_text)
-- Type & order: Partial B-tree on (created_at DESC) WHERE review_text IS NOT NULL.
-- For common complaint keywords ('cold', 'late' match ~16% of non-null reviews), scanning
-- newest reviews in created_at DESC order stops after ~300 rows (O(1) even at 20x scale),
-- complementing the GIN trigram index which handles rare keywords.
CREATE INDEX IF NOT EXISTS idx_reviews_created_nonnull
    ON reviews (created_at DESC)
    WHERE review_text IS NOT NULL;

-- Update planner statistics and visibility maps so Index Only Scans avoid heap fetches.
VACUUM ANALYZE;
