"""Plugin settings: resolved once per tool call into an immutable object.

Precedence per key: environment variable > Hermes plugin config
(``plugins.entries.koharu.settings.<key>``) > built-in default.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Optional

DEFAULT_TIMEOUT = 3600.0
DEFAULT_EXPORT_DIR = "~/Koharu/exports"
if sys.platform == "win32":
    DEFAULT_RUNNER = os.path.join(
        os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/AppData/Local"),
        "hermes-koharu",
        "bin",
        "koharu-batch.exe",
    )
elif sys.platform == "darwin":
    DEFAULT_RUNNER = "~/Library/Application Support/hermes-koharu/bin/koharu-batch"
else:
    DEFAULT_RUNNER = "~/.local/share/hermes-koharu/bin/koharu-batch"

_ENV = {
    "runner": "KOHARU_RUNNER",
    "export_dir": "KOHARU_EXPORT_DIR",
    "timeout": "KOHARU_TIMEOUT",
}

# Bound ``ctx.get_config`` captured at register(ctx). None outside Hermes.
_get_config: Optional[Callable[..., Any]] = None


def configure(get_config: Optional[Callable[..., Any]]) -> None:
    """Install the host's config reader (``ctx.get_config``)."""
    global _get_config
    _get_config = get_config


@dataclass(frozen=True)
class Settings:
    runner: Path
    export_dir: Path
    timeout: float


def _raw(key: str) -> Any:
    env = os.environ.get(_ENV[key], "").strip()
    if env:
        return env
    if _get_config is not None:
        try:
            return _get_config(key, None)
        except Exception:  # noqa: BLE001 - a broken host config must not break the tool
            return None
    return None


def load_settings() -> Settings:
    runner = str(_raw("runner") or "").strip() or DEFAULT_RUNNER
    export_dir = str(_raw("export_dir") or "").strip() or DEFAULT_EXPORT_DIR
    try:
        timeout = float(_raw("timeout") or DEFAULT_TIMEOUT)
    except (TypeError, ValueError):
        timeout = DEFAULT_TIMEOUT
    if timeout <= 0:
        timeout = DEFAULT_TIMEOUT
    return Settings(
        runner=Path(runner).expanduser(),
        export_dir=Path(export_dir).expanduser(),
        timeout=timeout,
    )
