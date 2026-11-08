#!/usr/bin/env bash
# T03 · Head-on crash after an unsafe overtake
# An overtaking car meets oncoming traffic; a severe crash with every service involved.
# Starts the whole city, waits until every system is up and steady, triggers the scenario one second later, follows it
# to the end and closes everything ten seconds after the last activity. The run log is written to logs/.
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/run_control_room.sh" --scenario T03 "$@"
