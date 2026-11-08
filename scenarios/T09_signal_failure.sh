#!/usr/bin/env bash
# T09 · Traffic signal failure
# A junction's signals fail; police direct traffic until the repair.
# Starts the whole city, waits until every system is up and steady, triggers the scenario one second later, follows it
# to the end and closes everything ten seconds after the last activity. The run log is written to logs/.
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/run_control_room.sh" --scenario T09 "$@"
