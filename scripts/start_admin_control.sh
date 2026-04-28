#!/usr/bin/env bash
set -euo pipefail

cd /root/.openclaw/AliceChat
mkdir -p /root/.openclaw/AliceChat/data/admin_control
nohup python3 -m backend.admin_control --host 127.0.0.1 --port 18082 > /tmp/alicechat-admin-control.log 2>&1 &
