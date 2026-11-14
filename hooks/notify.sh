#!/bin/bash
# CCNotify hook entry point: `notify.sh <stop|notification|prompt|session-start|session-end>`.
# All logic lives in notify.py (reads the hook JSON from stdin).
exec /usr/bin/env python3 "$(dirname "$0")/notify.py" "$@"
