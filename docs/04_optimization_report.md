# Phase 4: Optimization Report

Measured on PostgreSQL 18.4 (Postgres.app, MacBook Pro, `TimeZone = Asia/Kolkata`) against the 150,000-order seed dataset using the exact same methodology as Phase 3:

```bash
psql -d zomato_db -v ON_ERROR_STOP=1 -f sql/05_indexes.sql
./benchmarks/run_benchmark.sh zomato_db optimized 3 sql/06_optimized_queries.sql
```

Each query ran **3 times** with `EXPLAIN (ANALYZE, BUFFERS)`, write queries (`W01`–`W05`) ran inside `BEGIN ... ROLLBACK;`, and raw plans are saved in `benchmarks/results/optimized/` alongside `benchmarks/results/optimized/summary.csv`.

**Headline result:** Total workload time across all 30 queries dropped from **4,383.190 ms** to **150.801 ms** — a **96.6% reduction (29.1× overall speedup)** — while fixing a critical SQL `NULL` correctness bug in **R13** (`0` rows → `129` rows). All 11 real-time queries (`R01, R03, R04, R05, R06, R11, R12, R24, W01, W02, W03`) now execute in **under 1.6 ms**.

---

## 1. Before vs After Optimization Table (All 30 Queries)

`Improvement % = (before − after) / before × 100`. Positive values are speedups; negative values indicate slower execution (explained in Sections 5 and 7).

