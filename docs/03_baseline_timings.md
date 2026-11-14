# Phase 3: Baseline Timings

Measured with `./benchmarks/run_benchmark.sh zomato_db baseline` on PostgreSQL 18.4 (Postgres.app) on one MacBook Pro. Each query ran 3 times with EXPLAIN (ANALYZE, BUFFERS), and the average of the three Execution Time values is shown. Write queries (W01 to W05) ran inside BEGIN ... ROLLBACK, so the data did not change. The database had no indexes except the ones PostgreSQL creates for PRIMARY KEY and UNIQUE constraints. Raw plans for all runs are in `benchmarks/results/baseline/`.

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---|---|---|---|
| R01: Home feed: open restaurants in Koramangala, best rated first | READ | 0.889 | 0.473 | 0.408 | 0.590 |
| R02: Dish search: available paneer dishes in Bengaluru | READ | 23.135 | 17.417 | 15.019 | 18.524 |
| R03: Restaurant page: the menu of one restaurant, grouped by category | READ | 2.248 | 1.612 | 1.537 | 1.799 |
| R04: Your orders: a customer's last 10 orders with restaurant names | READ | 5.405 | 4.283 | 4.386 | 4.691 |
| R05: Kitchen-delay alert: orders stuck in PREPARING for over 40 minutes | READ | 6.407 | 5.409 | 5.337 | 5.718 |
| R06: Restaurant partner app: all orders received by restaurant 217 on 15 June 2026 | READ | 4.171 | 4.312 | 4.342 | 4.275 |
| R07: Restaurant partner app: units sold per dish in May 2026 | READ | 5.206 | 5.690 | 5.137 | 5.344 |
| R08: Bestseller badges: top 3 dishes of every Pune restaurant in the last 30 days | READ | 6.274 | 6.381 | 5.870 | 6.175 |
| R09: Ops dashboard: average delivery time per city per month in 2026 | READ | 22.393 | 21.814 | 22.785 | 22.331 |
| R10: Customer support: deliveries in June 2026 that took more than 60 minutes | READ | 4.676 | 4.879 | 4.922 | 4.826 |
| R11: Delivery partner app: this week's earnings for partner 150 | READ | 5.361 | 5.130 | 5.462 | 5.318 |
| R12: Dispatch: orders still waiting for a delivery partner, oldest first | READ | 7.178 | 7.228 | 7.193 | 7.200 |
| R13: Fleet team: active Bengaluru partners with no order since 25 June 2026 | READ | 5.627 | 5.607 | 5.558 | 5.597 |
| R14: Gold team: Gold members expiring before July 2026 who ordered in June 2026 | READ | 7.029 | 6.573 | 6.657 | 6.753 |
| R15: Marketing: coupon effectiveness (orders, total discount, average bill) | READ | 13.439 | 13.586 | 13.465 | 13.497 |
| R16: Payments team: failed payment attempts per method in the last 7 days | READ | 4.397 | 3.748 | 3.686 | 3.944 |
| R17: Risk team: customers with 2 or more failed payment attempts | READ | 14.709 | 14.936 | 14.738 | 14.794 |
| R18: Review moderation: newest reviews that complain about cold food or late delivery | READ | 12.343 | 12.126 | 11.758 | 12.076 |
| R19: Restaurant health report for Bengaluru | READ | 4133.686 | 4123.760 | 4145.683 | 4134.376 |
| R20: Growth: top 20 customers in Mumbai by spend on delivered orders | READ | 18.524 | 18.245 | 18.087 | 18.285 |
| R21: Growth: share of customers per city who ordered at least twice in May 2026 | READ | 9.074 | 9.081 | 9.012 | 9.056 |
| R22: Ops heatmap: Bengaluru orders by weekday and hour, last 8 weeks | READ | 12.751 | 12.701 | 12.776 | 12.743 |
| R23: Admin panel: All orders, newest first, page 4,001 | READ | 32.128 | 35.669 | 31.996 | 33.264 |
| R24: Bill page: one order with its items, restaurant and successful payment | READ | 4.660 | 4.699 | 4.675 | 4.678 |
| R25: Cuisine filter: open Chinese restaurants in Pune | READ | 0.289 | 0.278 | 0.304 | 0.290 |
| W01: Customer app: place a new order (header row) | WRITE | 1.245 | 0.562 | 0.576 | 0.794 |
| W02: Dispatch: assign partner 150 to the oldest accepted order with no partner | WRITE | 7.627 | 6.957 | 7.059 | 7.214 |
| W03: Restaurant partner app: desserts sold out, so hide them | WRITE | 1.413 | 1.350 | 1.360 | 1.374 |
| W04: Nightly job: recompute every restaurant's rating from its reviews | WRITE | 9.544 | 8.711 | 8.774 | 9.010 |
| W05: Nightly job: end Gold membership for customers whose plan has expired | WRITE | 10.145 | 7.380 | 8.436 | 8.654 |
| **Total (sum of all 30)** | | 4391.973 | 4370.597 | 4386.998 | 4383.189 |

