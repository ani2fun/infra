-- Lab seed: customers -> orders -> order_items, with real foreign keys so schema browsing in
-- Bytebase has a relationship graph to show, not just flat tables.
--
-- Idempotent: safe to run on every lab-up. Tables use IF NOT EXISTS and rows use explicit ids
-- with ON CONFLICT DO NOTHING, so re-running never duplicates or errors.

CREATE TABLE IF NOT EXISTS customers (
    id          integer PRIMARY KEY,
    name        text        NOT NULL,
    email       text        NOT NULL UNIQUE,
    country     text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS products (
    id       integer PRIMARY KEY,
    sku      text          NOT NULL UNIQUE,
    name     text          NOT NULL,
    category text          NOT NULL,
    price    numeric(10,2) NOT NULL
);

CREATE TABLE IF NOT EXISTS orders (
    id          integer PRIMARY KEY,
    customer_id integer     NOT NULL REFERENCES customers(id),
    status      text        NOT NULL,
    placed_at   timestamptz NOT NULL,
    total       numeric(10,2) NOT NULL
);

CREATE TABLE IF NOT EXISTS order_items (
    order_id   integer NOT NULL REFERENCES orders(id),
    product_id integer NOT NULL REFERENCES products(id),
    quantity   integer NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (order_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_status   ON orders(status);

INSERT INTO customers (id, name, email, country)
SELECT g,
       'Customer ' || g,
       'customer' || g || '@example.invalid',
       (ARRAY['NL','DE','FR','IN','US','GB'])[1 + (g % 6)]
FROM generate_series(1, 25) g
ON CONFLICT (id) DO NOTHING;

INSERT INTO products (id, sku, name, category, price)
SELECT g,
       'SKU-' || lpad(g::text, 4, '0'),
       (ARRAY['Widget','Gadget','Doohickey','Sprocket','Gizmo'])[1 + (g % 5)] || ' ' || g,
       (ARRAY['tools','toys','office','kitchen'])[1 + (g % 4)],
       round((5 + (g * 3.7))::numeric, 2)
FROM generate_series(1, 30) g
ON CONFLICT (id) DO NOTHING;

INSERT INTO orders (id, customer_id, status, placed_at, total)
SELECT g,
       1 + (g % 25),
       (ARRAY['pending','paid','shipped','delivered','cancelled'])[1 + (g % 5)],
       timestamptz '2026-01-01 00:00:00+00' + (g || ' days')::interval,
       round((20 + (g * 11.3))::numeric, 2)
FROM generate_series(1, 40) g
ON CONFLICT (id) DO NOTHING;

INSERT INTO order_items (order_id, product_id, quantity)
SELECT g, 1 + (g % 30), 1 + (g % 4)
FROM generate_series(1, 40) g
ON CONFLICT (order_id, product_id) DO NOTHING;

SELECT 'customers'   AS table, count(*) FROM customers
UNION ALL SELECT 'products',   count(*) FROM products
UNION ALL SELECT 'orders',     count(*) FROM orders
UNION ALL SELECT 'order_items',count(*) FROM order_items;
