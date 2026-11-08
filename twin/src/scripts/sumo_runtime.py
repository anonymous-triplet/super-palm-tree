"""Where SUMO is on this machine.

The launcher (run_control_room.sh) installs the official Eclipse SUMO 1.25.0 package into the twin's Python environment and
exports SUMO_HOME; this module finds it from there. In order:

1. SUMO_HOME (and SUMO_BINARY) from the environment,
2. the `sumo` Python package (pip install eclipse-sumo) of the running interpreter,
3. the older Debian bundle under twin/.runtime/legacy/sumo,
4. a `sumo` on PATH (a system package).
"""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
LEGACY = PROJECT.parent / ".runtime" / "legacy" / "sumo"
EXE = ".exe" if os.name == "nt" else ""


def _from_home(home: Path) -> tuple[Path, Path] | None:
    for candidate in (home / "bin" / f"sumo{EXE}", home.parent.parent / "bin" / f"sumo{EXE}"):
        if candidate.is_file():
            return home, candidate
    return None


def locate() -> tuple[Path, Path, list[str]]:
    """(SUMO_HOME, sumo binary, extra library directories)."""
    binary = os.environ.get("SUMO_BINARY", "")
    home = os.environ.get("SUMO_HOME", "")
    if home:
        if binary and Path(binary).is_file():
            return Path(home), Path(binary), []
        found = _from_home(Path(home))
        if found:
            return found[0], found[1], []
    try:
        import sumo  # type: ignore  # eclipse-sumo wheel

        found = _from_home(Path(sumo.SUMO_HOME))
        if found:
            return found[0], found[1], []
    except ImportError:
        pass
    legacy_binary = LEGACY / "usr" / "bin" / "sumo"
    if legacy_binary.is_file():
        library_root = LEGACY / "usr" / "lib" / "x86_64-linux-gnu"
        libraries = [str(library_root), str(library_root / "blas"), str(library_root / "lapack"), str(LEGACY / "usr" / "lib")]
        return LEGACY / "usr" / "share" / "sumo", legacy_binary, libraries
    system = shutil.which("sumo")
    if system:
        system_home = Path(home) if home else Path(system).resolve().parent.parent / "share" / "sumo"
        return system_home, Path(system), []
    raise FileNotFoundError("SUMO is not installed. Run ./run_control_room.sh once: it installs SUMO 1.25.0 for you.")


def prepare() -> tuple[Path, Path]:
    """Point this process (and the SUMO it starts) at SUMO; make traci and sumolib importable."""
    home, binary, libraries = locate()
    if libraries:
        existing = os.environ.get("LD_LIBRARY_PATH", "")
        os.environ["LD_LIBRARY_PATH"] = ":".join(libraries + ([existing] if existing else []))
    os.environ["SUMO_HOME"] = str(home)
    tools = str(home / "tools")
    if tools not in sys.path:
        sys.path.insert(0, tools)
    return home, binary


def tool(name: str) -> Path:
    """Another SUMO program (netconvert, ...) next to the sumo binary."""
    _home, binary, _libraries = locate()
    return binary.with_name(name + EXE)
