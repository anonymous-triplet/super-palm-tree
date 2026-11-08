#!/usr/bin/env python3
"""Keys and certificates for the encrypted, authenticated MCP links between layers.

Creates (or checks) a small certificate authority for the triplet and one key pair per identity, all as PEM files:

    <dir>/triplet-ca.cert.pem   <dir>/triplet-ca.key.pem        the authority every layer trusts
    <dir>/<name>.cert.pem       <dir>/<name>.key.pem            one per identity (the common name is the identity)

    python make_keys.py --dir twin/keys --identity twin=localhost,127.0.0.1 --identity city-brain --identity guardian
    python make_keys.py --dir twin/keys --check ...             exit 1 if anything is missing, expired or does not match

Keys are ECDSA P-256; certificates are valid for two years and name localhost and 127.0.0.1 unless told otherwise. A partner
team brings its own authority instead: its certificate goes into the twin's trusted_ca list in twin.conf.
"""
from __future__ import annotations

import argparse
import datetime
import ipaddress
import os
import sys
from pathlib import Path

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
except ImportError:  # pragma: no cover - the launcher installs it
    print("The 'cryptography' package is required (the launcher installs it into the twin's Python environment).", file=sys.stderr)
    sys.exit(3)

CA_NAME = "triplet-ca"
VALID_DAYS = 730
RENEW_BEFORE_DAYS = 14


def _now() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def _write_key(path: Path, key) -> None:
    path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def _load(path: Path):
    return x509.load_pem_x509_certificate(path.read_bytes())


def make_ca(directory: Path) -> None:
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "City Brain Convergence triplet CA"), x509.NameAttribute(NameOID.ORGANIZATION_NAME, "TSYP14 triplet")])
    certificate = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                   .serial_number(x509.random_serial_number()).not_valid_before(_now() - datetime.timedelta(minutes=5))
                   .not_valid_after(_now() + datetime.timedelta(days=VALID_DAYS * 2))
                   .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
                   .add_extension(x509.KeyUsage(digital_signature=True, key_cert_sign=True, crl_sign=True, content_commitment=False, key_encipherment=False,
                                                data_encipherment=False, key_agreement=False, encipher_only=False, decipher_only=False), critical=True)
                   .sign(key, hashes.SHA256()))
    _write_key(directory / f"{CA_NAME}.key.pem", key)
    (directory / f"{CA_NAME}.cert.pem").write_bytes(certificate.public_bytes(serialization.Encoding.PEM))


def make_identity(directory: Path, identity: str, hosts: list[str]) -> None:
    ca_key = serialization.load_pem_private_key((directory / f"{CA_NAME}.key.pem").read_bytes(), password=None)
    ca_certificate = _load(directory / f"{CA_NAME}.cert.pem")
    key = ec.generate_private_key(ec.SECP256R1())
    names: list[x509.GeneralName] = []
    for host in hosts:
        try:
            names.append(x509.IPAddress(ipaddress.ip_address(host)))
        except ValueError:
            names.append(x509.DNSName(host))
    certificate = (x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, identity)]))
                   .issuer_name(ca_certificate.subject).public_key(key.public_key()).serial_number(x509.random_serial_number())
                   .not_valid_before(_now() - datetime.timedelta(minutes=5)).not_valid_after(_now() + datetime.timedelta(days=VALID_DAYS))
                   .add_extension(x509.SubjectAlternativeName(names), critical=False)
                   .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                   .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH, ExtendedKeyUsageOID.CLIENT_AUTH]), critical=False)
                   .sign(ca_key, hashes.SHA256()))
    _write_key(directory / f"{identity}.key.pem", key)
    (directory / f"{identity}.cert.pem").write_bytes(certificate.public_bytes(serialization.Encoding.PEM))


def problem_with(directory: Path, identity: str, hosts: list[str]) -> str:
    """Why this identity's files cannot be used as they are ("" when they are fine)."""
    cert_path, key_path = directory / f"{identity}.cert.pem", directory / f"{identity}.key.pem"
    if not cert_path.is_file() or not key_path.is_file():
        return "missing"
    try:
        certificate = _load(cert_path)
        key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
        ca = _load(directory / f"{CA_NAME}.cert.pem")
    except (ValueError, OSError) as error:
        return f"unreadable ({error})"
    if certificate.public_key().public_numbers() != key.public_key().public_numbers():
        return "key does not match certificate"
    if certificate.issuer != ca.subject:
        return "not signed by the triplet authority"
    try:
        ca.public_key().verify(certificate.signature, certificate.tbs_certificate_bytes, ec.ECDSA(certificate.signature_hash_algorithm))
    except Exception:
        return "signature does not verify"
    if certificate.not_valid_after_utc - _now() < datetime.timedelta(days=RENEW_BEFORE_DAYS):
        return "expired or about to expire"
    try:
        listed = set(str(value) for value in certificate.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName))
        listed |= set(str(value) for value in certificate.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.IPAddress))
    except x509.ExtensionNotFound:
        listed = set()
    missing = [host for host in hosts if host not in listed]
    if missing:
        return f"does not name {', '.join(missing)}"
    return ""


def ca_problem(directory: Path) -> str:
    cert_path, key_path = directory / f"{CA_NAME}.cert.pem", directory / f"{CA_NAME}.key.pem"
    if not cert_path.is_file() or not key_path.is_file():
        return "missing"
    try:
        certificate = _load(cert_path)
        key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
    except (ValueError, OSError) as error:
        return f"unreadable ({error})"
    if certificate.public_key().public_numbers() != key.public_key().public_numbers():
        return "key does not match certificate"
    if certificate.not_valid_after_utc - _now() < datetime.timedelta(days=RENEW_BEFORE_DAYS):
        return "expired or about to expire"
    return ""


def parse_identity(text: str) -> tuple[str, list[str]]:
    name, _, hosts = text.partition("=")
    return name.strip(), [host.strip() for host in (hosts or "localhost,127.0.0.1").split(",") if host.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", required=True, type=Path)
    parser.add_argument("--identity", action="append", default=[], help="name[=host,host...] (default hosts: localhost,127.0.0.1)")
    parser.add_argument("--check", action="store_true", help="only report; exit 1 when something must be (re)generated")
    args = parser.parse_args()
    directory: Path = args.dir
    identities = [parse_identity(text) for text in args.identity]
    issues: list[str] = []
    ca_issue = ca_problem(directory)
    if ca_issue:
        issues.append(f"{CA_NAME}: {ca_issue}")
    for identity, hosts in identities:
        issue = "authority will be renewed" if ca_issue else problem_with(directory, identity, hosts)
        if issue:
            issues.append(f"{identity}: {issue}")
    if args.check:
        for issue in issues:
            print(issue)
        return 1 if issues else 0
    directory.mkdir(parents=True, exist_ok=True)
    if ca_issue:
        make_ca(directory)
        print(f"created {CA_NAME} (certificate authority)")
    for identity, hosts in identities:
        if ca_issue or problem_with(directory, identity, hosts):
            make_identity(directory, identity, hosts)
            print(f"created {identity} ({', '.join(hosts)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
