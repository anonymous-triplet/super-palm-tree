#!/usr/bin/env python3
"""Small jobs for run_control_room.sh that are easier in Python than in shell (standard library only).

    launcher_tasks.py identities        key pairs the launcher must keep valid: "<dir>|<name>|<host,host>" per line
    launcher_tasks.py manage-keys       "yes" when twin.conf lets the launcher create the keys
    launcher_tasks.py standins          the stand-ins to start: "<role>|<script>|<host>|<port>"
    launcher_tasks.py consistency       problems between twin.conf and mocks/standins.conf (nothing printed when they agree)
    launcher_tasks.py endpoints         every address this machine must listen on: "<who>|<host>|<port>"
    launcher_tasks.py port-owner PORT   whether a TCP port on 127.0.0.1 is taken ("free" / "taken")
    launcher_tasks.py free-port tcp|udp a free local port
"""
from __future__ import annotations

import socket
import sys
from pathlib import Path
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
TWIN = HERE.parents[1]
sys.path.insert(0, str(HERE / "mcp"))

import layer_config  # noqa: E402

CONF = TWIN / "twin.conf"
STANDINS = TWIN / "mocks" / "standins.conf"
SCRIPTS = {"brain": TWIN / "mocks" / "brain_standin.py", "guardian": TWIN / "mocks" / "guardian_standin.py"}


def _twin():
    parser = layer_config.read(CONF)
    return parser, layer_config.endpoint(parser, "twin", CONF.parent), layer_config.partners(parser), layer_config.clients(parser, CONF.parent)


def identities() -> None:
    parser, twin, partners, clients = _twin()
    print(f"{twin.certificate.parent}|{twin.identity}|{','.join(twin.hostnames)}")
    for client in clients:
        print(f"{client.certificate.parent}|{client.identity}|localhost,127.0.0.1")
    standins = layer_config.read(STANDINS)
    for partner in partners:
        if partner.standin and standins.has_section(partner.role):
            endpoint = layer_config.endpoint(standins, partner.role, STANDINS.parent)
            print(f"{endpoint.certificate.parent}|{endpoint.identity}|{','.join(endpoint.hostnames)}")


def manage_keys() -> None:
    parser, *_ = _twin()
    print("yes" if parser["twin"].get("manage_keys", "yes").strip().lower() in ("yes", "true", "1", "on") else "no")


def standins() -> None:
    _parser, _twin_endpoint, partners, _clients = _twin()
    parser = layer_config.read(STANDINS)
    for partner in partners:
        if partner.standin and partner.role in SCRIPTS and parser.has_section(partner.role):
            endpoint = layer_config.endpoint(parser, partner.role, STANDINS.parent)
            print(f"{partner.role}|{SCRIPTS[partner.role]}|{endpoint.listen_host}|{endpoint.listen_port}")


def consistency() -> int:
    problems = []
    _parser, twin, partners, _clients = _twin()
    parser = layer_config.read(STANDINS)
    roles = {partner.role: partner for partner in partners}
    for partner in partners:
        if not partner.standin:
            continue
        if not parser.has_section(partner.role):
            problems.append(f"twin.conf starts a {partner.role} stand-in but mocks/standins.conf has no [{partner.role}] section")
            continue
        endpoint = layer_config.endpoint(parser, partner.role, STANDINS.parent)
        url = urlsplit(partner.url)
        if (url.port, url.path or "/mcp") != (endpoint.listen_port, endpoint.path):
            problems.append(f"[partner:{partner.role}] url {partner.url} but the stand-in listens at {endpoint.url}")
        if partner.identity != endpoint.identity:
            problems.append(f"[partner:{partner.role}] identity '{partner.identity}' but the stand-in's certificate is '{endpoint.identity}'")
        data = parser[partner.role]
        twin_url = urlsplit(data.get("twin_url", ""))
        if (twin_url.port, twin_url.path or "/mcp") != (twin.listen_port, twin.path):
            problems.append(f"the {partner.role} stand-in calls the twin at {data.get('twin_url')} but the twin listens at {twin.url}")
        if data.get("twin_identity", "").strip() != twin.identity:
            problems.append(f"the {partner.role} stand-in expects the twin to be '{data.get('twin_identity')}', twin.conf says '{twin.identity}'")
        if twin.identity not in layer_config._list(data.get("accept", "")):
            problems.append(f"the {partner.role} stand-in does not accept the twin's identity '{twin.identity}' (accept =)")
    if "guardian" in roles and roles["guardian"].standin and parser.has_section("brain") and "brain" in roles:
        if roles["brain"].identity not in layer_config._list(parser["guardian"].get("accept", "")):
            problems.append("the Guardian stand-in does not accept the Brain's identity")
    for problem in problems:
        print(problem)
    return 1 if problems else 0


def endpoints() -> None:
    _parser, twin, partners, _clients = _twin()
    print(f"twin|{twin.listen_host}|{twin.listen_port}")
    parser = layer_config.read(STANDINS)
    for partner in partners:
        if partner.standin and parser.has_section(partner.role):
            endpoint = layer_config.endpoint(parser, partner.role, STANDINS.parent)
            print(f"{partner.role}|{endpoint.listen_host}|{endpoint.listen_port}")


def port_owner(port: int) -> None:
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        probe.bind(("127.0.0.1", port))
        print("free")
    except OSError:
        print("taken")
    finally:
        probe.close()


def free_port(kind: str) -> None:
    probe = socket.socket(type=socket.SOCK_DGRAM if kind == "udp" else socket.SOCK_STREAM)
    probe.bind(("127.0.0.1", 0))
    print(probe.getsockname()[1])
    probe.close()


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    command = sys.argv[1]
    try:
        if command == "identities":
            identities()
        elif command == "manage-keys":
            manage_keys()
        elif command == "standins":
            standins()
        elif command == "consistency":
            return consistency()
        elif command == "endpoints":
            endpoints()
        elif command == "port-owner":
            port_owner(int(sys.argv[2]))
        elif command == "free-port":
            free_port(sys.argv[2] if len(sys.argv) > 2 else "tcp")
        else:
            print(__doc__)
            return 2
    except layer_config.ConfigError as error:
        print(f"configuration error: {error}")
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
