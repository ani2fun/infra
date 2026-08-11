#!/bin/sh
# Lab seed: one `Orders` table with a PARTITION key (customerId) and a SORT key (orderId),
# so the DynamoDB key model is actually exercised rather than a single-key table.
#
# Credentials are dummy on purpose — DynamoDB Local accepts anything. The container runs with
# -sharedDb, so the AWS CLI and Bytebase see the SAME table set regardless of which key they
# present. Without -sharedDb they would each get their own private, apparently-empty database.
#
# Idempotent: table creation tolerates ResourceInUseException, and PutItem overwrites by key.
set -eu

EP="${DDB_ENDPOINT:-http://dynamodb-local:8000}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-dummy}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-dummy}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-central-1}"

aws() { command aws --endpoint-url "$EP" "$@"; }

echo "--- creating table Orders ---"
if aws dynamodb describe-table --table-name Orders >/dev/null 2>&1; then
  echo "table already exists — fine"
else
  aws dynamodb create-table \
    --table-name Orders \
    --attribute-definitions AttributeName=customerId,AttributeType=S AttributeName=orderId,AttributeType=S \
    --key-schema AttributeName=customerId,KeyType=HASH AttributeName=orderId,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name Orders
  echo "table created"
fi

echo "--- writing 24 items ---"
statuses="pending paid shipped delivered cancelled"
i=1
while [ "$i" -le 24 ]; do
  cust=$((1 + i % 8))
  n=0
  status=pending
  for s in $statuses; do
    if [ "$n" -eq $((i % 5)) ]; then status="$s"; fi
    n=$((n + 1))
  done
  aws dynamodb put-item --table-name Orders --item "{
    \"customerId\": {\"S\": \"CUST-$(printf '%03d' "$cust")\"},
    \"orderId\":    {\"S\": \"ORD-$(printf '%05d' "$i")\"},
    \"status\":     {\"S\": \"$status\"},
    \"total\":      {\"N\": \"$((20 + i * 11)).$((i * 7 % 100))\"},
    \"placedAt\":   {\"S\": \"2026-01-$(printf '%02d' $((1 + i % 28)))T00:00:00Z\"},
    \"items\":      {\"L\": [{\"S\": \"SKU-$(printf '%04d' "$i")\"}, {\"S\": \"SKU-$(printf '%04d' $((i + 1)))\"}]}
  }" >/dev/null
  i=$((i + 1))
done

echo "count: $(aws dynamodb scan --table-name Orders --select COUNT --query 'Count' --output text)"
