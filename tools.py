"""Agent-facing Koharu tools for Hermes, backed by the headless ``koharu-batch`` runner.

Every handler takes ``(args, **_)`` and returns a JSON string with an ``ok`` bool.
Settings are resolved once per call (see settings.py).

Translation runs as a detached job so one tool call never blocks past Hermes'
per-call limit: each call waits at most ``wait`` seconds, and an unfinished job
is resumed by calling again with ``job=<output_dir>``. Job state lives in the
output folder (runner stdout/stderr and a small job record), so it survives
plugin reloads.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import time
import tomllib
import urllib.error
import urllib.request
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional

from .settings import Settings, load_settings

WINDOWS = os.name == "nt"
if WINDOWS:
    import ctypes
    import msvcrt
    from ctypes import wintypes

    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    _kernel32.OpenProcess.restype = wintypes.HANDLE
    _kernel32.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
    _kernel32.GetExitCodeProcess.restype = wintypes.BOOL
    _kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    _kernel32.CloseHandle.restype = wintypes.BOOL
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    ERROR_ACCESS_DENIED = 5
    STILL_ACTIVE = 259
    # No console window for the runner or its children, and its own process
    # group so a Ctrl+C in Hermes' console does not reach it.
    _NO_WINDOW = subprocess.CREATE_NO_WINDOW
    _DETACH: Dict[str, Any] = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW}
else:
    import fcntl

    _NO_WINDOW = 0
    _DETACH = {"start_new_session": True}

LOG_TAIL_LINES = 20
PROVIDER_PROBE_TIMEOUT = 3.0
VERSION_TIMEOUT = 10.0
POLL_INTERVAL = 0.5
DEFAULT_WAIT = 300.0
MAX_WAIT = 380.0  # Hermes kills a tool call after 420 s
LOCK_NAME = ".koharu-batch.lock"
EVENTS_NAME = ".koharu-batch.jsonl"
LOG_NAME = ".koharu-batch.log"
JOB_NAME = ".koharu-batch.job.json"
INSTALL_HINT = "Install it with scripts/install.sh from the hermes-koharu-plugin repo, or set KOHARU_RUNNER."
MEDIA_NOTE = "Copy the MEDIA lines into your reply to send the pages on Telegram."

# Runner processes started by this Hermes process, so finished ones get reaped
# instead of lingering as zombies that still look alive to os.kill(pid, 0).
_children: Dict[int, subprocess.Popen] = {}


def koharu_config_path() -> Path:
    """Koharu desktop config shared with the runner (``~/.koharu/config.toml``)."""
    return Path.home() / ".koharu" / "config.toml"


def _json(data: Any) -> str:
    return json.dumps(data, ensure_ascii=False)


def _fail(error: str, **extra: Any) -> str:
    return _json({"ok": False, "error": error, **extra})


def _abs(path: str) -> Path:
    return Path(os.path.abspath(Path(path).expanduser()))


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


# ---------------------------------------------------------------------------
# koharu_translate
# ---------------------------------------------------------------------------


def _win_alive(pid: int) -> bool:
    """Windows liveness without os.kill, which would terminate the process."""
    handle = _kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not handle:
        return ctypes.get_last_error() == ERROR_ACCESS_DENIED  # exists but not ours to query
    try:
        code = wintypes.DWORD()
        if not _kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
            return True
        return code.value == STILL_ACTIVE
    finally:
        _kernel32.CloseHandle(handle)


def _kill_tree(pid: int) -> None:
    """Kill the runner and everything it started."""
    if WINDOWS:
        try:
            subprocess.run(
                ["taskkill", "/PID", str(pid), "/T", "/F"],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                creationflags=_NO_WINDOW,
                timeout=VERSION_TIMEOUT,
            )
        except (OSError, subprocess.SubprocessError):
            pass
        return
    try:
        os.killpg(pid, signal.SIGKILL)  # the runner leads its own session and group
    except (ProcessLookupError, PermissionError):
        pass


def _alive(pid: int) -> bool:
    child = _children.get(pid)
    if child is not None:
        if child.poll() is None:
            return True
        del _children[pid]
        return False
    if WINDOWS:
        return _win_alive(pid)
    try:
        if os.waitpid(pid, os.WNOHANG)[0] == pid:
            return False  # our own zombie, now reaped
    except ChildProcessError:
        pass
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


@contextmanager
def _locked(settings: Settings) -> Iterator[Any]:
    """The job lock file, locked for a short read-modify-write."""
    settings.export_dir.mkdir(parents=True, exist_ok=True)
    with open(settings.export_dir / LOCK_NAME, "a+", encoding="utf-8") as handle:
        if not WINDOWS:
            fcntl.flock(handle, fcntl.LOCK_EX)  # released when the file closes
            handle.seek(0)
            yield handle
            return
        handle.seek(0)
        while True:  # LK_LOCK gives up after about 10 s, keep waiting like flock
            try:
                msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
                break
            except OSError:
                pass
        try:
            yield handle
        finally:
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


def _read_lock(handle: Any) -> Dict[str, Any]:
    try:
        data = json.loads(handle.read() or "{}")
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def _write_lock(handle: Any, data: Dict[str, Any]) -> None:
    handle.seek(0)
    handle.truncate()
    if data:
        handle.write(json.dumps(data))
    handle.flush()


def _release(settings: Settings, pid: int) -> None:
    with _locked(settings) as handle:
        if _read_lock(handle).get("pid") == pid:
            _write_lock(handle, {})


def _events(output_dir: Path) -> List[Dict[str, Any]]:
    try:
        lines = (output_dir / EVENTS_NAME).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    events = []
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue  # also a partially written last line
        if isinstance(event, dict):
            events.append(event)
    return events


def _log_tail(output_dir: Path) -> List[str]:
    try:
        text = (output_dir / LOG_NAME).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    return [line for line in text.splitlines() if line.strip()][-LOG_TAIL_LINES:]


def _stages_done(events: List[Dict[str, Any]]) -> List[str]:
    stages: List[str] = []
    for event in events:
        stage = event.get("stage")
        if event.get("event") == "progress" and stage and stage != "init" and stage not in stages:
            stages.append(stage)
    return stages


def _start(settings: Settings, args: Dict[str, Any]) -> Any:
    """Validate a new run and spawn the runner detached. Returns (output_dir, job) or an error JSON string."""
    raw_paths = args.get("paths")
    if isinstance(raw_paths, str):
        raw_paths = [raw_paths]
    paths = [p.strip() for p in raw_paths or [] if isinstance(p, str) and p.strip()]
    if not paths:
        return _fail("paths must list at least one image file or folder.")
    inputs = [_abs(p) for p in paths]
    missing = [str(p) for p in inputs if not p.exists()]
    if missing:
        return _fail("Input paths not found: " + ", ".join(missing), missing=missing)

    runner = settings.runner
    if not (runner.is_file() and os.access(runner, os.X_OK)):
        return _fail(f"Koharu runner not found or not executable at {runner}. {INSTALL_HINT}")

    output_arg = _text(args.get("output_dir"))
    if output_arg:
        output_dir = _abs(output_arg)
    else:
        first = inputs[0]
        name = first.name if first.is_dir() else first.stem
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        output_dir = settings.export_dir / f"{name}-{stamp}"

    command = [str(runner), *map(str, inputs), "--output", str(output_dir)]
    target_language = _text(args.get("target_language"))
    if target_language:
        command += ["--target-language", target_language]
    instructions = _text(args.get("instructions"))
    if instructions:
        command += ["--instructions", instructions]

    with _locked(settings) as handle:
        holder = _read_lock(handle)
        if isinstance(holder.get("pid"), int) and _alive(holder["pid"]):
            # Models are large: one run at a time.
            return _fail(
                "busy",
                job=holder.get("output_dir"),
                note="Another Koharu job is running. Call koharu_translate with job=<that job> and wait for it to finish first.",
            )
        output_dir.mkdir(parents=True, exist_ok=True)
        try:
            with open(output_dir / EVENTS_NAME, "w") as out, open(output_dir / LOG_NAME, "w") as err:
                proc = subprocess.Popen(
                    command, stdin=subprocess.DEVNULL, stdout=out, stderr=err, **_DETACH
                )
        except OSError as exc:
            return _fail(f"Could not start the Koharu runner: {exc}. {INSTALL_HINT}")
        _children[proc.pid] = proc
        job = {"pid": proc.pid, "started": time.time()}
        (output_dir / JOB_NAME).write_text(json.dumps(job), encoding="utf-8")
        _write_lock(handle, {"pid": proc.pid, "output_dir": str(output_dir)})
    return output_dir, job


def _wait_value(raw: Any) -> float:
    try:
        wait = float(raw if raw is not None else DEFAULT_WAIT)
    except (TypeError, ValueError):
        wait = DEFAULT_WAIT
    return min(max(wait, 0.0), MAX_WAIT)


def handle_koharu_translate(args: Dict[str, Any], **_: Any) -> str:
    settings = load_settings()
    wait = _wait_value(args.get("wait"))

    job_arg = _text(args.get("job"))
    if job_arg:
        output_dir = _abs(job_arg)
        try:
            job = json.loads((output_dir / JOB_NAME).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return _fail(f"No Koharu job at {output_dir}.")
    else:
        started = _start(settings, args)
        if isinstance(started, str):
            return started
        output_dir, job = started

    pid, started_at = int(job["pid"]), float(job["started"])
    deadline = time.monotonic() + wait
    while True:
        events = _events(output_dir)
        done = next((e for e in reversed(events) if e.get("event") == "done"), None)
        running = done is None and _alive(pid)
        if done is not None or not running:
            if done is None:  # it may have written the done line just before exiting
                events = _events(output_dir)
                done = next((e for e in reversed(events) if e.get("event") == "done"), None)
            child = _children.pop(pid, None)
            if child is not None:
                try:
                    child.wait(timeout=5)  # the runner exits right after its done line
                except subprocess.TimeoutExpired:
                    pass
            _release(settings, pid)
            return _finish(output_dir, events, done, started_at)
        if time.time() - started_at > settings.timeout:
            _kill_tree(pid)
            for _ in range(20):
                if not _alive(pid):
                    break
                time.sleep(0.1)
            _release(settings, pid)
            return _fail(
                f"Koharu runner timed out after {settings.timeout:g} s and was killed.",
                job=str(output_dir),
                stages_done=_stages_done(events),
                log_tail=_log_tail(output_dir),
            )
        if time.monotonic() >= deadline:
            start = next((e for e in events if e.get("event") == "start"), {})
            return _json(
                {
                    "ok": True,
                    "done": False,
                    "job": str(output_dir),
                    "progress": {
                        "pages_total": start.get("pages"),
                        "translated": sum(
                            1 for e in events if e.get("event") == "progress" and e.get("stage") == "translation"
                        ),
                        "stages_done": _stages_done(events),
                    },
                    "note": f"Still running. Call koharu_translate with job={output_dir} to keep waiting.",
                }
            )
        time.sleep(POLL_INTERVAL)


def _finish(output_dir: Path, events: List[Dict[str, Any]], done: Optional[Dict[str, Any]], started_at: float) -> str:
    if done is None or not done.get("ok"):
        error = str((done or {}).get("error") or "Koharu runner exited without a result.")
        return _fail(error, job=str(output_dir), stages_done=_stages_done(events), log_tail=_log_tail(output_dir))
    pages = [
        {"input": page.get("input"), "output": str(_abs(str(page.get("output"))))}
        for page in done.get("pages") or []
        if isinstance(page, dict) and page.get("output")
    ]
    elapsed = done.get("elapsed_s")
    return _json(
        {
            "ok": True,
            "done": True,
            "output_dir": str(output_dir),
            "pages": pages,
            "media": [f"MEDIA:{page['output']}" for page in pages],
            "elapsed_s": elapsed if elapsed is not None else round(time.time() - started_at, 1),
            "note": MEDIA_NOTE,
        }
    )


# ---------------------------------------------------------------------------
# koharu_status
# ---------------------------------------------------------------------------


def _runner_version(runner: Path) -> Optional[str]:
    try:
        result = subprocess.run(
            [str(runner), "--version"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=VERSION_TIMEOUT,
            creationflags=_NO_WINDOW,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return (result.stdout.strip() or None) if result.returncode == 0 else None


def _probe(base_url: str) -> bool:
    """True when the provider's HTTP server answers ``GET <base_url>/models`` at all."""
    try:
        with urllib.request.urlopen(base_url.rstrip("/") + "/models", timeout=PROVIDER_PROBE_TIMEOUT):
            return True
    except urllib.error.HTTPError:
        return True  # it answered, e.g. 401 without an API key
    except (urllib.error.URLError, OSError, ValueError):
        return False


