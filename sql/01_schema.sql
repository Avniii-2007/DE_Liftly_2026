-- Zomato Food Delivery Database: schema (Phase 2)
-- Run on an empty database: psql -d zomato_db -f sql/01_schema.sql

DROP SCHEMA IF EXISTS zomato CASCADE;   -- lets us re-run the file from scratch
CREATE SCHEMA zomato;
SET search_path TO zomato;

-- 1. cities
CREATE TABLE cities (
    city_id    INTEGER     PRIMARY KEY,
    city_name  VARCHAR(50) NOT NULL UNIQUE,
    state      VARCHAR(50) NOT NULL
);

-- 2. localities (each belongs to one city)
CREATE TABLE localities (
    locality_id    INTEGER     PRIMARY KEY,
    city_id        INTEGER     NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    locality_name  VARCHAR(60) NOT NULL,
    pincode        CHAR(6)     NOT NULL,
    CONSTRAINT uq_localities_city_name UNIQUE (city_id, locality_name),
    CONSTRAINT chk_localities_pincode  CHECK (pincode ~ '^[0-9]{6}$')
);

-- 3. customers
CREATE TABLE customers (
    customer_id      INTEGER      PRIMARY KEY,
    full_name        VARCHAR(100) NOT NULL,
    email            VARCHAR(100) NOT NULL UNIQUE,
    phone            CHAR(10)     NOT NULL UNIQUE,
    city_id          INTEGER      NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    signup_date      DATE         NOT NULL,
    is_gold_member   BOOLEAN      NOT NULL DEFAULT FALSE,
    gold_expires_on  DATE,
    is_active        BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_customers_email CHECK (position('@' IN email) > 1),
    CONSTRAINT chk_customers_phone CHECK (phone ~ '^[0-9]{10}$'),
    -- a Gold member must have an expiry date. (We do NOT force the date to be
    -- empty for non-Gold users, because W05 sets is_gold_member = FALSE and
    -- leaves the old expiry date in place.)
    CONSTRAINT chk_customers_gold CHECK (NOT is_gold_member OR gold_expires_on IS NOT NULL)
);

-- 4. restaurants
CREATE TABLE restaurants (
    restaurant_id     INTEGER      PRIMARY KEY,
    name              VARCHAR(100) NOT NULL,
    locality_id       INTEGER      NOT NULL REFERENCES localities(locality_id) ON DELETE RESTRICT,
    cuisines          TEXT[]       NOT NULL,
    avg_cost_for_two  INTEGER      NOT NULL,
    rating            NUMERIC(2,1),            -- empty for restaurants with no reviews yet
    rating_count      INTEGER      NOT NULL DEFAULT 0,
    opens_at          TIME         NOT NULL,
    closes_at         TIME         NOT NULL,
    is_pure_veg       BOOLEAN      NOT NULL,
    status            VARCHAR(25)  NOT NULL,
    onboarded_on      DATE         NOT NULL,
    CONSTRAINT chk_restaurants_status CHECK (status IN ('OPEN', 'TEMPORARILY_CLOSED', 'DELISTED')),
    CONSTRAINT chk_restaurants_cost   CHECK (avg_cost_for_two > 0),
    CONSTRAINT chk_restaurants_rating CHECK (rating IS NULL OR rating BETWEEN 1 AND 5),
    CONSTRAINT chk_restaurants_count  CHECK (rating_count >= 0),
    CONSTRAINT chk_restaurants_hours  CHECK (opens_at < closes_at)
);

-- 5. menu_items (a dish belongs to one restaurant)
CREATE TABLE menu_items (
    item_id        INTEGER       PRIMARY KEY,
    restaurant_id  INTEGER       NOT NULL REFERENCES restaurants(restaurant_id) ON DELETE CASCADE,
    item_name      VARCHAR(100)  NOT NULL,
    category       VARCHAR(30)   NOT NULL,
    price          NUMERIC(10,2) NOT NULL,
    is_veg         BOOLEAN       NOT NULL,
    is_bestseller  BOOLEAN       NOT NULL DEFAULT FALSE,
    is_available   BOOLEAN       NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_menu_items_price    CHECK (price > 0),
    CONSTRAINT chk_menu_items_category CHECK (category IN
        ('Main Course', 'Breads', 'Rice', 'Desserts', 'Beverages', 'Starters'))
);

-- 6. delivery_partners
CREATE TABLE delivery_partners (
    partner_id    INTEGER      PRIMARY KEY,
    full_name     VARCHAR(100) NOT NULL,
    phone         CHAR(10)     NOT NULL UNIQUE,
    city_id       INTEGER      NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    vehicle_type  VARCHAR(15)  NOT NULL,
    joined_on     DATE         NOT NULL,
    rating        NUMERIC(2,1) NOT NULL,
    status        VARCHAR(15)  NOT NULL,
    CONSTRAINT chk_partners_phone   CHECK (phone ~ '^[0-9]{10}$'),
    CONSTRAINT chk_partners_vehicle CHECK (vehicle_type IN ('SCOOTER', 'BICYCLE', 'BIKE', 'EV')),
    CONSTRAINT chk_partners_rating  CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT chk_partners_status  CHECK (status IN ('ACTIVE', 'INACTIVE', 'BLOCKED'))
);