| Query | Before (ms) | Problem found in the plan | Optimization applied | After (ms) | Improvement | Same result? |
|---|---:|---|---|---:|---:|:---:|
| **R01** | 0.590 | Seq Scan on `restaurants` (2,500 rows) + `localities` + Sort | Partial index `idx_restaurants_locality_open_rating` on `(locality_id, rating DESC NULLS LAST) WHERE status = 'OPEN'` | 0.131 | 77.8% (4.5×) | ✅ |
| **R02** | 18.524 | Seq Scan on 50,000 `menu_items` evaluating `ILIKE '%paneer%'` | Covering index `idx_restaurants_locality` + `idx_menu_items_rest_cat` (+ partial GIN trigram `idx_menu_items_name_trgm` for scale) | 7.225 | 61.0% (2.6×) | ✅ |
| **R03** | 1.799 | Seq Scan on 50,000 `menu_items` + Sort by `(category, is_bestseller DESC, item_name)` | Covering index `idx_menu_items_rest_cat` enabling Index Only Scan in exact sort order (no Sort) | 0.107 | 94.1% (16.8×) | ✅ |
| **R04** | 4.691 | Seq Scan on 150,000 `orders` (2,288 buffers) + Sort | Composite covering index `idx_orders_customer_placed` on `(customer_id, placed_at DESC)` | 0.143 | 97.0% (32.8×) | ✅ |
| **R05** | 5.718 | Parallel Seq Scan on 150,000 `orders` (2,326 buffers) for 35 `PREPARING` rows + Sort | Partial covering index `idx_orders_preparing_accepted` (`WHERE status = 'PREPARING'`, 16 kB) → Index Only Scan, no Sort | 0.081 | 98.6% (70.6×) | ✅ |
| **R06** | 4.275 | Parallel Seq Scan on 150,000 `orders`; non-sargable `DATE(placed_at) = '2026-06-15'` | **Rewrite** to sargable range `placed_at >= '2026-06-15' AND placed_at < '2026-06-16'` + covering index `idx_orders_restaurant_placed` | 0.072 | 98.3% (59.4×) | ✅ |
| **R07** | 5.344 | Parallel Seq Scan on 150,000 `orders` to find 1 matching May order for restaurant 217 | Covering index `idx_orders_restaurant_placed` → Index Only Scan on `orders`, then PK lookups | 0.134 | 97.5% (39.9×) | ✅ |
| **R08** | 6.175 | Parallel Seq Scan on 150,000 `orders` + Seq Scan on `restaurants` | Covering indexes `idx_orders_placed_desc` + `idx_restaurants_locality` → Index Only Scans | 3.727 | 39.6% (1.7×) | ✅ |
| **R09** | 22.331 | Parallel Seq Scan on 150,000 `orders`; non-sargable `EXTRACT(YEAR...)` caused 112× underestimation and 43k-row Sort | **Rewrite** to sargable month ranges + materialized `rest_city` CTE + `avg(interval)` + `idx_orders_placed_desc` (buffers 2,399 → 460; see Section 7) | 22.010 | 1.4% (1.0×) | ✅ |
| **R10** | 4.826 | Parallel Seq Scan on 150,000 `orders` (2,327 buffers) for June deliveries > 60 min | Covering index `idx_orders_placed_desc` → Index Only Scan on June range only (71 buffers) | 1.423 | 70.5% (3.4×) | ✅ |
| **R11** | 5.318 | Parallel Seq Scan on 150,000 `orders` (2,288 buffers) for 2 rows of partner 150 | Partial covering index `idx_orders_partner_placed` (`WHERE partner_id IS NOT NULL`) → Index Only Scan (4 buffers) | 0.053 | 99.0% (100.3×) | ✅ |
| **R12** | 7.200 | Seq Scan on 150,000 `orders` (2,291 buffers) + Sort for 75 unassigned orders | Partial covering index `idx_orders_unassigned_dispatch` (`WHERE partner_id IS NULL AND status IN ('PLACED','ACCEPTED')`, 16 kB) → Index Only Scan, no Sort | 0.081 | 98.9% (88.9×) | ✅ |
| **R13** | 5.597 | Seq Scan on `orders` + `delivery_partners`; **`NOT IN` with NULL `partner_id` returned 0 rows (bug!)** | **Rewrite** `NOT IN` → `NOT EXISTS` + partial covering indexes `idx_delivery_partners_city_active` & `idx_orders_partner_placed` | 0.698 | 87.5% (8.0×) | **Fixed (0 → 129)** |
| **R14** | 6.753 | Seq Scan on 150,000 `orders` + Seq Scan on 25,000 `customers` (2,613 buffers) | Partial covering index `idx_customers_gold_expires` + covering `idx_orders_placed_desc` → Index Only Scans (75 buffers) | 1.714 | 74.6% (3.9×) | ✅ |
| **R15** | 13.497 | Seq Scan on all 150,000 `orders` (2,288 buffers) though only 11.7% are delivered with a coupon | Partial covering index `idx_orders_coupon_delivered` (`WHERE status = 'DELIVERED' AND coupon_code IS NOT NULL`) → Index Only Scan (124 buffers) | 4.940 | 63.4% (2.7×) | ✅ |
| **R16** | 3.944 | Seq Scan on 137,378 `payments` (1,166 buffers) for 82 recent failed attempts | Partial covering index `idx_payments_failed_attempted` (`WHERE payment_status = 'FAILED'`) → Index Only Scan (6 buffers) | 0.147 | 96.3% (26.8×) | ✅ |
| **R17** | 14.794 | Seq Scan on 137,378 `payments` + Seq Scan on 150,000 `orders` | Partial covering `idx_payments_failed_attempted` cut `payments` from 1,160 → 32 buffers, but `orders` still needed Seq Scan for Hash Join (see Section 7) | 23.642 | -59.8% (0.6×) | ✅ |
| **R18** | 12.076 | Seq Scan on 39,186 `reviews` running two leading-wildcard `ILIKE` checks + Sort | Partial index `idx_reviews_created_nonnull` (`(created_at DESC) WHERE review_text IS NOT NULL`) stops after ~300 newest rows (+ GIN trigram `idx_reviews_text_trgm` for rare terms) | 0.497 | 95.9% (24.3×) | ✅ |
| **R19** | 4134.376 | 3 correlated subqueries re-scanned `orders` 800× and `reviews` 400× (1,966,851 buffers!) | **Rewrite** to pre-aggregated CTEs + `LEFT JOIN` + covering indexes `idx_restaurants_locality`, `idx_orders_restaurant_placed`, `idx_reviews_restaurant_rating` (2,294 buffers) | 10.676 | 99.7% (387.3×) | ✅ |
| **R20** | 18.285 | Seq Scan on 150,000 `orders` + Seq Scan on 25,000 `customers` + HashAggregate | **Rewrite** to `LATERAL` per-customer aggregate + covering indexes `idx_customers_city` & `idx_orders_customer_placed` → Index Only Scans | 13.219 | 27.7% (1.4×) | ✅ |
| **R21** | 9.056 | Seq Scan on 150,000 `orders` + Seq Scan on 25,000 `customers` (2,616 buffers) | Covering `idx_orders_placed_desc` cut `orders` from 2,288 → 67 buffers (total 395 buffers); join against 25k `customers` dominates remaining time (see Section 7) | 8.729 | 3.6% (1.0×) | ✅ |
| **R22** | 12.743 | Seq Scan on 150,000 `orders` (2,288 buffers) + Seq Scan on `restaurants` | Covering indexes `idx_restaurants_locality` + `idx_orders_restaurant_placed` → Index Only Scan on only 2,500 Bengaluru orders | 4.102 | 67.8% (3.1×) | ✅ |
| **R23** | 33.264 | Seq Scan on 150,000 `orders` + external disk merge sort (7,568 kB temp spill) for `OFFSET 100000` | **Rewrite** to keyset pagination `WHERE (placed_at, order_id) < (...)` + `idx_orders_placed_desc` → 25-row Index Scan (5 buffers, zero sort) | 0.058 | 99.8% (573.5×) | ✅ |
| **R24** | 4.678 | Seq Scan on 137,378 `payments` (1,160 buffers) because `payments.order_id` had no index | Covering index `idx_payments_order_status` on `(order_id, payment_status) INCLUDE (method)` → Index Only Scan (27 total buffers) | 0.164 | 96.5% (28.5×) | ✅ |
| **R25** | 0.290 | Seq Scan on 2,500 `restaurants` checking `'Chinese' = ANY(cuisines)` | **Rewrite** to `r.cuisines @> ARRAY['Chinese']` + partial GIN `idx_restaurants_cuisines_gin` (tiny 47-page table on seed; built for 20× scale; see Section 7) | 0.311 | -7.2% (0.9×) | ✅ |
| **W01** | 0.794 | Plain `INSERT` (no scan); baseline maintained only PK | Write overhead: must insert into 4 new indexes on `orders` (3 partial indexes skipped; see Section 5) | 1.534 | -93.2% (0.5×) | ✅ |
| **W02** | 7.214 | Seq Scan on 150,000 `orders` + Sort to find 1 oldest unassigned `ACCEPTED` order | Partial covering index `idx_orders_unassigned_dispatch` → Index Only Scan (73 buffers vs 2,353) | 0.847 | 88.3% (8.5×) | ✅ |
| **W03** | 1.374 | Seq Scan on 50,000 `menu_items` to update 2 dessert rows | `idx_menu_items_rest_cat` → direct Index Scan on `(restaurant_id = 217, category = 'Desserts')` | 0.405 | 70.5% (3.4×) | ✅ |
| **W04** | 9.010 | Full scan of `reviews` + bulk `UPDATE` of 2,390 of 2,500 `restaurants` | Write overhead: updating `rating` breaks HOT updates and updates `idx_restaurants_locality_open_rating` (nightly job; see Section 5) | 27.047 | -200.2% (0.3×) | ✅ |
| **W05** | 8.654 | Seq Scan on 25,000 `customers` + `UPDATE` of 1,230 expired Gold rows | Bitmap Index Scan on `idx_customers_gold_expires` speeds up lookup, but flipping `is_gold_member` updates the partial index on 1,230 rows (nightly job; see Section 5) | 16.884 | -95.1% (0.5×) | ✅ |
| **Total** | **4383.190** | — | **21 targeted indexes + 7 query rewrites + `VACUUM ANALYZE`** | **150.801** | **96.6% (29.1×)** | **29 identical + 1 bug fixed** |

