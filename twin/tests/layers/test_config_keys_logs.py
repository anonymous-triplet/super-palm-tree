"""twin.conf and standins.conf, the key pairs, the gateway's own checks and the run logs."""
from __future__ import annotations

import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from helpers import MCP, SRC, TWIN, make_keys

import launcher_tasks
import layer_config
import runlog
import twin_gateway


class ConfigTest(unittest.TestCase):
    def test_the_shipped_configuration_is_consistent(self) -> None:
        parser = layer_config.read(TWIN / "twin.conf")
        twin = layer_config.endpoint(parser, "twin", TWIN)
        self.assertEqual(twin.url, "https://127.0.0.1:8740/mcp")
        roles = {partner.role: partner for partner in layer_config.partners(parser)}
        self.assertEqual(set(roles), {"brain", "guardian"})
        self.assertIn("dispatch_units", roles["brain"].allow)
        self.assertNotIn("dispatch_units", roles["guardian"].allow)
        with redirect_stdout(io.StringIO()) as out:
            self.assertEqual(launcher_tasks.consistency(), 0)
        self.assertEqual(out.getvalue(), "")

    def test_mismatches_are_reported(self) -> None:
        folder = Path(tempfile.mkdtemp(prefix="cgz-conf-"))
        (folder / "mocks").mkdir()
        conf = (TWIN / "twin.conf").read_text().replace("url = https://127.0.0.1:8741/mcp", "url = https://127.0.0.1:9999/mcp")
        (folder / "twin.conf").write_text(conf)
        shutil.copy(TWIN / "mocks" / "standins.conf", folder / "mocks" / "standins.conf")
        saved = launcher_tasks.CONF, launcher_tasks.STANDINS
        launcher_tasks.CONF, launcher_tasks.STANDINS = folder / "twin.conf", folder / "mocks" / "standins.conf"
        try:
            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(launcher_tasks.consistency(), 1)
        finally:
            launcher_tasks.CONF, launcher_tasks.STANDINS = saved
        self.assertIn("9999", out.getvalue())

    def test_bad_values_are_refused(self) -> None:
        folder = Path(tempfile.mkdtemp(prefix="cgz-conf-"))
        (folder / "twin.conf").write_text((TWIN / "twin.conf").read_text().replace("url = https://127.0.0.1:8742/mcp", "url = http://127.0.0.1:8742/mcp"))
        with self.assertRaises(layer_config.ConfigError):
            layer_config.partners(layer_config.read(folder / "twin.conf"))
        (folder / "twin.conf").write_text((TWIN / "twin.conf").read_text().replace("listen_port = 8740", "listen_port = 99999"))
        with self.assertRaises(layer_config.ConfigError):
            layer_config.endpoint(layer_config.read(folder / "twin.conf"), "twin", folder)

    def test_block_labels_match_the_city(self) -> None:
        self.assertEqual(layer_config.block_label(-370.0, -370.0), "A.1")
        self.assertEqual(layer_config.block_label(10.0, 10.0), "K.1")
        self.assertEqual(layer_config.block_label(370.0, 370.0), "P.4")


class KeysTest(unittest.TestCase):
    def run_keys(self, directory: Path, *identities: str, check: bool = False) -> subprocess.CompletedProcess:
        arguments = [sys.executable, str(MCP / "make_keys.py"), "--dir", str(directory)] + [item for name in identities for item in ("--identity", name)]
        return subprocess.run(arguments + (["--check"] if check else []), capture_output=True, text=True)

    def test_create_check_and_heal(self) -> None:
        directory = Path(tempfile.mkdtemp(prefix="cgz-keys-"))
        self.assertEqual(self.run_keys(directory, "city-twin", check=True).returncode, 1)
        self.assertEqual(self.run_keys(directory, "city-twin").returncode, 0)
        self.assertEqual(self.run_keys(directory, "city-twin", check=True).returncode, 0)
        other = make_keys(["city-twin"])
        shutil.copy(other / "city-twin.key.pem", directory / "city-twin.key.pem")         # a key that does not match the certificate
        result = self.run_keys(directory, "city-twin", check=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match", result.stdout)
        self.run_keys(directory, "city-twin")
        self.assertEqual(self.run_keys(directory, "city-twin", check=True).returncode, 0)
        self.assertIn("does not name", self.run_keys(directory, "city-twin=localhost,127.0.0.1,10.0.0.7", check=True).stdout)


class GatewayTest(unittest.TestCase):
    def test_check_accepts_the_configuration(self) -> None:
        keys = TWIN / "keys"
        if not (keys / "city-twin.cert.pem").is_file():
            self.skipTest("keys not generated yet (run ./run_control_room.sh --setup)")
        result = subprocess.run([sys.executable, str(MCP / "twin_gateway.py"), "--config", str(TWIN / "twin.conf"), "--check"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_wording(self) -> None:
        text = twin_gateway.describe_call("dispatch_units", {"incident": "INC-1", "decisions": [{"request": "INC-1-R1", "action": "unit", "unit": "POL-2"},
                                                                                                {"request": "INC-1-R2", "action": "mutual_aid"}]})
        self.assertEqual(text, "Dispatch decision for INC-1: POL-2 for INC-1-R1, mutual aid for INC-1-R2")
        self.assertEqual(twin_gateway.describe_call("read_sector", {"sector": "K"}), "Read sector K")
        facts = twin_gateway.incident_facts({"id": "INC-1", "kind": "rear_end", "title": "Rear-end collision", "location": {"x": 10.0, "z": 10.0},
                                             "participants": [{"id": "civ_1", "injured": True}]})
        self.assertEqual(facts["block"], "K.1")
        self.assertEqual(facts["injuries"], ["civ_1"])


class RunLogTest(unittest.TestCase):
    def test_lines_payloads_and_viewer(self) -> None:
        folder = Path(tempfile.mkdtemp(prefix="cgz-logs-"))
        logs = twin_gateway.RunLogs(folder, 64, ["Layers:  test"])
        path = logs.open_run("INC-0007", "T07 Building fire", "Building fire")
        self.assertRegex(path.name, r"^\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d_t07-building-fire_INC-0007_building-fire\.log$")
        entry = {"time": "12:00:00.000", "from": "brain", "to": "twin", "text": "Dispatch decision", "incident": "INC-0007", "payload": {"a": "x" * 100}}
        logs.write(entry)
        text = path.read_text()
        self.assertIn("12:00:00.000  BRAIN → TWIN        Dispatch decision", text)
        self.assertIn("↳ {", text)
        self.assertIn("more characters", text)
        with redirect_stdout(io.StringIO()) as out:
            runlog.show(path, details=False)
        self.assertFalse(any(line.lstrip().startswith("↳") for line in out.getvalue().splitlines()))
        self.assertIn("Dispatch decision", out.getvalue())
        self.assertTrue(logs.session.is_file())


if __name__ == "__main__":
    unittest.main()