-- 7. coupons
CREATE TABLE coupons (
    coupon_code      VARCHAR(20)   PRIMARY KEY,
    discount_pct     SMALLINT      NOT NULL,
    max_discount     NUMERIC(10,2) NOT NULL,
    min_order_value  NUMERIC(10,2) NOT NULL,
    valid_from       DATE          NOT NULL,
    valid_to         DATE          NOT NULL,
    CONSTRAINT chk_coupons_pct   CHECK (discount_pct BETWEEN 1 AND 100),
    CONSTRAINT chk_coupons_max   CHECK (max_discount > 0),
    CONSTRAINT chk_coupons_min   CHECK (min_order_value >= 0),
    CONSTRAINT chk_coupons_dates CHECK (valid_from <= valid_to)
);

-- 8. orders
CREATE TABLE orders (
    order_id       INTEGER       PRIMARY KEY,
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

    -- time order: placed -> accepted -> picked up -> delivered
    CONSTRAINT chk_orders_t_accept  CHECK (accepted_at  IS NULL OR accepted_at  >= placed_at),
    CONSTRAINT chk_orders_t_pickup  CHECK (picked_up_at IS NULL OR (accepted_at IS NOT NULL AND picked_up_at >= accepted_at)),
    CONSTRAINT chk_orders_t_deliver CHECK (delivered_at IS NULL OR (picked_up_at IS NOT NULL AND delivered_at >= picked_up_at)),

    -- which columns must be filled depends on the status
    CONSTRAINT chk_orders_delivered CHECK (status <> 'DELIVERED' OR
        (partner_id IS NOT NULL AND accepted_at IS NOT NULL AND picked_up_at IS NOT NULL AND delivered_at IS NOT NULL)),
    CONSTRAINT chk_orders_ofd       CHECK (status <> 'OUT_FOR_DELIVERY' OR
        (partner_id IS NOT NULL AND picked_up_at IS NOT NULL AND delivered_at IS NULL)),
    CONSTRAINT chk_orders_preparing CHECK (status <> 'PREPARING' OR
        (partner_id IS NOT NULL AND accepted_at IS NOT NULL AND picked_up_at IS NULL)),
    CONSTRAINT chk_orders_accepted  CHECK (status <> 'ACCEPTED' OR (accepted_at IS NOT NULL AND picked_up_at IS NULL)),
    CONSTRAINT chk_orders_fresh     CHECK (status NOT IN ('PLACED', 'CANCELLED_BY_RESTAURANT') OR
        (partner_id IS NULL AND accepted_at IS NULL AND picked_up_at IS NULL AND delivered_at IS NULL)),
    CONSTRAINT chk_orders_deliv_only CHECK (delivered_at IS NULL OR status = 'DELIVERED')
);

-- 9. order_items (M:N between orders and menu_items)
CREATE TABLE order_items (
    order_id    INTEGER       NOT NULL REFERENCES orders(order_id)      ON DELETE CASCADE,
    item_id     INTEGER       NOT NULL REFERENCES menu_items(item_id)   ON DELETE RESTRICT,
    quantity    SMALLINT      NOT NULL,
    unit_price  NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, item_id),
    CONSTRAINT chk_order_items_qty   CHECK (quantity > 0),
    CONSTRAINT chk_order_items_price CHECK (unit_price > 0)
);

-- 10. payments (an order can have several attempts)
CREATE TABLE payments (
    payment_id      INTEGER       PRIMARY KEY,
    order_id        INTEGER       NOT NULL REFERENCES orders(order_id) ON DELETE RESTRICT,
    amount          NUMERIC(10,2) NOT NULL,
    method          VARCHAR(10)   NOT NULL,
    payment_status  VARCHAR(10)   NOT NULL,
    attempted_at    TIMESTAMPTZ   NOT NULL,
    CONSTRAINT chk_payments_amount CHECK (amount > 0),
    CONSTRAINT chk_payments_method CHECK (method IN ('COD', 'UPI', 'CARD', 'WALLET')),
    CONSTRAINT chk_payments_status CHECK (payment_status IN ('SUCCESS', 'FAILED', 'REFUNDED'))
);

-- 11. reviews (at most one review per order)
CREATE TABLE reviews (
    review_id        INTEGER     PRIMARY KEY,
    order_id         INTEGER     NOT NULL UNIQUE REFERENCES orders(order_id)           ON DELETE CASCADE,
    customer_id      INTEGER     NOT NULL REFERENCES customers(customer_id)            ON DELETE RESTRICT,
    restaurant_id    INTEGER     NOT NULL REFERENCES restaurants(restaurant_id)        ON DELETE RESTRICT,
    food_rating      SMALLINT    NOT NULL,
    delivery_rating  SMALLINT,
    review_text      TEXT,
    created_at       TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_reviews_food     CHECK (food_rating BETWEEN 1 AND 5),
    CONSTRAINT chk_reviews_delivery CHECK (delivery_rating IS NULL OR delivery_rating BETWEEN 1 AND 5)
);