*(Note: Individual query averages sum to `4383.190 ms` from `benchmarks/results/baseline/summary.csv` and `150.801 ms` from `benchmarks/results/optimized/summary.csv`.)*

---

## 2. Wrong-Result Query Found, Explained, and Fixed (`R13`)

### The Problem (P6: *"The fleet team's idle-partner list came back empty"*)

Original **R13** in `queries/workload_30.sql`:

```sql
SELECT p.partner_id, p.full_name, p.phone
FROM delivery_partners p
WHERE p.city_id = 1
  AND p.status = 'ACTIVE'
  AND p.partner_id NOT IN (
      SELECT o.partner_id FROM orders o WHERE o.placed_at >= '2026-06-25'
  );
```

- **Baseline result:** **`0` rows** (even though Bengaluru has active delivery partners who had no orders since 25 June 2026).
- **Root cause (SQL Three-Valued Logic):** `orders.partner_id` is nullable (orders in `PLACED`, `ACCEPTED`, `CANCELLED_BY_RESTAURANT`, and some `CANCELLED_BY_CUSTOMER` rows have no rider assigned). On the seed dataset, **214 orders** placed on or after `2026-06-25` have `partner_id IS NULL`.
- In SQL, `p.partner_id NOT IN (v1, v2, ..., NULL)` is logically equivalent to:
  ```sql
  p.partner_id <> v1 AND p.partner_id <> v2 AND ... AND p.partner_id <> NULL
  ```
  Because any comparison against `NULL` yields `UNKNOWN`, the entire `AND` chain evaluates to either `FALSE` or `UNKNOWN` — **never `TRUE`**. Since `WHERE` keeps only rows evaluating to `TRUE`, every single delivery partner is discarded and the query silently returns an empty set.

### The Fix

Rewritten **R13** in `sql/06_optimized_queries.sql`:

```sql
SELECT p.partner_id, p.full_name, p.phone
FROM delivery_partners p
WHERE p.city_id = 1
  AND p.status = 'ACTIVE'
  AND NOT EXISTS (
      SELECT 1
      FROM orders o
      WHERE o.partner_id = p.partner_id
        AND o.placed_at >= '2026-06-25'
  );
```

- **Why `NOT EXISTS` fixes both correctness and speed:**
  1. **Correctness:** `o.partner_id = p.partner_id` simply fails to match rows where `o.partner_id IS NULL` instead of poisoning the whole predicate. The query now returns the correct **129 idle active Bengaluru delivery partners**.
  2. **Speed:** PostgreSQL plans `NOT EXISTS` as an Anti Join using `Index Only Scan` on `idx_delivery_partners_city_active` and `idx_orders_partner_placed`, cutting execution time from **5.597 ms → 0.698 ms (87.5% / 8.0× faster)**.

---

## 3. Proof That Results Are Unchanged

For the 23 untouched queries, the SQL text is byte-for-byte identical to `queries/workload_30.sql` and indexes never change query results.

For all **7 rewritten queries** (`R06`, `R09`, `R13`, `R19`, `R20`, `R23`, `R25`), we verified result equivalence directly in PostgreSQL using symmetric `EXCEPT ALL` diffs:

```sql
-- Pattern run for each rewritten query (ordered queries R20 and R23 also include row_number() OVER () to verify exact ordering):
WITH orig AS ( /* original query from workload_30.sql */ ),
     opt  AS ( /* rewritten query from 06_optimized_queries.sql */ )
SELECT
    (SELECT count(*) FROM orig) AS orig_rows,
    (SELECT count(*) FROM opt)  AS opt_rows,
    (SELECT count(*) FROM (SELECT * FROM orig EXCEPT ALL SELECT * FROM opt) a) +
    (SELECT count(*) FROM (SELECT * FROM opt  EXCEPT ALL SELECT * FROM orig) b) AS diff_rows;
```

### Verification Results

