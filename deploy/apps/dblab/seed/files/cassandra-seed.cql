-- Lab seed: SimpleStrategy RF=1 (single node) and a table with a COMPOUND primary key —
-- partition key customer_id, clustering key order_id — so Bytebase has to render a
-- non-trivial Cassandra key structure rather than a plain rowset.
--
-- Idempotent: IF NOT EXISTS on the DDL, and Cassandra INSERTs are upserts by nature.

CREATE KEYSPACE IF NOT EXISTS lab
  WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};

USE lab;

CREATE TABLE IF NOT EXISTS orders_by_customer (
    customer_id int,
    order_id    int,
    status      text,
    total       decimal,
    placed_at   timestamp,
    items       list<text>,
    PRIMARY KEY ((customer_id), order_id)
) WITH CLUSTERING ORDER BY (order_id DESC);

CREATE TABLE IF NOT EXISTS products (
    sku      text PRIMARY KEY,
    name     text,
    category text,
    price    decimal
);

INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (1, 1001, 'paid',      120.50, '2026-01-02 10:00:00+0000', ['SKU-0001','SKU-0002']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (1, 1002, 'shipped',    75.00, '2026-01-05 11:30:00+0000', ['SKU-0003']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (1, 1003, 'delivered', 310.25, '2026-01-09 09:15:00+0000', ['SKU-0004','SKU-0005','SKU-0006']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (2, 2001, 'pending',    42.10, '2026-01-03 14:00:00+0000', ['SKU-0007']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (2, 2002, 'paid',      215.75, '2026-01-11 16:45:00+0000', ['SKU-0008','SKU-0009']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (3, 3001, 'cancelled',  18.99, '2026-01-04 08:20:00+0000', ['SKU-0010']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (3, 3002, 'delivered', 640.00, '2026-01-12 12:05:00+0000', ['SKU-0011','SKU-0012','SKU-0013']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (4, 4001, 'paid',       99.99, '2026-01-06 17:10:00+0000', ['SKU-0014']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (4, 4002, 'shipped',   150.00, '2026-01-13 19:25:00+0000', ['SKU-0015','SKU-0016']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (5, 5001, 'pending',    27.40, '2026-01-07 07:55:00+0000', ['SKU-0017']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (5, 5002, 'paid',      480.60, '2026-01-14 21:40:00+0000', ['SKU-0018','SKU-0019']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (6, 6001, 'delivered', 205.15, '2026-01-08 13:35:00+0000', ['SKU-0020']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (6, 6002, 'shipped',    62.80, '2026-01-15 10:50:00+0000', ['SKU-0021','SKU-0022']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (7, 7001, 'paid',      355.00, '2026-01-10 15:05:00+0000', ['SKU-0023','SKU-0024']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (7, 7002, 'cancelled',  88.25, '2026-01-16 18:15:00+0000', ['SKU-0025']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (8, 8001, 'delivered', 133.45, '2026-01-17 09:00:00+0000', ['SKU-0026','SKU-0027']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (8, 8002, 'pending',   276.90, '2026-01-18 11:20:00+0000', ['SKU-0028']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (9, 9001, 'paid',       54.30, '2026-01-19 14:40:00+0000', ['SKU-0029','SKU-0030']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (9, 9002, 'shipped',   412.00, '2026-01-20 16:55:00+0000', ['SKU-0001','SKU-0005']);
INSERT INTO orders_by_customer (customer_id, order_id, status, total, placed_at, items) VALUES (10, 10001, 'delivered', 190.70, '2026-01-21 20:10:00+0000', ['SKU-0002','SKU-0009']);

INSERT INTO products (sku, name, category, price) VALUES ('SKU-0001', 'Widget 1',    'tools',   8.70);
INSERT INTO products (sku, name, category, price) VALUES ('SKU-0002', 'Gadget 2',    'toys',   12.40);
INSERT INTO products (sku, name, category, price) VALUES ('SKU-0003', 'Doohickey 3', 'office', 16.10);
INSERT INTO products (sku, name, category, price) VALUES ('SKU-0004', 'Sprocket 4',  'kitchen',19.80);
INSERT INTO products (sku, name, category, price) VALUES ('SKU-0005', 'Gizmo 5',     'tools',  23.50);
INSERT INTO products (sku, name, category, price) VALUES ('SKU-0006', 'Widget 6',    'toys',   27.20);
INSERT INTO products (sku, name, category, price) VALUES ('SKU-0007', 'Gadget 7',    'office', 30.90);
INSERT INTO products (sku, name, category, price) VALUES ('SKU-0008', 'Doohickey 8', 'kitchen',34.60);
INSERT INTO products (sku, name, category, price) VALUES ('SKU-0009', 'Sprocket 9',  'tools',  38.30);
INSERT INTO products (sku, name, category, price) VALUES ('SKU-0010', 'Gizmo 10',    'toys',   42.00);

SELECT count(*) FROM orders_by_customer;
