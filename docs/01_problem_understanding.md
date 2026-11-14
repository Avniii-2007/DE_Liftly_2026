# Phase 1: Problem Understanding

| # | What the business needs | Who is affected | Type |
|---|---|---|---|
| P1 | When people open the app at lunch or dinner, the restaurant list and menu pages should load right away, even when thousands of people are ordering at once. (R01, R03, R25) | Customers | Customer-facing / real-time |
| P2 | When someone types "paneer" or "biryani", results should appear while they are still typing. If search lags, they give up and open another app. (R02) | Customers (Search team) | Customer-facing / real-time |
| P3 | Opening "Your orders" or a bill should feel instant. Right now customers wait seconds just to see a past order. (R04, R24) | Customers | Customer-facing / real-time |
| P4 | Restaurant owners want to open the partner app and immediately see today's orders and which dishes are selling. They can't wait seconds in the middle of a busy kitchen. (R06, R07, R08, W03) | Restaurant partners | Customer-facing / real-time (R07, R08 lean towards analytics) |
| P5 | Dispatch screens (orders with no rider, kitchens running late) must refresh every few seconds, or orders get stuck and customers wait. (R05, R12, W01, W02) | Dispatch / Ops | Customer-facing / real-time |
| P6 | The fleet team's idle-rider list came back empty, which can't be right. This is a correctness problem as well as a speed problem: one query is giving a wrong answer. (R11, R13) | Fleet / delivery partners | Customer-facing / real-time (R11), reporting (R13) |
| P7 | Payments and risk teams need to spot failed payments and suspicious customers quickly, so they can act before more money or trust is lost. (R16, R17) | Payments / Risk | Customer-facing / real-time (R16 is the last 7 days, R17 scans all history) |
| P8 | Gold, coupon and growth reports time out, so the marketing and Gold teams can't see how their offers and members are performing. (R14, R15, R20, R21, W05) | Gold team / Marketing | Reporting / analytics (W05 is a nightly job) |
| P9 | Support agents need to find late deliveries and angry reviews fast, so they can help unhappy customers while it still matters. (R10, R18) | Customer support | Customer-facing / real-time (an agent is waiting on a screen) |
| P10 | Leadership dashboards (delivery times, order heatmaps, restaurant health) are slow, and order volume will grow 20 times next year, so they must keep working at scale. (R09, R19, R22, R23, W04) | Ops / Leadership / Admin | Reporting / analytics (W04 is a nightly job) |

**Why the split:** P1 to P7 and P9 have a person (or a team) waiting on a screen, so queries must finish in milliseconds (or at most a fraction of a second for search-type screens). P8 and P10 are reports that scan a lot of data, so a few seconds is acceptable, but they must not time out. P6 is also a correctness problem, because an empty list means the query result is wrong, not just slow.

## Assumptions

- The data is the 150,000-order seed export (1 Jan 2025 to 30 Jun 2026), and "today" in the queries is about 30 Jun / 1 Jul 2026.
- "Real-time" means a few milliseconds, "interactive" means under a quarter of a second, and "reporting" can take a few seconds.
- Order volume will grow about 20 times, so every fix must still work at about 3 million orders.
- Query results must stay the same after optimization.
- The schema is not documented, so we infer it from the CSV files.