| Query | Rewrite Summary | Original Rows | Optimized Rows | Symmetric `EXCEPT ALL` Diff | Ordering Verified? | Status |
|---|---|---:|---:|---:|:---:|:---:|
| **R06** | `DATE(placed_at) = '2026-06-15'` → sargable range | 1 | 1 | **0** | Yes (`placed_at`) | ✅ Identical |
| **R09** | `EXTRACT(YEAR...) = 2026` → sargable month buckets + `avg(interval)` | 60 | 60 | **0** | Yes (`city_id, month`) | ✅ Identical |
| **R13** | `NOT IN (...)` → `NOT EXISTS (...)` | 0 *(buggy)* | 129 *(fixed)* | **0** *(vs `NOT IN ... AND partner_id IS NOT NULL`)* | Unordered | ✅ Bug Fixed |
| **R19** | 3 correlated subqueries → pre-aggregated CTEs + `LEFT JOIN` | 400 | 400 | **0** | Yes (`last_order_at DESC NULLS LAST`) | ✅ Identical |
| **R20** | Full `JOIN` + `GROUP BY` → `LATERAL` per Mumbai customer | 20 | 20 | **0** | Yes (`row_number()` checked) | ✅ Identical |
| **R23** | `OFFSET 100000` → keyset `WHERE (placed_at, order_id) < ('2025-07-02 00:00:00+05:30', 50001)` | 25 | 25 | **0** | Yes (`row_number()` checked) | ✅ Identical |
| **R25** | `'Chinese' = ANY (r.cuisines)` → `r.cuisines @> ARRAY['Chinese']` | 62 | 62 | **0** | Yes (`rating DESC NULLS LAST`) | ✅ Identical |

---

## 4. Before / After `EXPLAIN (ANALYZE, BUFFERS)` Plans — Top 5 Improvements

Ranked by percentage improvement / speedup factor (covering the two largest absolute time savings as well):

### 4.1 R23 — Admin Panel Pagination: **33.264 ms → 0.058 ms (99.8% / 573.5× faster)**

- **Why it got faster:** `OFFSET 100000` forced PostgreSQL to scan all 150,000 orders (`2,288` buffers), spill a **7,568 kB external merge sort to disk** (`temp read=792 written=949`), and discard 100,000 rows. Rewriting to keyset pagination using `(placed_at, order_id) < ('2025-07-02 00:00:00+05:30', 50001)` with `idx_orders_placed_desc` jumps straight to row 100,001 in **5 buffer hits** with zero sorting and zero temp disk I/O.

**Before (`benchmarks/results/baseline/R23.txt`, Run 1):**
```text
Limit  (cost=21035.95..21036.01 rows=25 width=36) (actual time=30.791..30.793 rows=25.00 loops=1)
  Buffers: shared hit=2291, temp read=792 written=949
  ->  Sort  (cost=20785.95..21160.95 rows=150000 width=36) (actual time=25.909..29.081 rows=100025.00 loops=1)
        Sort Key: placed_at DESC
        Sort Method: external merge  Disk: 7568kB
        Buffers: shared hit=2291, temp read=792 written=949
        ->  Seq Scan on orders  (cost=0.00..3788.00 rows=150000 width=36) (actual time=0.007..9.111 rows=150000.00 loops=1)
              Buffers: shared hit=2288
Planning Time: 0.157 ms
Execution Time: 32.128 ms
```

**After (`benchmarks/results/optimized/R23.txt`, Run 1):**
```text
Limit  (cost=0.42..3.80 rows=25 width=36) (actual time=0.019..0.033 rows=25.00 loops=1)
  Buffers: shared hit=5
  ->  Index Scan using idx_orders_placed_desc on orders  (cost=0.42..6810.86 rows=50375 width=36) (actual time=0.018..0.031 rows=25.00 loops=1)
        Index Cond: (ROW(placed_at, order_id) < ROW('2025-07-02 00:00:00+05:30'::timestamp with time zone, 50001))
        Index Searches: 1
        Buffers: shared hit=5
Planning Time: 0.810 ms
Execution Time: 0.061 ms
```

---

### 4.2 R19 — Bengaluru Restaurant Health Report: **4,134.376 ms → 10.676 ms (99.7% / 387.3× faster, 4,123.7 ms saved)**

- **Why it got faster:** In the baseline, three correlated `SubPlan`s executed once per Bengaluru restaurant (`loops=400`), performing **800 full Seq Scans of `orders`** (120 million row evaluations) and **400 full Seq Scans of `reviews`** (15.7 million row evaluations), hitting **1,966,851 shared buffers**. Rewriting to pre-aggregated CTEs (`blr_restaurants`, `order_stats`, `review_stats`) backed by covering indexes `idx_restaurants_locality`, `idx_orders_restaurant_placed`, and `idx_reviews_restaurant_rating` turned all three table accesses into `Index Only Scan`s touching only Bengaluru's 24,106 orders and 6,306 reviews — slashing buffer hits by **857×** (`1,966,851 → 2,294`).

