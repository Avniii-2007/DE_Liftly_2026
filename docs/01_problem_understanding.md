# Phase 1: Problem Understanding

| # | What the business needs | Who is affected | Type |
|---|---|---|---|
| P1 | When people open the app at lunch or dinner, the restaurant list and menu pages should show up right away, even when thousands of people are ordering at once. (R01, R03, R25) | Customers | Customer-facing / real-time |
| P2 | When someone types "paneer" or "biryani", results should appear while they are still typing. If search lags, they will just give up and open another app. (R02) | Customers (Search team) | Customer-facing / real-time |
| P3 | Opening "Your orders" or a bill should feel instant. Right now customers sit and wait for seconds just to see a past order. (R04, R24) | Customers | Customer-facing / real-time |
| P4 | Restaurant owners want to open the partner app and immediately see today's orders and which dishes are selling. They can't wait seconds in the middle of a busy kitchen. (R06, R07, R08, W03) | Restaurant partners | Customer-facing / real-time (R07, R08 are closer to analytics) |
| P5 | Dispatch screens (orders with no rider, kitchens running late) must refresh every few seconds, or orders get stuck and customers wait. (R05, R12, W01, W02) | Dispatch / Ops | Real-time |
| P6 | The fleet team's "idle riders" list came back empty, which can't be right. This is a correctness problem, not just speed: the query gives a wrong answer. (R11, R13) | Fleet / delivery partners | Real-time (R11) and reporting (R13) |
| P7 | Payments and risk teams need to spot failed payments and suspicious customers quickly, ideally within seconds or minutes, so they can act before more money or trust is lost. (R16, R17) | Payments / Risk | Near-real-time reporting (R16 covers the last 7 days; R17 scans all history) |
| P8 | Gold, coupon and growth reports currently time out, so the marketing and Gold teams can't see how their offers and members are performing. (R14, R15, R20, R21, W05) | Gold team / Marketing | Reporting / analytics (W05 is a nightly batch job) |
| P9 | Support agents need to quickly find late deliveries and angry reviews so they can help unhappy customers while it still matters. (R10, R18) | Customer support | Interactive search, close to real-time |
| P10 | Leadership dashboards (delivery times, order heatmaps, restaurant health) are slow, and order volume will grow 20 times next year, so they must keep working at scale. (R09, R19, R22, R23, W04) | Ops / Leadership / Admin | Reporting / analytics (W04 is a nightly batch job) |

**Why the split:** P1 to P5 are customer-facing or real-time because a person is waiting on a screen (customer, restaurant owner, dispatcher), so each query has to finish in milliseconds. P7 and P9 are interactive: they need to be fast, but not instant. P8 and P10 are reporting/analytics: they scan a lot of data, so a few seconds is acceptable, but they must not time out. P6 is a correctness problem as well as a speed problem.

## Assumptions

- The data is the 150,000-order seed export (1 Jan 2025 to 30 Jun 2026), and the "current date" used in the queries is about 30 Jun / 1 Jul 2026.
- "Real-time" means a few milliseconds, "interactive" means under a quarter of a second, and "reporting" can take a few seconds.
- Order volume will grow about 20 times, so every fix must still work at about 3 million orders.
- Query results must stay the same after optimization.
- The schema is not documented, so we infer it from the CSV files.
