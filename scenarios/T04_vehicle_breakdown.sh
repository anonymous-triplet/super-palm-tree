#!/usr/bin/env bash
# T04 · Vehicle breakdown
# A car breaks down in its lane; the driver calls for police and a tow.
# Starts the whole city, waits until every system is up and steady, triggers the scenario one second later, follows it
# to the end and closes everything ten seconds after the last activity. The run log is written to logs/.
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/run_control_room.sh" --scenario T04 "$@"