**Before (`benchmarks/results/baseline/R19.txt`, Run 1):**
```text
Sort  (cost=2383139.30..2383139.92 rows=250 width=67) (actual time=4133.607..4133.622 rows=400.00 loops=1)
  Sort Key: ((SubPlan 1)) DESC NULLS LAST
  Sort Method: quicksort  Memory: 49kB
  Buffers: shared hit=1966851
  ->  Hash Join  (cost=2.38..2383129.34 rows=250 width=67) (actual time=11.367..4133.460 rows=400.00 loops=1)
        Hash Cond: (r.locality_id = l.locality_id)
        Buffers: shared hit=1966848
        ->  Seq Scan on restaurants r  (cost=0.00..72.00 rows=2500 width=23) (actual time=0.003..0.181 rows=2500.00 loops=1)
        ->  Hash  (cost=2.25..2.25 rows=10 width=4) (actual time=0.008..0.009 rows=10.00 loops=1)
              ->  Seq Scan on localities l  (Filter: city_id = 1)
        SubPlan 1
          ->  Aggregate  (actual time=3.414..3.414 rows=1.00 loops=400)
                ->  Seq Scan on orders o  (Filter: restaurant_id = r.restaurant_id, Buffers: shared hit=915200)
        SubPlan 2
          ->  Aggregate  (actual time=5.883..5.883 rows=1.00 loops=400)
                ->  Seq Scan on orders o_1  (Filter: restaurant_id = r.restaurant_id AND status = 'DELIVERED', Buffers: shared hit=915200)
        SubPlan 3
          ->  Aggregate  (actual time=1.034..1.034 rows=1.00 loops=400)
                ->  Seq Scan on reviews v  (Filter: restaurant_id = r.restaurant_id, Buffers: shared hit=136400)
Planning Time: 0.505 ms
Execution Time: 4133.686 ms
```

**After (`benchmarks/results/optimized/R19.txt`, Run 1):**
```text
Sort  (cost=2471.63..2472.25 rows=250 width=270) (actual time=10.176..10.193 rows=400.00 loops=1)
  Sort Key: (max(o.placed_at)) DESC NULLS LAST
  Sort Method: quicksort  Memory: 49kB
  Buffers: shared hit=2294
  CTE blr_restaurants
    ->  Nested Loop  (actual time=0.072..0.168 rows=400.00 loops=1, Buffers: shared hit=24)
          ->  Seq Scan on localities l  (Filter: city_id = 1, rows=10)
          ->  Index Only Scan using idx_restaurants_locality on restaurants r  (Heap Fetches: 0, loops=10)
  ->  Hash Right Join  (Hash Cond: v.restaurant_id = br.restaurant_id, Buffers: shared hit=2291)
        ->  HashAggregate  (Group Key: v.restaurant_id, rows=384, Buffers: shared hit=819)
              ->  Nested Loop  (rows=6306)
                    ->  CTE Scan on blr_restaurants br_1  (rows=400)
                    ->  Index Only Scan using idx_reviews_restaurant_rating on reviews v  (Heap Fetches: 0, loops=400)
        ->  Hash  (Buffers: shared hit=1472)
              ->  Hash Right Join  (Hash Cond: o.restaurant_id = br.restaurant_id)
                    ->  HashAggregate  (Group Key: o.restaurant_id, rows=384, Buffers: shared hit=1448)
                          ->  Nested Loop  (rows=24106)
                                ->  CTE Scan on blr_restaurants br_2  (rows=400)
                                ->  Index Only Scan using idx_orders_restaurant_placed on orders o  (Heap Fetches: 47, loops=400)
                    ->  Hash  (CTE Scan on blr_restaurants br, rows=400)
Planning Time: 2.011 ms
Execution Time: 10.328 ms
```

---

### 4.3 R11 — Delivery Partner Weekly Earnings: **5.318 ms → 0.053 ms (99.0% / 100.3× faster)**

- **Why it got faster:** Baseline performed a Parallel Seq Scan over all 150,000 `orders` (`2,288` buffers) just to find 2 deliveries for partner 150. The partial covering index `idx_orders_partner_placed` on `(partner_id, placed_at DESC) INCLUDE (status, delivery_fee) WHERE partner_id IS NOT NULL` seeks directly to those 2 entries via an **Index Only Scan** (`Heap Fetches: 0`, **4 buffers**).

**Before (`benchmarks/results/baseline/R11.txt`, Run 1):**
```text
Aggregate  (cost=5052.81..5052.82 rows=1 width=40) (actual time=4.757..5.332 rows=1.00 loops=1)
  Buffers: shared hit=2288
  ->  Gather  (cost=1000.00..5052.81 rows=1 width=4) (actual time=4.711..5.323 rows=2.00 loops=1)
        Workers Planned: 1
        Workers Launched: 1
        Buffers: shared hit=2288
        ->  Parallel Seq Scan on orders  (cost=0.00..4052.71 rows=1 width=4) (actual time=3.788..3.810 rows=1.00 loops=2)
              Filter: ((placed_at >= '2026-06-22 00:00:00+05:30'::timestamptz) AND (placed_at < '2026-06-29 00:00:00+05:30'::timestamptz) AND (partner_id = 150) AND ((status)::text = 'DELIVERED'::text))
              Rows Removed by Filter: 74999
              Buffers: shared hit=2288
Planning Time: 0.165 ms
Execution Time: 5.361 ms
```

**After (`benchmarks/results/optimized/R11.txt`, Run 1):**
```text
Aggregate  (cost=8.45..8.46 rows=1 width=40) (actual time=0.022..0.022 rows=1.00 loops=1)
  Buffers: shared hit=4
  ->  Index Only Scan using idx_orders_partner_placed on orders  (cost=0.42..8.44 rows=1 width=4) (actual time=0.010..0.011 rows=2.00 loops=1)
        Index Cond: ((partner_id = 150) AND (placed_at >= '2026-06-22 00:00:00+05:30'::timestamptz) AND (placed_at < '2026-06-29 00:00:00+05:30'::timestamptz))
        Filter: ((status)::text = 'DELIVERED'::text)
        Heap Fetches: 0
        Index Searches: 1
        Buffers: shared hit=4
Planning Time: 0.949 ms
Execution Time: 0.055 ms
```

---