def _section(data: Any, *keys: str) -> Dict[str, Any]:
    for key in keys:
        data = data.get(key) if isinstance(data, dict) else None
    return data if isinstance(data, dict) else {}


def handle_koharu_status(args: Dict[str, Any], **_: Any) -> str:
    settings = load_settings()
    notes: List[str] = []

    runner = settings.runner
    exists = runner.is_file()
    version = _runner_version(runner) if exists else None
    if not exists:
        notes.append(f"Runner missing at {runner}. {INSTALL_HINT}")
    elif version is None:
        notes.append(f"Runner at {runner} did not report a version. Reinstall with scripts/install.sh.")

    config_path = koharu_config_path()
    data: Dict[str, Any] = {}
    if config_path.is_file():
        try:
            data = tomllib.loads(config_path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as exc:
            notes.append(f"Could not parse {config_path}: {exc}")
    else:
        notes.append(f"No Koharu config at {config_path}. Set up the pipeline in the Koharu desktop app.")

    translation = _section(data, "pipeline", "translation")
    model = _section(translation, "model")
    provider = model.get("provider") or None
    base_url = _section(data, "providers", provider).get("base_url") if provider else None
    if not model.get("model"):
        notes.append("No translation model configured in Koharu's config.")

    reachable: Optional[bool] = None
    if base_url:
        reachable = _probe(str(base_url))
        if not reachable:
            notes.append(f"Translation provider {provider} at {base_url} is not reachable. Start it before translating.")

    return _json(
        {
            "ok": bool(exists and version) and reachable is not False,
            "runner": {"path": str(runner), "exists": exists, "version": version},
            "config": {
                "path": str(config_path),
                "exists": config_path.is_file(),
                "target_language": translation.get("target_language"),
                "translation_model": model.get("model"),
                "translation_provider": provider,
                "provider_base_url": base_url,
                "detection": _section(data, "pipeline", "detection").get("model"),
                "ocr": _section(data, "pipeline", "ocr").get("model"),
                "inpainting": _section(data, "pipeline", "inpainting").get("model"),
            },
            "provider_reachable": reachable,
            "notes": notes,
        }
    )


# ---------------------------------------------------------------------------
# schemas
# ---------------------------------------------------------------------------

TRANSLATE_SCHEMA = {
    "name": "koharu_translate",
    "description": (
        "Translate manga/comic pages with Koharu (headless): detects text, runs OCR, translates, "
        "removes the original text and typesets the translation. Takes image files "
        "(png/jpg/jpeg/webp) or folders of them (not recursive, natural page order). The default "
        "target language, translation model and pipeline come from Koharu's own config "
        "(koharu_status shows them). Pass target_language whenever the user names a language. "
        "The run continues in the background, and each call waits up to `wait` seconds (default 300). "
        "Long chapters return done=false with a `job`: call koharu_translate again with only "
        "job=<that value> to keep waiting until done=true. Only one job runs at a time. Error "
        "'busy' names the running job to wait on first. When done, it returns one PNG per page "
        "and `media` lines: copy every MEDIA:/path line verbatim into your reply, one per line, "
        "so the pages are sent to the user."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "paths": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Image files and/or folders of images to translate. Absolute paths or ~ paths. Required unless `job` is given.",
            },
            "target_language": {
                "type": "string",
                "description": "Language to translate into, as a name or tag, e.g. 'English', 'en-US', 'Indonesian', 'id-ID'. Omit to use Koharu's configured default.",
            },
            "instructions": {
                "type": "string",
                "description": "Extra instructions for the translation model for this run (names, glossary, tone). They are added after the instructions set in Koharu's settings.",
            },
            "output_dir": {
                "type": "string",
                "description": "Folder for the translated PNGs. Default: <export_dir>/<first input name>-<timestamp>.",
            },
            "job": {
                "type": "string",
                "description": "Resume waiting on an earlier run: the `job` value from a done=false or busy result. Other arguments except `wait` are ignored.",
            },
            "wait": {
                "type": "number",
                "description": "Seconds to wait in this call before returning progress (0-380, default 300).",
            },
        },
    },
}

STATUS_SCHEMA = {
    "name": "koharu_status",
    "description": (
        "Check that Koharu translation is ready: runner installed (path, version), Koharu's config "
        "(default target language, translation model/provider, detection/OCR/inpainting models) "
        "and whether the translation provider's server answers. Call it before koharu_translate "
        "when unsure, or when a translation fails."
    ),
    "parameters": {"type": "object", "properties": {}},
}

TOOLS = (
    (TRANSLATE_SCHEMA, handle_koharu_translate, "🈂️"),
    (STATUS_SCHEMA, handle_koharu_status, "🩺"),
)
