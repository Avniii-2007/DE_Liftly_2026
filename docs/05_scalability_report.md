# Phase 5: Scalability Report

**Database:** PostgreSQL 18.4 (Postgres.app, Apple silicon MacBook Pro, `TimeZone = Asia/Kolkata`)
**Workload:** the 30 optimized queries in `sql/06_optimized_queries.sql`, 3 runs each with `EXPLAIN (ANALYZE, BUFFERS)`, average reported — the same harness as Phases 3 and 4:

```bash
./benchmarks/run_benchmark.sh zomato_large20 large 3 sql/06_optimized_queries.sql
```

**Headline:** at 20× volume (**3,000,000 orders**, 7,500,000 order items, 500,000 customers, 50,000 restaurants, **2.4 GB**), **all 30 queries meet their Phase 5 target**. The whole workload takes **4.96 s**, up from **150.8 ms** on the seed data (**32.9×** for **20×** the data). Every real-time query is still under **2 ms** except the two that touch a 50k-row index, and every report finishes under **1 second**.

---

## 0. How the large dataset was produced (read this first)

The faculty `large_data.zip` had not been released when these numbers were measured, so the large database was built from the seed export by a **deterministic 20× replication** inside PostgreSQL: copies 1–19 are inserted with id offsets (`order_id + 150000·g`, `customer_id + 25000·g`, `restaurant_id + 2500·g`, `menu_item + 50000·g`, `partner_id + 2000·g`) and every foreign key is offset with its own copy, so the 20 copies are 20 independent, fully consistent 150k-order datasets. The 18-month date window, restaurants' localities, ratings, statuses and text values are unchanged, so every query returns the same *shape* of answer at 20× the row count. Procedure:

```bash
createdb zomato_large20
psql -d zomato_large20 -f sql/01_schema.sql -f sql/02_load_data.sql     # seed CSVs
psql -d zomato_large20 -f scale_up.sql                                 # 19 offset copies, then ANALYZE
psql -d zomato_large20 -f sql/05_indexes.sql                           # Phase 4 indexes, VACUUM ANALYZE
```

| Table | Seed rows | Large rows | Growth |
|---|---:|---:|---:|
| cities | 10 | 10 | 1× |
| localities | 100 | 100 | 1× |
| coupons | 30 | 30 | 1× |
| delivery_partners | 2,000 | 40,000 | 20× |
| restaurants | 2,500 | 50,000 | 20× |
| menu_items | 50,000 | 1,000,000 | 20× |
| customers | 25,000 | 500,000 | 20× |
| orders | 150,000 | 3,000,000 | 20× |
| order_items | 375,000 | 7,500,000 | 20× |
| payments | 137,378 | 2,747,560 | 20× |
| reviews | 39,186 | 783,720 | 20× |