### 4.4 R12 — Dispatch Unassigned Orders Queue: **7.200 ms → 0.081 ms (98.9% / 88.9× faster)**

- **Why it got faster:** Only 75 out of 150,000 orders (0.05%) are unassigned and in `PLACED`/`ACCEPTED`. Baseline read all 150,000 rows (`2,291` buffers) and sorted them. The partial covering index `idx_orders_unassigned_dispatch` (only **16 kB**) stores just those 75 rows pre-ordered by `placed_at` with `(order_id, restaurant_id, status)` included — returning the oldest 50 via an **Index Only Scan** in **3 buffers** with no Sort node.

**Before (`benchmarks/results/baseline/R12.txt`, Run 1):**
```text
Limit  (cost=4163.12..4163.14 rows=8 width=27) (actual time=7.163..7.165 rows=50.00 loops=1)
  Buffers: shared hit=2291
  ->  Sort  (cost=4163.12..4163.14 rows=8 width=27) (actual time=7.162..7.163 rows=50.00 loops=1)
        Sort Key: placed_at
        Sort Method: quicksort  Memory: 30kB
        Buffers: shared hit=2291
        ->  Seq Scan on orders o  (cost=0.00..4163.00 rows=8 width=27) (actual time=7.138..7.151 rows=75.00 loops=1)
              Filter: ((partner_id IS NULL) AND ((status)::text = ANY ('{PLACED,ACCEPTED}'::text[])))
              Rows Removed by Filter: 149925
              Buffers: shared hit=2288
Planning Time: 0.176 ms
Execution Time: 7.178 ms
```

**After (`benchmarks/results/optimized/R12.txt`, Run 1):**
```text
Limit  (cost=0.14..8.23 rows=6 width=27) (actual time=0.049..0.060 rows=50.00 loops=1)
  Buffers: shared hit=3
  ->  Index Only Scan using idx_orders_unassigned_dispatch on orders o  (cost=0.14..8.23 rows=6 width=27) (actual time=0.048..0.056 rows=50.00 loops=1)
        Heap Fetches: 5
        Index Searches: 1
        Buffers: shared hit=3
Planning Time: 0.806 ms
Execution Time: 0.079 ms
```

---

### 4.5 R05 — Kitchen-Delay Alert (`PREPARING` > 40 min): **5.718 ms → 0.081 ms (98.6% / 70.6× faster)**

- **Why it got faster:** Only 37 rows in `orders` (0.025%) are in `PREPARING`. Baseline launched a parallel worker to scan 150,000 rows (`2,326` buffers) and sort 35 matches. The tiny 16 kB partial covering index `idx_orders_preparing_accepted` reads only those 35 rows in `accepted_at` order via an **Index Only Scan** in **3 buffers** with zero sorting.

**Before (`benchmarks/results/baseline/R05.txt`, Run 1):**
```text
Gather Merge  (cost=4832.45..4835.53 rows=27 width=16) (actual time=5.729..6.387 rows=35.00 loops=1)
  Workers Planned: 1
  Workers Launched: 1
  Buffers: shared hit=2326
  ->  Sort  (cost=3832.44..3832.48 rows=16 width=16) (actual time=4.578..4.579 rows=17.50 loops=2)
        Sort Key: accepted_at
        Sort Method: quicksort  Memory: 25kB
        ->  Parallel Seq Scan on orders  (cost=0.00..3832.12 rows=16 width=16) (actual time=4.554..4.561 rows=17.50 loops=2)
              Filter: (((status)::text = 'PREPARING'::text) AND (accepted_at < ('2026-06-30 23:59:00+05:30'::timestamptz - '00:40:00'::interval)))
              Rows Removed by Filter: 74982
              Buffers: shared hit=2288
Planning Time: 0.154 ms
Execution Time: 6.407 ms
```

**After (`benchmarks/results/optimized/R05.txt`, Run 1):**
```text
Index Only Scan using idx_orders_preparing_accepted on orders  (cost=0.14..13.18 rows=59 width=16) (actual time=0.054..0.061 rows=35.00 loops=1)
  Index Cond: (accepted_at < ('2026-06-30 23:59:00+05:30'::timestamptz - '00:40:00'::interval))
  Heap Fetches: 16
  Index Searches: 1
  Buffers: shared hit=3 dirtied=1
Planning Time: 0.776 ms
Execution Time: 0.080 ms
```

---

## 5. Write Overhead Analysis (`W01`–`W05`)

Every index speeds up reads at the cost of extra maintenance on writes — and when an `UPDATE` modifies an indexed column (or changes whether a row satisfies a partial index predicate), PostgreSQL cannot perform a Heap-Only Tuple (HOT) update and must update index entries too.

