-- Load the seed data. Run from the project root so the seed_data/ paths work.
-- Parents first, children after, so the foreign keys are satisfied.
SET search_path TO zomato;

\copy cities           FROM 'seed_data/cities.csv'           WITH (FORMAT csv, HEADER true)
\copy localities       FROM 'seed_data/localities.csv'       WITH (FORMAT csv, HEADER true)
\copy customers        FROM 'seed_data/customers.csv'        WITH (FORMAT csv, HEADER true)
\copy restaurants      FROM 'seed_data/restaurants.csv'      WITH (FORMAT csv, HEADER true)
\copy menu_items       FROM 'seed_data/menu_items.csv'       WITH (FORMAT csv, HEADER true)
\copy delivery_partners FROM 'seed_data/delivery_partners.csv' WITH (FORMAT csv, HEADER true)
\copy coupons          FROM 'seed_data/coupons.csv'          WITH (FORMAT csv, HEADER true)
\copy orders           FROM 'seed_data/orders.csv'           WITH (FORMAT csv, HEADER true)
\copy order_items      FROM 'seed_data/order_items.csv'      WITH (FORMAT csv, HEADER true)
\copy payments         FROM 'seed_data/payments.csv'         WITH (FORMAT csv, HEADER true)
\copy reviews          FROM 'seed_data/reviews.csv'          WITH (FORMAT csv, HEADER true)

ANALYZE;