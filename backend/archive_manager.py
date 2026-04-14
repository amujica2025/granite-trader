from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Any, Dict

# Resolve relative to this file so it works from any CWD.
PROJECT_ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_ROOT = PROJECT_ROOT / "data" / "archive"


def archive_symbol_state(state: Dict[str, Any], reason: str = "snapshot") -> Path:
    """
    Write a dated JSON snapshot of `state` to data/archive/<date>/<symbol>/<time>_<reason>.json.
    Returns the path written.
    """
    symbol = str(state.get("symbol", "UNKNOWN")).upper()
    date_part = datetime.now().strftime("%Y-%m-%d")
    time_part = datetime.now().strftime("%H%M%S")

    target_dir = ARCHIVE_ROOT / date_part / symbol
    target_dir.mkdir(parents=True, exist_ok=True)

    target_path = target_dir / f"{time_part}_{reason}.json"
    target_path.write_text(json.dumps(state, indent=2, default=str), encoding="utf-8")
    return target_path