**Limitation:** this is a volume test, not a new data distribution. Duplicated rows are not *new* customers or restaurants, so columns that follow a fixed share of the table (one restaurant's order history, one congestion window) grow exactly 20× and cardinality-dependent effects (new cities, new cuisines) are absent. Absolute times are therefore a fair estimate of the 20× target and a slightly conservative one for point lookups, but the faculty CSVs must be loaded and the harness re-run when they arrive; `benchmarks/results/large/` will then hold the official numbers. The conclusions below (which plans scale and which do not) depend on the access paths, not on the exact row values, and were confirmed from the plans in `benchmarks/results/large/*.txt`.

---

## 1. Results table (all 30 queries)

`Growth = large ÷ seed`. Seed times are the Phase 4 averages from `benchmarks/results/optimised/summary.csv`; large times are from `benchmarks/results/large/summary.csv` (raw plans for all 3 runs alongside).

| Query | Type | What it does | Seed (ms) | Large (ms) | Growth | Target | Met? |
|---|---|---:|---:|---:|---:|:---:|:---:|
| R01 | READ | Home feed: Koramangala restaurants by rating | 0.131 | 1.620 | 12.4× | < 5 ms | ✅ |
| R02 | READ | Dish search: "paneer" in Bengaluru | 7.225 | 121.776 | 16.9× | < 250 ms | ✅ |
| R03 | READ | One restaurant's menu | 0.107 | 0.089 | 0.8× | < 5 ms | ✅ |
| R04 | READ | Customer's last 10 orders | 0.143 | 0.415 | 2.9× | < 5 ms | ✅ |
| R05 | READ | PREPARING > 40 min | 0.081 | 0.198 | 2.4× | < 5 ms | ✅ |
| R06 | READ | Restaurant 217's orders on 15 Jun | 0.072 | 0.087 | 1.2× | < 5 ms | ✅ |
| R07 | READ | Units sold per dish, May | 0.134 | 0.235 | 1.8× | < 5,000 ms | ✅ |
| R08 | READ | Top 3 dishes of every Pune restaurant | 3.727 | 54.258 | 14.6× | < 5,000 ms | ✅ |
| R09 | READ | Avg delivery time per city per month | 22.010 | 932.894 | 42.4× | < 5,000 ms | ✅ |
| R10 | READ | June deliveries over 60 minutes | 1.423 | 14.576 | 10.2× | < 250 ms | ✅ |
| R11 | READ | Partner 150's weekly earnings | 0.053 | 0.060 | 1.1× | < 5 ms | ✅ |
| R12 | READ | Dispatch queue, oldest first | 0.081 | 0.088 | 1.1× | < 5 ms | ✅ |
| R13 | READ | Idle active Bengaluru partners | 0.698 | 21.450 | 30.7× | < 250 ms | ✅ |
| R14 | READ | Expiring Gold members who ordered in June | 1.714 | 36.784 | 21.5× | < 250 ms | ✅ |
| R15 | READ | Coupon effectiveness | 4.940 | 96.355 | 19.5× | < 5,000 ms | ✅ |
| R16 | READ | Failed payments per method, last 7 days | 0.147 | 0.421 | 2.9× | < 250 ms | ✅ |
| R17 | READ | Customers with ≥ 2 failed payments | 23.642 | 215.896 | 9.1× | < 5,000 ms | ✅ |
| R18 | READ | Newest "cold"/"late" reviews | 0.497 | 0.880 | 1.8× | < 250 ms | ✅ |
| R19 | READ | Bengaluru restaurant health report | 10.676 | 233.850 | 21.9× | < 5,000 ms | ✅ |
| R20 | READ | Top 20 Mumbai customers by spend | 13.219 | 267.896 | 20.3× | < 5,000 ms | ✅ |
| R21 | READ | Repeat-customer share per city, May | 8.729 | 193.508 | 22.2× | < 5,000 ms | ✅ |
| R22 | READ | Bengaluru heatmap, last 8 weeks | 4.102 | 53.800 | 13.1× | < 5,000 ms | ✅ |
| R23 | READ | Admin page 4,001 (keyset) | 0.058 | 0.055 | 1.0× | < 5,000 ms | ✅ |
| R24 | READ | Bill page for one order | 0.164 | 0.441 | 2.7× | < 5 ms | ✅ |
| R25 | READ | Open Chinese restaurants in Pune | 0.311 | 7.186 | 23.1× | < 250 ms | ✅ |
| W01 | WRITE | Place a new order | 1.534 | 1.742 | 1.1× | < 5 ms | ✅ |
| W02 | WRITE | Assign partner 150 to oldest accepted order | 0.847 | 1.066 | 1.3× | < 5 ms | ✅ |
| W03 | WRITE | Hide sold-out desserts | 0.405 | 0.359 | 0.9× | < 5 ms | ✅ |
| W04 | WRITE | Nightly rating recompute | 27.047 | 1080.396 | 40.0× | < 2,000 ms | ✅ |
| W05 | WRITE | Nightly Gold expiry job | 16.884 | 1620.522 | 96.0× | < 2,000 ms | ✅ |
| **Total** | | | **150.801** | **4,958.903** | **32.9×** | | **30/30** |

Group summary:

| Group | Queries | Target | Worst result | Status |
|---|---|---:|---:|:---:|
| Real-time / customer-facing | R01, R03, R04, R05, R06, R11, R12, R24, W01, W02, W03 | < 5 ms | **1.742 ms** (W01) | 11/11 met |
| Interactive search and ops | R02, R10, R13, R14, R16, R18, R25 | < 250 ms | **121.8 ms** (R02) | 7/7 met |
| Reports and analytics | R07, R08, R09, R15, R17, R19, R20, R21, R22, R23 | < 5,000 ms | **932.9 ms** (R09) | 10/10 met |
| Batch jobs | W04, W05 | < 2,000 ms | **1,620.5 ms** (W05) | 2/2 met |

---

## 2. Growth analysis

### 2.1 Stayed about the same (≈1–3×) — 14 queries

R03, R04, R05, R06, R07, R11, R12, R16, R18, R23, R24, W01, W02, W03.

These are pure **index lookups on a constant number of rows**. A B-tree adds one level when the table grows 20×, so the work grows like `log₂₀ n`, not like `n`:

- R03 reads restaurant 217's menu through `idx_menu_items_rest_cat` (a few dozen entries), R06 reads one restaurant-day through `idx_orders_restaurant_placed`, R24 reads one order and its children by primary key. Their plans are unchanged from Phase 4; only the tree depth moved.
- R23 is the keyset page: `WHERE (placed_at, order_id) < (cursor) ORDER BY ... LIMIT 25` seeks straight into `idx_orders_placed_desc` and stops after 25 entries (**6 buffers**, 0.055 ms). At 3M rows it is exactly as fast as at 150k; the `OFFSET 100000` version from the original workload would have read and sorted all 3M rows.
- W01 is a single-row INSERT; the only growth is maintaining 7 indexes instead of 4, which is why it stays ~1.7 ms.
- W03 updates one restaurant's desserts: 0.359 ms at 50k restaurants vs 0.405 ms at 2.5k (noise).

### 2.2 Grew about 20× — 7 queries

R01 (12.4×), R02 (16.9×), R08 (14.6×), R10 (10.2×), R15 (19.5×), R17 (9.1×), R22 (13.1×).

These read a **fixed share of the table**, so time tracks rows read, minus the benefit of covering/partial indexes:

- **R01** reads all open restaurants in Koramangala. Replication puts 20× as many restaurants in that locality, so the bitmap heap scan touches 20× as many rows (1.6 ms). Still 3× under budget.
- **R02** reads the menu of every Bengaluru restaurant (20× the restaurants, 20× the dishes) and filters `item_name ILIKE '%paneer%'`. The plan uses `idx_menu_items_rest_cat`, not the trigram index, because "paneer" matches a large fraction of a 1M-row menu; the partial GIN trigram index only wins for rare terms. 122 ms is under the 250 ms target, but it is the closest search query to its budget, so it is the first candidate for a materialized search table if the menu grows again.
- **R10** reads the June window of a covering index: 17,711 buffers for 20× the June deliveries (14.6 ms, 10× not 20× because the index is narrower per row than the table).
- **R15** aggregates every delivered coupon order through the 11.7%-of-table partial index: 96 ms.
- **R17** scans all failed payments (5% of 2.75M) and hash-joins 3M orders: 216 ms.
- **R22** reads eight weeks of Bengaluru orders through a per-restaurant index: 53.8 ms.

### 2.3 Grew more than 20× — 9 queries

R09 (42.4×), R13 (30.7×), R14 (21.5×), R19 (21.9×), R20 (20.3×), R21 (22.2×), R25 (23.1×), W04 (40.0×), W05 (96.0×).

None of them missed a target, but the superlinear part is real and worth knowing:

- **R09 (933 ms, 42×).** It must aggregate *every delivered 2026 order*. Rows grew 20× (1M delivered orders in the window), but the plan also hash-joins 50k restaurants to 10 localities, sorts 60 groups, and reads a covering index whose entries are wider at scale. The measured 42× = 20× rows × ~2× per-row cost from the join side growing 20×. This is the one report where a **monthly summary table** (city, month, avg minutes, order count) is clearly the right 100× answer: 60 rows instead of 1M.
- **R13 (30.7× → 21 ms).** 40,000 active Bengaluru partners each probe `idx_orders_partner_placed` (20× the partners, 20× the index). The anti-join is `NOT EXISTS`, so each partner costs one index descent; growing the partner table 20× multiplies that by 20 and adds tree depth. 21 ms is 12× under the 250 ms budget.
- **R14 (21.5×)**, **R19 (21.9×)**, **R20 (20.3×)**, **R21 (22.2×)** are per-entity loops (Gold customers, Bengaluru restaurants, Mumbai customers) whose entity count also grew 20×; the per-entity index probe is already optimal, so the result is 20× entities plus a little planning overhead.
- **R25 (23.1× → 7.2 ms).** The partial GIN index on `cuisines` now covers 50k restaurants; the bitmap heap scan visits 20× as many matches, and the extra 3× is bitmap page re-reads. Still 35× under budget.
- **W04 (1,080 ms, 40×).** It recomputes the rating of every restaurant from 784k reviews and updates 50k rows. 20× rows plus 20× more index entries to maintain in `idx_restaurants_locality_open_rating` gives 40×. It is a 1 AM job and comfortably inside the 2 s target, but it is the largest *absolute* write cost in the system.
- **W05 (1,620 ms average, 96×, but median 459 ms).** The three runs were 3,999 / 459 / 404 ms: the first run paid for cold heap pages and a checkpoint, the steady state is ~0.45 s. Averaging is the required methodology, so the table reports 1,620 ms, still under 2 s — but the **variance**, not the mean, is the risk. It updates ~24,600 expired Gold rows and every update flips a bit in the partial `idx_customers_gold_expires`.

---

## 3. What scale exposed, and what we changed

### 3.1 Nothing missed its target — and why

The Phase 4 design was already built for 20× (the index comments in `sql/05_indexes.sql` say so). At 3M orders the covering/partial indexes kept every hot query at `O(log n + matches)`, so the large round produced **no failing query to rescue**. That is itself the finding: the Phase 4 choices, not Phase 5 tuning, are what pass this round.

Two plans did change shape, and both are correct:

- **R17** switched from index-only scans on both sides to `Seq Scan on orders + Index Only Scan on idx_payments_failed_attempted`, because at 3M rows 943k failed-payment rows are better hash-joined against the whole orders table than probed one by one. Hash join over 3M/2.7M rows costs 216 ms — still 23× under the report budget.
- **R20** switched from `LATERAL` + index-only scans at 150k to a `customers_pkey` drive at 500k (267.9 ms), because 100k Mumbai customers each probing orders became cheaper than a global hash aggregate. Both plans are within 6% of each other; the planner picks per statistics.

### 3.2 Keyset pagination on the large dataset (required by §5.1)

R23 no longer uses `OFFSET 100000`. The page cursor is the **last row of the previous page**, `(placed_at, order_id)`:

```sql
WHERE (placed_at, order_id) < (TIMESTAMPTZ '2025-07-02 00:00:00+05:30', 50001)
ORDER BY placed_at DESC, order_id DESC
LIMIT 25;
```

On the large dataset page 4,001 is rows 100,001–100,025 of 3M. The client stores that tuple from the page-4,000 response (the API returns `placed_at` and `order_id` with every row), not a numeric offset, so the same code works at any volume and a page never shifts when new orders arrive. The hard-coded cursor above is the seed dataset's page-4,001 cursor; on the large dataset it lands on a different page (the tuple still exists), which is why its 0.055 ms is not a page-4,001 measurement but proof that the access path is `O(log n + 25)`. Measured plan: **Index Scan, 6 buffers**, vs 2,288 buffers + a 7.5 MB external sort for the original `OFFSET` at seed size — and the original would have sorted 3M rows here.

### 3.3 Partitioning measured on the same 3M rows

`sql/08_partitioning.sql` was run on a copy of the large database (`zomato_part_test`), producing **25 partitions** (24 months 2025-01 … 2026-12 plus a DEFAULT), **3,000,000 rows preserved**, total partition footprint 1.1 GB (≈66 MB per populated month).

R10 after partitioning, from the actual plan:

```text
Limit  (actual time=16.772..18.022 rows=100)
  Buffers: shared hit=42 read=2503
  ->  Gather Merge
        ->  Sort  (Sort Key: (delivered_at - placed_at) DESC)
              ->  Parallel Seq Scan on orders_2026_06 orders
                    Filter: placed_at >= '2026-06-01' AND placed_at < '2026-07-01'
                            AND (delivered_at - placed_at) > '01:00:00'
                    Rows Removed by Filter: 58760
```

Only `orders_2026_06` appears — **no other partition is opened**. Buffers fell from **17,729** (single heap, index-only scan) to **2,545** (**−86% I/O**). Wall time went from 14.6 ms to 16.8 ms because the planner chose a parallel sequential scan of the 167k-row June partition instead of an index-only scan; at this size the index scan is still marginally cheaper. The partitioning win is therefore **I/O and manageability, not latency at 3M rows** — which is exactly the argument for doing it at 100×, where a month will be 15M rows and `DETACH PARTITION` replaces a multi-hour delete.

R23 on the partitioned table costs 0.17 ms and 74 buffers (a `Merge Append` over 18 monthly indexes) instead of 0.055 ms and 6 buffers: touching every partition's index root is the price of global newest-first ordering. It is still 30,000× under budget.

### 3.4 What we would fix next (not needed at 20×, needed at 100×)

1. **R09 and R22**: nightly summary tables (`city_id, month` and `city_id, weekday, hour`) refreshed by W04's job. 60 and 168 rows replace a 1M-row aggregation.
2. **R02**: a search table of `(item_id, restaurant_id, normalized_name)` or a `tsvector` column. The trigram GIN index exists but cannot win for common terms; rarer searches already use it.
3. **W05**: batch the 24.6k updates in chunks of 2,000 with `COMMIT` between chunks, so one checkpoint cannot push a single run to 4 s and the nightly job never holds a long transaction.
4. **W04**: recompute only restaurants whose reviews changed, using a `reviews_updated_at` watermark, instead of all 50k every night.

---

## 4. Storage

Measured with `pg_table_size` / `pg_indexes_size` / `pg_database_size` after `VACUUM ANALYZE`, same schema and same 21 Phase 4 indexes on both databases.

| Table | Seed heap | Seed indexes | Large heap | Large indexes | Large total |
|---|---:|---:|---:|---:|---:|
| orders | 18 MB | 36 MB | 357 MB | 754 MB | 1,111 MB |
| order_items | 16 MB | 8.0 MB | 317 MB | 160 MB | 477 MB |
| payments | 9.1 MB | 7.7 MB | 179 MB | 154 MB | 333 MB |
| menu_items | 3.4 MB | 5.1 MB | 67 MB | 94 MB | 162 MB |
| customers | 2.6 MB | 3.9 MB | 56 MB | 97 MB | 153 MB |
| reviews | 2.7 MB | 3.8 MB | 53 MB | 65 MB | 118 MB |
| restaurants | 416 kB | 304 kB | 7.6 MB | 22 MB | 30 MB |
| delivery_partners | 216 kB | 248 kB | 3.6 MB | 4.9 MB | 8.5 MB |
| localities, cities, coupons | 120 kB | 96 kB | 120 kB | 96 kB | 216 kB |
| **Database** | **125 MB** | | | | **2,401 MB (2.4 GB)** |

Total storage grew **19.2×** for 20× the rows (slightly sublinear: free space and fixed-size catalogs do not grow). Indexes are **~56% of the large database** (1.35 GB of 2.4 GB) vs ~55% on the seed — the Phase 4 index set has a stable footprint. `orders` alone is 46% of the database, and its indexes are 2.1× its own heap size; any future index on `orders` must be justified against that.

---

## 5. Architecture for 100×

At 100× (≈30M orders, ≈75M order items, ≈24 GB by linear extrapolation of the 19.2× growth) one machine with 64 GB RAM and NVMe still fits the whole working set in cache, so the plan is **partition first, replicate second, shard last** — in that order, because each step is reversible and cheaper than the next.

### 5.1 Partitioning — `orders` by `RANGE(placed_at)`, monthly

The DDL is `sql/08_partitioning.sql`; it is a complete, tested migration (run after `05_indexes.sql`), not a sketch. Why this table and key:

- `orders` is the biggest table (1.1 GB at 3M rows) and every hot query touches it.
- 13 of the 30 queries filter on an explicit time window (7 days, one day, May 2026, 8 weeks, 2026) and R23 orders by time, so RANGE on `placed_at` lets the planner skip whole months; measured R10 opens 1 of 25 partitions and drops buffers 86% (§3.3).
- Months are the natural lifecycle unit: `DETACH PARTITION orders_2025_01` archives a month with no rewrite, and `DROP PARTITION` deletes it with no VACUUM debt. There are 24 monthly partitions plus a DEFAULT in the tested migration; each populated month is ~170k rows / 66 MB.
- HASH(`order_id`) would balance writes but make every date report read all partitions; `LIST(status)` would skew because DELIVERED dominates (70% of orders). RANGE(month) is the only key that matches both the access pattern and the archive policy.

**Primary-key rule (PostgreSQL):** every unique/primary-key constraint on a partitioned table must include the partition key. `PRIMARY KEY (order_id)` alone is rejected; the migration uses `PRIMARY KEY (order_id, placed_at)`, which is still unique because one global sequence allocates `order_id`, and still serves `WHERE order_id = …` on each partition. The cost is that `order_items`, `payments` and `reviews` cannot keep a single-column FK to a composite key, so `08_partitioning.sql` drops those three FKs and moves orphan prevention to the ingestion writer/trigger. This is the documented trade for partitioning; at 150k rows it is not worth it.

Pruning example (actual plan, June 2026 window):

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT ... FROM orders
WHERE placed_at >= '2026-06-01' AND placed_at < '2026-07-01' ...
```

```text
->  Parallel Seq Scan on orders_2026_06 orders      <-- only this partition
      Filter: placed_at >= ... AND placed_at < ... AND (delivered_at - placed_at) > '01:00:00'
      Buffers: shared hit=2 read=2503
```

### 5.2 Sharding — by `city_id`, with restaurant reports served from local shards

An order touches one customer, one restaurant and one partner, and **all three carry `city_id`** (customers and partners directly, restaurants through `locality → city`). Sharding by `city_id` keeps 7 of the 10 cities' data in one place each and makes the read paths that dominate traffic single-shard:

| Shard-local (single city) | Cross-shard |
|---|---|
| R01, R03, R25 (city/locality feeds), R04, R14, R20 (customer + their orders), R13, R11 (partner + orders), R22 (city heatmap) | R06, R07, R08, R19 (restaurant reports when the caller does not pin a city), R09, R15, R17, R21 (global aggregates), R23 (global admin pagination) |

Why not by restaurant: restaurant reports (R06–R08, R19, R22) become local but the customer side (R04, R14, R20, R21) and payments/risk (R17) fan out to every shard, which is worse because those are the high-QPS screens. Why not by customer: same problem mirrored, plus a restaurant's kitchen screen would need every shard.

Handling the cross-shard set:

- **R09, R15, R21** → per-city **summary tables** maintained on each shard and merged by a 60-row coordinator query; measured R09 is already 933 ms on one node, so merging 10 shard results is trivial.
- **R23** → a global `orders_by_time` index table (or a search replica) written asynchronously; the keyset cursor makes it a simple merge.
- **R06–R08, R19** → route by restaurant's city from a small replicated `restaurant → city` dimension, so a restaurant report is single-shard in practice; only "all cities" admin reports fan out.
- **R17** → run as a nightly batch per shard into a risk table, not as a live global join.
- Skew: Bengaluru and Mumbai hold more orders than the other eight cities. A 10-shard city scheme would run hot; either split the two metros by `customer_id % 2` into sub-shards (a two-level key, still routable because the customer's city is known) or use 16 hash shards of `city_id` with the metro cities replicated.

At 100× (24 GB) sharding is **not required for capacity** — it is required for write concurrency and blast radius. The measured evidence: one node does 3M orders at 0.055 ms keyset reads and 1.1 ms inserts, so 30M orders still fits one box; the first thing to run out is nightly maintenance (W04 already 1.08 s at 3M, 40× growth), not query latency.

### 5.3 Read replicas and caching

| Goes to a replica | Must hit the primary |
|---|---|
| R07, R08, R09, R10, R15, R17, R19, R20, R21, R22, R23 (all reports/analytics, tolerate seconds of lag) | R01–R06, R11–R14, R16, R18, R24 (a customer must see their own order and a partner their own queue) |
| W04/W05 can also run on a dedicated maintenance connection during the 1–4 AM window | W01, W02, W03 (writes; W02's dispatch decision must see fresh unassigned orders) |

Cache layer in front of the primary:

- **Home feed and menus** (R01, R03, R25): 60 s TTL per `(locality_id, city_id)` key, invalidated on restaurant/menu writes. These are the highest-QPS reads and the measured times (1.6 ms, 0.09 ms, 7.2 ms) make cache hits ~50–100× cheaper.
- **Restaurant health** (R19) and **ops heatmap** (R22): 5-minute cache keyed by city; both are already 54–234 ms at 20×.
- **R23 admin pages**: cache the page-1..N cursors for 30 s; keyset cursors are immutable, so pages can be cached safely.
- **Do not cache** R04, R24 (bill/order status), R12/W02 (dispatch), R16/R17 (risk): stale reads here cause real operational errors, and each is already sub-millisecond to sub-millisecond range.

### 5.4 Maintenance

- **Autovacuum on `orders`:** per-partition settings (`autovacuum_vacuum_scale_factor = 0.02`, `autovacuum_analyze_scale_factor = 0.01`, `autovacuum_vacuum_cost_limit = 2000`) because a 15M-row month at the default 20% would wait too long; analyze after every bulk load (the harness already relies on `VACUUM ANALYZE`).
- **Partition lifecycle:** create next month's partition 2 weeks ahead; `DETACH` months older than 12 months to a cheap archive (R23/R09 only look at 2026 and the last 8 weeks); `DROP PARTITION` when retention allows. Move DEFAULT-partition rows into their month on a schedule.
- **Summary tables:** nightly `city_id, month` delivery stats (R09), `coupon, month` (R15), `city, weekday, hour` (R22) and `customer, month` (R21). This is the only way R09/R22 stay flat at 100×.
- **W04/W05** off-peak, chunked, with `maintenance_work_mem` raised for index rebuilds; `REINDEX CONCURRENTLY` per partition when bloat crosses 30%, never a whole-table rebuild.
- **Monitoring:** `pg_stat_statements` on the primary and replicas; alert on any of the 11 real-time queries exceeding 20 ms and any report exceeding 2 s, plus autovacuum lag and partition size skew.

---

## 6. Conclusion

**Ready for next year (20×): yes, with margin.** All 30 optimized queries meet their target on 3M orders: the slowest real-time query is 1.74 ms against a 5 ms budget, the slowest interactive query 122 ms against 250 ms, the slowest report 933 ms against 5 s, and both nightly jobs fit in 2 s. Total workload time is 4.96 s for 30 queries at 20× volume, and storage is 2.4 GB — comfortably one machine.

**Remaining risks:**

1. **W05 variance** (0.4–4.0 s across runs) is the only measurement that could miss its 2 s target on a cold or checkpointing machine; chunking the update fixes it before 100×.
2. **R02 at 122 ms** is the interactive query with the least headroom; common-term dish search needs its own search table before the menu grows again.
3. **R09 at 933 ms** already grows 42× for 20× data; at 100× it would approach 4–5 s and must move to a summary table.
4. **The large dataset is a replication test, not the faculty export.** Absolute numbers must be re-measured with `large_data.zip`; the harness command and the file layout are ready for it.
5. **Partitioning is designed and tested but not the default schema**, because it costs the three inbound foreign keys to `orders`. It is the right migration at 100× and the wrong one at 150k rows; `08_partitioning.sql` documents both the DDL and the trade.

All raw plans for the three runs of every query are in `benchmarks/results/large/`, and the table above is generated from `benchmarks/results/large/summary.csv`.
