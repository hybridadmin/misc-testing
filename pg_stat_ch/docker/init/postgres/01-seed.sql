-- ============================================================================
-- PostgreSQL init: enable pg_stat_ch and create a demo schema with sample data
-- ============================================================================
-- This script runs automatically on first boot via docker-entrypoint-initdb.d.
-- It creates the extension, builds a small e-commerce schema, seeds realistic
-- data, and then runs a variety of queries so that pg_stat_ch captures a rich
-- set of telemetry events for analysis in ClickHouse.
-- ============================================================================

-- 1. Enable the extension
CREATE EXTENSION IF NOT EXISTS pg_stat_ch;

-- Verify it loaded
SELECT pg_stat_ch_version();

-- ============================================================================
-- 2. Demo schema: a small e-commerce database
-- ============================================================================

CREATE TABLE customers (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    email       TEXT UNIQUE NOT NULL,
    city        TEXT,
    created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE products (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    category    TEXT NOT NULL,
    price       NUMERIC(10,2) NOT NULL,
    stock       INT DEFAULT 0
);

CREATE TABLE orders (
    id           SERIAL PRIMARY KEY,
    customer_id  INT REFERENCES customers(id),
    product_id   INT REFERENCES products(id),
    quantity     INT NOT NULL DEFAULT 1,
    total        NUMERIC(10,2),
    status       TEXT DEFAULT 'pending',
    ordered_at   TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_orders_customer  ON orders(customer_id);
CREATE INDEX idx_orders_product   ON orders(product_id);
CREATE INDEX idx_orders_status    ON orders(status);
CREATE INDEX idx_orders_date      ON orders(ordered_at);
CREATE INDEX idx_products_cat     ON products(category);

-- ============================================================================
-- 3. Seed data
-- ============================================================================

-- 200 customers
INSERT INTO customers (name, email, city)
SELECT
    'Customer ' || i,
    'customer' || i || '@example.com',
    (ARRAY['New York','London','Berlin','Tokyo','Sydney','Toronto','Paris',
           'Mumbai','Singapore','Sao Paulo'])[1 + (i % 10)]
FROM generate_series(1, 200) AS s(i);

-- 50 products across categories
INSERT INTO products (name, category, price, stock)
SELECT
    'Product ' || i,
    (ARRAY['Electronics','Books','Clothing','Home','Sports','Food',
           'Toys','Beauty','Auto','Garden'])[1 + (i % 10)],
    round((random() * 500 + 5)::numeric, 2),
    (random() * 1000)::int
FROM generate_series(1, 50) AS s(i);

-- 5 000 orders spread over the last 90 days
INSERT INTO orders (customer_id, product_id, quantity, total, status, ordered_at)
SELECT
    1 + (random() * 199)::int,
    1 + (random() * 49)::int,
    1 + (random() * 5)::int,
    round((random() * 2000 + 10)::numeric, 2),
    (ARRAY['pending','shipped','delivered','returned','cancelled'])[1 + (i % 5)],
    now() - (random() * interval '90 days')
FROM generate_series(1, 5000) AS s(i);

-- ============================================================================
-- 4. Run a variety of queries to generate telemetry events
-- ============================================================================

-- Simple point lookups
SELECT * FROM customers WHERE id = 42;
SELECT * FROM products  WHERE id = 7;

-- Aggregations
SELECT category, count(*), avg(price), max(price)
FROM products
GROUP BY category
ORDER BY avg(price) DESC;

-- Join + filter
SELECT c.name, count(o.id) AS order_count, sum(o.total) AS spend
FROM customers c
JOIN orders o ON o.customer_id = c.id
WHERE o.status = 'delivered'
GROUP BY c.name
ORDER BY spend DESC
LIMIT 20;

-- Time-series: daily revenue
SELECT date_trunc('day', ordered_at) AS day,
       count(*)                      AS orders,
       sum(total)                    AS revenue
FROM orders
GROUP BY day
ORDER BY day;

-- Subquery / CTE
WITH top_products AS (
    SELECT product_id, sum(total) AS revenue
    FROM orders
    GROUP BY product_id
    ORDER BY revenue DESC
    LIMIT 10
)
SELECT p.name, p.category, tp.revenue
FROM top_products tp
JOIN products p ON p.id = tp.product_id;

-- Write operations (INSERT / UPDATE / DELETE)
INSERT INTO orders (customer_id, product_id, quantity, total, status)
SELECT
    1 + (random() * 199)::int,
    1 + (random() * 49)::int,
    1,
    round((random() * 100 + 10)::numeric, 2),
    'pending'
FROM generate_series(1, 100) AS s(i);

UPDATE orders SET status = 'shipped' WHERE status = 'pending' AND ordered_at < now() - interval '30 days';

DELETE FROM orders WHERE status = 'cancelled' AND ordered_at < now() - interval '60 days';

-- Intentional errors to populate error telemetry
DO $$
BEGIN
    -- Table does not exist → generates an error event
    EXECUTE 'SELECT * FROM nonexistent_table';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;

DO $$
BEGIN
    -- Duplicate key → unique violation
    INSERT INTO customers (id, name, email) VALUES (1, 'Duplicate', 'dup@example.com');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;

-- Sequential scan on a larger result set (temp files / work_mem pressure demo)
SET work_mem = '64kB';
SELECT o.*, c.name, p.name AS product_name
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN products p ON p.id = o.product_id
ORDER BY o.total DESC;
RESET work_mem;

-- Force a full table scan with no index
SELECT count(*) FROM orders WHERE total BETWEEN 100 AND 200;

-- ============================================================================
-- Done — telemetry events should now be flowing to ClickHouse
-- ============================================================================
