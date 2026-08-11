#!/bin/sh
# Lab seed: one `products` index with an EXPLICIT mapping (dynamic mapping disabled) plus a
# bulk load. Explicit typing matters here — with dynamic mapping every number arrives as a
# guess, and price/rating sort order becomes meaningless.
#
# Idempotent: index creation tolerates resource_already_exists_exception, and every _bulk line
# carries a fixed _id so re-running overwrites rather than appending duplicates.
set -eu

ES="${ES_HOST:-http://elasticsearch:9200}"

echo "--- creating index with explicit mapping ---"
code=$(curl -s -o /tmp/es-create.out -w '%{http_code}' -X PUT "$ES/products" \
  -H 'Content-Type: application/json' -d '{
  "settings": { "number_of_shards": 1, "number_of_replicas": 0 },
  "mappings": {
    "dynamic": "strict",
    "properties": {
      "sku":       { "type": "keyword" },
      "name":      { "type": "text" },
      "category":  { "type": "keyword" },
      "price":     { "type": "scaled_float", "scaling_factor": 100 },
      "rating":    { "type": "half_float" },
      "in_stock":  { "type": "boolean" },
      "tags":      { "type": "keyword" },
      "added_at":  { "type": "date" }
    }
  }
}')
if [ "$code" = "200" ]; then
  echo "index created"
elif grep -q resource_already_exists_exception /tmp/es-create.out 2>/dev/null; then
  echo "index already exists — fine"
else
  echo "unexpected response ($code):"; cat /tmp/es-create.out; exit 1
fi

echo "--- bulk loading 30 docs ---"
: > /tmp/es-bulk.ndjson
i=1
while [ "$i" -le 30 ]; do
  cat_idx=$((i % 4))
  case $cat_idx in
    0) category=tools ;;
    1) category=toys ;;
    2) category=office ;;
    *) category=kitchen ;;
  esac
  stock=true
  [ $((i % 5)) -eq 0 ] && stock=false
  printf '{"index":{"_index":"products","_id":"%d"}}\n' "$i" >> /tmp/es-bulk.ndjson
  printf '{"sku":"SKU-%04d","name":"Product %d","category":"%s","price":%d.%02d,"rating":%d.%d,"in_stock":%s,"tags":["lab","seed"],"added_at":"2026-01-%02dT00:00:00Z"}\n' \
    "$i" "$i" "$category" $((5 + i * 3)) $((i * 7 % 100)) $((1 + i % 5)) $((i % 10)) "$stock" $((1 + i % 28)) >> /tmp/es-bulk.ndjson
  i=$((i + 1))
done

curl -s -X POST "$ES/_bulk" -H 'Content-Type: application/x-ndjson' \
  --data-binary @/tmp/es-bulk.ndjson > /tmp/es-bulk.out
if grep -q '"errors":true' /tmp/es-bulk.out; then
  echo "bulk load reported errors:"; head -c 800 /tmp/es-bulk.out; exit 1
fi

curl -s -X POST "$ES/products/_refresh" >/dev/null
echo "count: $(curl -s "$ES/products/_count" | sed 's/.*"count":\([0-9]*\).*/\1/')"