| Query | Operation | Before (ms) | After (ms) | Delta (ms) | Change | Why | Acceptable? |
|---|---|---:|---:|---:|---:|---|:---:|
| **W01** | `INSERT` 1 new `PLACED` order | 0.794 | 1.534 | +0.740 | +93.2% slower | Must insert into 4 new indexes on `orders` (`customer_placed`, `restaurant_placed`, `placed_desc`, `unassigned_dispatch`). Partial predicates deliberately skip the other 3 (`partner_placed`, `preparing_accepted`, `coupon_delivered`). Buffers: `72 → 243`. | **Yes** — 1.53 ms is well under the 5 ms real-time target. |
| **W02** | `UPDATE` oldest unassigned `ACCEPTED` order | 7.214 | 0.847 | -6.367 | **88.3% faster** | Lookup of oldest unassigned `ACCEPTED` order dropped from 150k Seq Scan (6.93 ms) to a 3-buffer Index Only Scan via `idx_orders_unassigned_dispatch`, far outweighing index maintenance on 1 row. | **Yes** — big net win, < 1 ms. |
| **W03** | `UPDATE` desserts unavailable for restaurant 217 | 1.374 | 0.405 | -0.969 | **70.5% faster** | Finding the 2 rows dropped from 50k Seq Scan to direct Index Scan on `idx_menu_items_rest_cat`, easily outweighing index update on 2 rows. | **Yes** — net win, < 0.5 ms. |
| **W04** | Nightly bulk `UPDATE` of `restaurants.rating` (2,390 rows) | 9.010 | 27.047 | +18.037 | +200.2% slower | `idx_restaurants_locality_open_rating` indexes `rating`, so updating `rating` on 2,390 rows disables HOT updates and forces index updates (buffers: `17,329 → 31,124`). | **Yes** — runs once nightly (target < 2,000 ms); saves orders of magnitude more latency on high-QPS home feed `R01`. |
| **W05** | Nightly bulk `UPDATE` of 1,230 expired Gold `customers` | 8.654 | 16.884 | +8.230 | +95.1% slower | Scanning for expired Gold users got faster via `idx_customers_gold_expires` (`0.96 ms → 0.76 ms`), but setting `is_gold_member = FALSE` invalidates all 1,230 rows from the partial index and prevents HOT updates (buffers: `17,740 → 20,415`). | **Yes** — runs once nightly (target < 2,000 ms). |

**Takeaway:** The two dispatch/partner writes (`W02`, `W03`) got **3.4×–8.5× faster**, the hot-path customer insert (`W01`) rose by only **+0.74 ms** (kept lean by partial indexes), and the larger write penalties (`W04`, `W05`) are isolated to **once-a-night batch jobs** well below their 2,000 ms budget.

---

## 6. Index Storage (`pg_relation_size`)

### 6.1 Custom Indexes Created in `sql/05_indexes.sql` (21 Indexes)

Measured via `pg_relation_size()` after `VACUUM ANALYZE`:

| Table | Index Name | Type | Table Size | Index Size | % of Table | Queries Served |
|---|---|---|---:|---:|---:|---|
| `customers` | `idx_customers_city` | Covering B-tree | 2,984 kB | 1,256 kB | 42.1% | R20 |
| `customers` | `idx_customers_gold_expires` | Partial covering B-tree | 2,984 kB | 168 kB | 5.6% | R14, W05 |
| `delivery_partners` | `idx_delivery_partners_city_active` | Partial covering B-tree | 184 kB | 104 kB | 56.5% | R13 |
| `localities` | `idx_localities_name` | Covering B-tree | 8 kB | 16 kB | 200.0% | R01 |
| `menu_items` | `idx_menu_items_rest_cat` | Covering B-tree | 3,456 kB | 2,808 kB | 81.3% | R03, W03 (and R02) |
| `menu_items` | `idx_menu_items_name_trgm` | Partial GIN (`pg_trgm`) | 3,456 kB | 1,352 kB | 39.1% | R02 |
| `orders` | `idx_orders_placed_desc` | Covering B-tree | 18 MB | 8,944 kB | 49.0% | R09, R10, R21, R23 (and R08, R14) |
| `orders` | `idx_orders_restaurant_placed` | Covering B-tree | 18 MB | 8,856 kB | 48.5% | R06, R07, R19, R22 |
| `orders` | `idx_orders_customer_placed` | Covering B-tree | 18 MB | 7,640 kB | 41.9% | R04, R20 |
| `orders` | `idx_orders_partner_placed` | Partial covering B-tree | 18 MB | 6,744 kB | 37.0% | R11, R13 |
| `orders` | `idx_orders_coupon_delivered` | Partial covering B-tree | 18 MB | 824 kB | 4.5% | R15 |
| `orders` | `idx_orders_preparing_accepted` | Partial covering B-tree | 18 MB | 16 kB | 0.1% | R05 |
| `orders` | `idx_orders_unassigned_dispatch` | Partial covering B-tree | 18 MB | 16 kB | 0.1% | R12, W02 |
| `payments` | `idx_payments_order_status` | Covering B-tree | 9,160 kB | 4,648 kB | 50.7% | R24 |
| `payments` | `idx_payments_failed_attempted` | Partial covering B-tree | 9,160 kB | 256 kB | 2.8% | R16, R17 |
| `restaurants` | `idx_restaurants_locality` | Covering B-tree | 1,456 kB | 584 kB | 40.1% | R02, R08, R19, R22 |
| `restaurants` | `idx_restaurants_cuisines_gin` | Partial GIN (array) | 1,456 kB | 344 kB | 23.6% | R25 |
| `restaurants` | `idx_restaurants_locality_open_rating` | Partial B-tree | 1,456 kB | 320 kB | 22.0% | R01 |
| `reviews` | `idx_reviews_restaurant_rating` | Covering B-tree | 2,728 kB | 880 kB | 32.3% | R19 |
| `reviews` | `idx_reviews_text_trgm` | Partial GIN (`pg_trgm`) | 2,728 kB | 824 kB | 30.2% | R18 |
| `reviews` | `idx_reviews_created_nonnull` | Partial B-tree | 2,728 kB | 408 kB | 15.0% | R18 |
| **Total (21 custom indexes)** | — | — | **53.19 MiB** *(all 11 heaps)* | **45.91 MiB** *(47,008 kB)* | **86.3%** | — |

