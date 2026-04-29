#!/usr/bin/env bash
set -euo pipefail

export HOME=/root
export USER=root
export LOGNAME=root
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

if ! command -v openclaw >/dev/null 2>&1; then
  export PATH="/root/.nvm/versions/node/v22.22.1/bin:/root/.local/share/pnpm:${PATH}"
fi

openclaw gateway restart
openclaw gateway status