## Scan type and why each query is slow or fast

- **R01**: Seq Scan on restaurants, Seq Scan on localities. No index on locality_name or status, so both small tables are read in full. They are tiny (100 and 2,500 rows), so it is already fast.
- **R02**: Seq Scan on menu_items, Seq Scan on restaurants, Seq Scan on localities. ILIKE '%paneer%' starts with a wildcard, so a normal B-tree index cannot help. Every dish in menu_items is checked.
- **R03**: Seq Scan on menu_items. No index on restaurant_id, so all of menu_items is read to find one restaurant's dishes.
- **R04**: Seq Scan on orders, Index Scan using restaurants_pkey on restaurants. No index on customer_id, so all of orders is read to find one customer's orders. The restaurant lookup uses the primary key.
- **R05**: Seq Scan on orders. No index on status or accepted_at, so all of orders is read to find the few PREPARING orders.
- **R06**: Seq Scan on orders. No index on restaurant_id. DATE(placed_at) also wraps the column in a function, so an index on placed_at could not be used as written.
- **R07**: Seq Scan on orders, Index Scan using order_items_pkey on order_items, Index Scan using menu_items_pkey on menu_items. All of orders is read to find restaurant 217's delivered May orders. Order items and dishes are then found through their primary keys.
- **R08**: Seq Scan on orders, Seq Scan on restaurants, Seq Scan on localities, Index Scan using order_items_pkey on order_items. All of orders is read for the date and status filter, joined to Pune restaurants, then to order_items by primary key.
- **R09**: Seq Scan on orders, Seq Scan on restaurants, Seq Scan on localities. EXTRACT(YEAR FROM placed_at) = 2026 wraps the column in a function, so no index could be used. It also joins every delivered order to its city.
- **R10**: Seq Scan on orders. No index on placed_at, so all of orders is read. The delivery-time condition is calculated from two columns.
- **R11**: Seq Scan on orders. No index on partner_id, so all of orders is read to find one partner's orders.
- **R12**: Seq Scan on orders. No index on partner_id or status. All of orders is read, then the matching rows are sorted by placed_at.
- **R13**: Seq Scan on delivery_partners, Seq Scan on orders. Uses NOT IN over orders.partner_id, which can contain NULLs. NOT IN with a NULL in the list can return no rows at all, so the result is suspect (to check in CP3).
- **R14**: Seq Scan on orders, Seq Scan on customers. For each Gold customer, orders is searched for a June order, and there is no index on customer_id.
- **R15**: Seq Scan on orders, Seq Scan on coupons. Must read nearly all of orders to group by coupon_code, so an index will not help much.
- **R16**: Seq Scan on payments. No index on payment_status or attempted_at, so all of payments is read.
- **R17**: Seq Scan on orders, Seq Scan on payments. All failed payments are joined to orders to find the customer, then grouped by customer. There is no index on payments.order_id.
- **R18**: Seq Scan on reviews. ILIKE '%cold%' and '%late%' start with a wildcard, so a normal B-tree index cannot help. Every review is checked.
- **R19**: Seq Scan on restaurants, Seq Scan on localities, Seq Scan on orders, Seq Scan on reviews. Slowest query. For each Bengaluru restaurant, three correlated subqueries re-scan orders and reviews, and there is no index on restaurant_id.
- **R20**: Seq Scan on orders, Seq Scan on customers. All delivered orders are joined to Mumbai customers and grouped by customer, then sorted by total spend.
- **R21**: Seq Scan on customers, Seq Scan on orders. All May orders are read and grouped by customer, then joined to customers.
- **R22**: Seq Scan on orders, Seq Scan on restaurants, Seq Scan on localities. All recent orders are read, joined to restaurants and localities for the city, and grouped by weekday and hour.
- **R23**: Seq Scan on orders. OFFSET 100000 makes Postgres read and sort all orders by placed_at, then throw away the first 100,000 rows.
- **R24**: Index Scan using orders_pkey on orders, Index Scan using restaurants_pkey on restaurants, Seq Scan on payments, Index Scan using order_items_pkey on order_items, Index Scan using menu_items_pkey on menu_items. Fast for orders, order_items and restaurants because they use primary keys. payments is read in full because it has no index on order_id.
- **R25**: Seq Scan on restaurants, Seq Scan on localities. Tiny tables, so already fast. The array search 'Chinese' = ANY(cuisines) has no index, so rows are checked one by one.
- **W01**: (no scan). A single-row INSERT, so there is nothing to scan. Every index added later will make it slightly slower.
- **W02**: Seq Scan on orders, Index Scan using orders_pkey on orders. All of orders is read to find the oldest ACCEPTED order with no partner, then the update goes through the primary key.
- **W03**: Seq Scan on menu_items. No index on restaurant_id, so all of menu_items is read before hiding the desserts.
- **W04**: Seq Scan on restaurants, Seq Scan on reviews. All of reviews is read to average ratings per restaurant, then every matching restaurant row is updated.
- **W05**: Seq Scan on customers. No index on is_gold_member or gold_expires_on, so all of customers is read.
