#!/usr/bin/env bash
set -euo pipefail

export HOME=/root
export USER=root
export LOGNAME=root
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

if [ -f /root/.bashrc ]; then
  source /root/.bashrc
fi
if [ -f /root/.profile ]; then
  source /root/.profile
fi

openclaw gateway restart
openclaw gateway status
