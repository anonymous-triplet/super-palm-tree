"""Reading a layer's .conf file (INI syntax): identity, endpoint, PEM files and partners. Paths are relative to the file."""
from __future__ import annotations

import configparser
import math
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit

SECTORS = "ABCDEFGHIJKLMNOP"


class ConfigError(Exception):
    pass


@dataclass
class Endpoint:
    identity: str
    listen_host: str
    listen_port: int
    path: str
    certificate: Path
    private_key: Path
    trusted_ca: list[Path]
    hostnames: list[str]
    tls_min_version: str = "1.3"

    @property
    def url(self) -> str:
        host = "127.0.0.1" if self.listen_host in ("0.0.0.0", "::", "") else self.listen_host
        return f"https://{host}:{self.listen_port}{self.path}"


@dataclass
class Partner:
    name: str
    role: str
    url: str
    identity: str
    allow: list[str]
    timeout_s: float = 8.0
    standin: bool = True
    tools: dict = field(default_factory=dict)


@dataclass
class Client:
    name: str
    identity: str
    certificate: Path
    private_key: Path
    allow: list[str]


def _list(text: str) -> list[str]:
    return [part.strip() for part in str(text or "").replace("\n", ",").split(",") if part.strip()]


def _bool(text: str) -> bool:
    return str(text).strip().lower() in ("1", "yes", "true", "on")


def read(path: Path) -> configparser.ConfigParser:
    if not path.is_file():
        raise ConfigError(f"configuration file not found: {path}")
    parser = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=("#", ";"))
    try:
        parser.read(path, encoding="utf-8")
    except configparser.Error as error:
        raise ConfigError(f"{path}: {error}") from error
    return parser


def endpoint(parser: configparser.ConfigParser, section: str, base: Path) -> Endpoint:
    if not parser.has_section(section):
        raise ConfigError(f"[{section}] is missing")
    data = parser[section]
    try:
        port = int(data.get("listen_port", "0"))
    except ValueError as error:
        raise ConfigError(f"[{section}] listen_port must be a number") from error
    if not 1 <= port <= 65535:
        raise ConfigError(f"[{section}] listen_port must be 1-65535")
    for key in ("identity", "certificate", "private_key", "trusted_ca"):
        if not data.get(key, "").strip():
            raise ConfigError(f"[{section}] {key} is required")
    return Endpoint(identity=data["identity"].strip(), listen_host=data.get("listen_host", "127.0.0.1").strip(), listen_port=port,
                    path=data.get("endpoint", "/mcp").strip() or "/mcp", certificate=(base / data["certificate"].strip()).resolve(),
                    private_key=(base / data["private_key"].strip()).resolve(), trusted_ca=[(base / item).resolve() for item in _list(data["trusted_ca"])],
                    hostnames=_list(data.get("hostnames", "localhost, 127.0.0.1")), tls_min_version=data.get("tls_min_version", "1.3").strip())


def partners(parser: configparser.ConfigParser) -> list[Partner]:
    found = []
    for section in parser.sections():
        if not section.startswith("partner:"):
            continue
        data = parser[section]
        url = data.get("url", "").strip()
        if urlsplit(url).scheme != "https":
            raise ConfigError(f"[{section}] url must be an https:// address")
        if not data.get("identity", "").strip():
            raise ConfigError(f"[{section}] identity is required (the common name of the partner's certificate)")
        tools = {key[:-5]: value.strip() for key, value in data.items() if key.endswith("_tool")}
        found.append(Partner(name=section.split(":", 1)[1], role=data.get("role", section.split(":", 1)[1]).strip(), url=url,
                             identity=data["identity"].strip(), allow=_list(data.get("allow", "read_only")),
                             timeout_s=float(data.get("timeout_s", "8")), standin=_bool(data.get("standin", "no")), tools=tools))
    return found


def clients(parser: configparser.ConfigParser, base: Path) -> list[Client]:
    found = []
    for section in parser.sections():
        if not section.startswith("client:"):
            continue
        data = parser[section]
        found.append(Client(name=section.split(":", 1)[1], identity=data.get("identity", "").strip(),
                            certificate=(base / data.get("certificate", "")).resolve(), private_key=(base / data.get("private_key", "")).resolve(),
                            allow=_list(data.get("allow", "read_only"))))
    return found


def block_label(x: float, z: float) -> str:
    """Sector and block of a ground position, as the city names them (A.1 ... P.4)."""
    column = min(max(math.floor((x + 380.0) / 95.0), 0), 7)
    row = min(max(math.floor((z + 380.0) / 95.0), 0), 7)
    return f"{SECTORS[(row // 2) * 4 + column // 2]}.{row % 2 * 2 + column % 2 + 1}"
