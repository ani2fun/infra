#!/usr/bin/env bash
set -euo pipefail

SSH_HOST="root@172.27.15.11"
LOCAL_PORT="15432"
POD_IP="10.42.147.100"

exec ssh -N -L "${LOCAL_PORT}:${POD_IP}:5432" "$SSH_HOST"