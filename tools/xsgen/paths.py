"""
Kallskar xsgen: filesystem locations.

Large data and run output live on D: (the WSL virtual disk sits on a nearly full C: drive; see
memory/reference-wsl-openmc). Import this module instead of hard-coding paths, and call `configure_openmc()`
before building any OpenMC model.
"""
import os
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DATA_ROOT = Path("/mnt/d/Roblox Projects/Kallinskar Nuclear Power Plant")
NUCDATA = DATA_ROOT / "nucdata"
CROSS_SECTIONS = NUCDATA / "endfb-viii.1-hdf5" / "cross_sections.xml"
CHAIN_FAST = NUCDATA / "chain_endfb81_fast.xml"
RUNS = DATA_ROOT / "xs-runs"
RESULTS = REPO / "tools" / "xsgen" / "results"  # small, committed summaries of runs

# KALLSKAR_THREADS caps the OpenMC threads (e.g. to keep a machine cooler on long runs); default: every CPU
THREADS = int(os.environ.get("KALLSKAR_THREADS") or os.cpu_count() or 1)
if os.environ.get("KALLSKAR_THREADS"):
    # depletion runs OpenMC through openmc.lib, whose OpenMP runtime reads this when the library loads
    os.environ["OMP_NUM_THREADS"] = str(THREADS)


def configure_openmc():
    """Point OpenMC at the D: data and keep scratch writes off the C:-hosted WSL disk."""
    import openmc

    if not CROSS_SECTIONS.exists():
        raise FileNotFoundError(f"nuclear data not found at {CROSS_SECTIONS}; run tools/xsgen/setup_data.sh")
    openmc.config["cross_sections"] = str(CROSS_SECTIONS)
    if CHAIN_FAST.exists():
        openmc.config["chain_file"] = str(CHAIN_FAST)
    tmp = RUNS / "tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    os.environ["TMPDIR"] = str(tmp)
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    RESULTS.mkdir(parents=True, exist_ok=True)
    return openmc


def run_dir(name: str) -> Path:
    d = RUNS / name
    d.mkdir(parents=True, exist_ok=True)
    return d