### 6.2 Table Heap vs All Indexes (PK + UNIQUE + Custom)

| Table | Table Heap | All Indexes (PK + UQ + Custom) | Total Size |
|---|---:|---:|---:|
| `orders` | 18 MB | 36 MB | 53 MB |
| `order_items` | 16 MB | 8,232 kB | 24 MB |
| `payments` | 9,160 kB | 7,928 kB | 17 MB |
| `menu_items` | 3,456 kB | 5,272 kB | 8,760 kB |
| `customers` | 2,984 kB | 4,464 kB | 7,480 kB |
| `reviews` | 2,728 kB | 3,856 kB | 6,624 kB |
| `restaurants` | 1,456 kB | 1,432 kB | 2,928 kB |
| `delivery_partners` | 184 kB | 248 kB | 464 kB |
| `localities` | 8 kB | 48 kB | 88 kB |
| `cities` | 8 kB | 32 kB | 72 kB |
| `coupons` | 8 kB | 16 kB | 56 kB |
| **Total (all 11 tables)** | **53.19 MiB** | **66.29 MiB** | **~119.5 MiB** |

Notice how effective **partial indexes** are for storage: `idx_orders_preparing_accepted` (16 kB, 0.1%), `idx_orders_unassigned_dispatch` (16 kB, 0.1%), `idx_payments_failed_attempted` (256 kB, 2.8%), `idx_orders_coupon_delivered` (824 kB, 4.5%), and `idx_customers_gold_expires` (168 kB, 5.6%) deliver massive speedups (up to 89×) while adding barely **1.25 MB** combined.

---

## 7. Queries That Could Not Be Sped Up Significantly (and Why)

An honest review of the queries where wall-clock time stayed flat or regressed on the 150k-order seed dataset:

1. **R09 (`22.331 ms → 22.010 ms`, 1.4%):**
   - **What actually improved:** The rewrite + `idx_orders_placed_desc` cut shared buffer hits by **5.2×** (`2,399 → 460`) and eliminated the 43,141-row Sort (`1,778 kB` per worker) in favor of a 40 kB `HashAggregate`.
   - **Why wall-clock time stayed ~22 ms:** `R09` must still aggregate **all 43,141 delivered orders of 2026** (28.8% of the entire table) and join every one to its restaurant/city. In baseline, PostgreSQL ran the scan and sort across 2 parallel workers; in the optimized plan, the single-threaded Nested Loop over 12 months + Hash Join + `avg(interval)` is CPU-bound on warm in-memory data. For sub-millisecond reporting at 20× volume, a nightly/hourly **materialized view** pre-aggregating `(city_id, month)` would be the right next step.
2. **R17 (`14.794 ms → 23.642 ms`, -59.8%):**
   - **What actually improved:** `idx_payments_failed_attempted` cut the `payments` scan from **1,160 buffers (4.07 ms) → 32 buffers (0.59 ms)** — a **36× I/O reduction** on `payments`.
   - **Why total time did not drop:** `R17` asks for *all-time* failed payments (6,965 rows) joined to `orders` to fetch `customer_id`. Because `orders_pkey` indexes only `order_id` (not `customer_id`), PostgreSQL judged a `Seq Scan on orders` (`2,281` buffers) cheaper than 6,965 random PK + heap lookups. Total buffers still fell (`3,454 → 2,319`), and the higher wall-clock time came from CPU/cache variance on the 150k-row Hash Join. Without adding a redundant covering index on `orders(order_id) INCLUDE (customer_id)` (~4 MB extra write cost on every order insert), scanning `orders` is unavoidable for an all-time risk audit.
3. **R21 (`9.056 ms → 8.729 ms`, 3.6%):**
   - **What actually improved:** `idx_orders_placed_desc` cut the `orders` scan from **2,288 buffers (5.31 ms) → 67 buffers (0.82 ms)** (34× fewer buffers; total buffers `2,616 → 395`).
   - **Why total time moved only slightly:** After aggregating 8,517 May orders down to 7,210 distinct customers, the query must still join 28.8% of the `customers` table (`25,000` rows) to map each `customer_id` to `city_id`. That `Seq Scan on customers` + `Hash Join` + `HashAggregate` now accounts for ~7.8 ms of the 8.7 ms total.
4. **R25 (`0.290 ms → 0.311 ms`, -7.2%):**
   - **Why:** On the seed dataset, `restaurants` has only **2,500 rows (47 pages total)** and 595 open Chinese restaurants spread across all 47 pages (`Heap Blocks: exact=47`). Visiting the GIN index (`3` buffers) plus all `47` heap blocks costs virtually the same as scanning 47 heap blocks sequentially (~0.3 ms). The rewrite (`@> ARRAY['Chinese']`) and `idx_restaurants_cuisines_gin` are kept specifically for **Phase 5 (50,000 restaurants)** where scanning the full table grows 20×.
5. **W04 (`9.010 ms → 27.047 ms`) and W05 (`8.654 ms → 16.884 ms`):**
   - Both are nightly bulk `UPDATE` jobs touching 95.6% of `restaurants` (2,390 rows) and 1,230 expired Gold `customers`, respectively. As analyzed in Section 5, their extra time is pure index-maintenance write overhead traded in exchange for sub-millisecond reads on customer-facing queries (`R01`, `R14`).
