#!/bin/sh
# Lab seed: a deliberate MIX of Redis types, because the point is to see how much variety
# Bytebase's Redis view can actually render — strings, hash, list, set, sorted set, and a
# key with a TTL.
#
# Idempotent by construction: SET/HSET/ZADD overwrite. The list is deleted first, since RPUSH
# would otherwise append a duplicate copy on every run.
set -eu

R="redis-cli -h ${REDIS_HOST:-redis} -a ${REDIS_PASSWORD} --no-auth-warning"

# --- strings ---------------------------------------------------------------
i=1
while [ "$i" -le 20 ]; do
  $R SET "product:$i:name" "Product $i" >/dev/null
  i=$((i + 1))
done
$R SET "config:currency" "EUR" >/dev/null
$R SET "session:demo" "expires-soon" EX 3600 >/dev/null   # a key with a TTL

# --- hash ------------------------------------------------------------------
$R HSET customer:1 name "Customer 1" email "customer1@example.invalid" country "NL" orders 4 >/dev/null
$R HSET customer:2 name "Customer 2" email "customer2@example.invalid" country "DE" orders 7 >/dev/null
$R HSET customer:3 name "Customer 3" email "customer3@example.invalid" country "IN" orders 2 >/dev/null

# --- list (recent orders, newest first) ------------------------------------
$R DEL recent_orders >/dev/null
i=1
while [ "$i" -le 15 ]; do
  $R RPUSH recent_orders "ORD-$(printf '%05d' "$i")" >/dev/null
  i=$((i + 1))
done

# --- set -------------------------------------------------------------------
$R DEL categories >/dev/null
$R SADD categories tools toys office kitchen >/dev/null

# --- sorted set (leaderboard by spend) -------------------------------------
i=1
while [ "$i" -le 20 ]; do
  $R ZADD top_customers "$((i * 37 % 500))" "Customer $i" >/dev/null
  i=$((i + 1))
done

echo "dbsize: $($R DBSIZE)"
echo "types:  string=$($R EXISTS config:currency) hash=$($R TYPE customer:1) list=$($R TYPE recent_orders) set=$($R TYPE categories) zset=$($R TYPE top_customers)"
