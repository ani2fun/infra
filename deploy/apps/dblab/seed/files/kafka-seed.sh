#!/bin/sh
# Lab seed: two topics with a handful of JSON messages each, so Kafbat UI's message browser
# has something to display instead of an empty topic list.
#
# Idempotent: topic creation uses --if-not-exists. Messages ARE appended on every run — Kafka
# is a log, so there is no upsert. Re-running simply adds more records, which is harmless here;
# lab-nuke.sh is the way back to a clean slate.
set -eu

BS="${KAFKA_BOOTSTRAP:-kafka:9092}"
K=/opt/kafka/bin

echo "--- creating topics ---"
$K/kafka-topics.sh --bootstrap-server "$BS" --create --if-not-exists \
  --topic orders --partitions 3 --replication-factor 1
$K/kafka-topics.sh --bootstrap-server "$BS" --create --if-not-exists \
  --topic customer-events --partitions 1 --replication-factor 1

echo "--- producing to orders ---"
i=1
while [ "$i" -le 15 ]; do
  printf '{"orderId":"ORD-%05d","customerId":%d,"status":"%s","total":%d.%02d,"placedAt":"2026-01-%02dT10:00:00Z"}\n' \
    "$i" $((1 + i % 8)) "$( [ $((i % 2)) -eq 0 ] && echo paid || echo pending )" \
    $((20 + i * 11)) $((i * 7 % 100)) $((1 + i % 28))
  i=$((i + 1))
done | $K/kafka-console-producer.sh --bootstrap-server "$BS" --topic orders

echo "--- producing to customer-events ---"
i=1
while [ "$i" -le 10 ]; do
  printf '{"customerId":%d,"event":"%s","at":"2026-01-%02dT12:00:00Z"}\n' \
    "$i" "$( [ $((i % 3)) -eq 0 ] && echo signup || echo login )" $((1 + i % 28))
  i=$((i + 1))
done | $K/kafka-console-producer.sh --bootstrap-server "$BS" --topic customer-events

echo "--- topics now ---"
$K/kafka-topics.sh --bootstrap-server "$BS" --list
