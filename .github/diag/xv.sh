#!/usr/bin/env bash
# Run a command under Xvfb. XVFB_SCREEN (e.g. 1280x1024x24) overrides xvfb-run's default
# screen, which is 8 bits deep.
set -euo pipefail
if [ -n "${XVFB_SCREEN:-}" ]; then
  exec xvfb-run --auto-servernum --server-args="-screen 0 ${XVFB_SCREEN}" "$@"
fi
exec xvfb-run --auto-servernum "$@"
