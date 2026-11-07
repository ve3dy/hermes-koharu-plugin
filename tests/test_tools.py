"""Behavioural tests against a fake ``koharu-batch`` runner script (stdlib only)."""

from __future__ import annotations

import importlib.util
import json
import os
import signal
import socket
import sys
import tempfile
import textwrap
import threading
import time
import types
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if "hermes_plugins" not in sys.modules:
    parent = types.ModuleType("hermes_plugins")
    parent.__path__ = []  # type: ignore[attr-defined]
    sys.modules["hermes_plugins"] = parent
_spec = importlib.util.spec_from_file_location(
    "hermes_plugins.koharu", ROOT / "__init__.py", submodule_search_locations=[str(ROOT)]
)
plugin = importlib.util.module_from_spec(_spec)
sys.modules["hermes_plugins.koharu"] = plugin
_spec.loader.exec_module(plugin)  # type: ignore[union-attr]
settings_mod = sys.modules["hermes_plugins.koharu.settings"]
tools = sys.modules["hermes_plugins.koharu.tools"]

WINDOWS = os.name == "nt"
ENV_KEYS = (
    "KOHARU_RUNNER",
    "KOHARU_EXPORT_DIR",
    "KOHARU_TIMEOUT",
    "HOME",
    "USERPROFILE",
    "FAKE_MODE",
    "FAKE_LOG",
    "FAKE_DELAY",
)

# Fake runner: behaviour chosen by FAKE_MODE; each launch appends {argv, pid} to FAKE_LOG.
# POSIX runs the script through its shebang, Windows through a .cmd wrapper.
FAKE_RUNNER = textwrap.dedent(
    """\
    #!{python}
    import json, os, subprocess, sys, time
    argv = sys.argv[1:]
    if argv == ["--version"]:
        print("koharu-batch 0.83.5")
        sys.exit(0)
    mode = os.environ.get("FAKE_MODE", "ok")
    def record(**extra):
        with open(os.environ["FAKE_LOG"], "a") as f:
            f.write(json.dumps(dict(argv=argv, pid=os.getpid(), **extra)) + "\\n")
    def emit(obj):
        print(json.dumps(obj), flush=True)
    record()
    out = argv[argv.index("--output") + 1]
    inputs = argv[:argv.index("--output")]
    print("INFO loading models", file=sys.stderr, flush=True)
    emit({{"event": "start", "pages": len(inputs)}})
    emit({{"event": "progress", "stage": "detection", "model": "det", "elapsed_s": 0.1}})
    if mode == "die":
        print("panic: boom", file=sys.stderr, flush=True)
        sys.exit(3)
    emit({{"event": "progress", "stage": "ocr", "model": "ocr", "elapsed_s": 0.1}})
    if mode == "fail":
        for i in range(30):
            print(f"ERROR line {{i}}", file=sys.stderr, flush=True)
        emit({{"event": "done", "ok": False, "error": "translation provider refused"}})
        sys.exit(1)
    if mode == "hang":
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        record(child=child.pid)
        time.sleep(60)
    time.sleep(float(os.environ.get("FAKE_DELAY") or 0))
    pages = []
    for path in inputs:
        dest = os.path.join(out, os.path.splitext(os.path.basename(path))[0] + ".png")
        open(dest, "wb").close()
        pages.append({{"input": path, "output": dest}})
        emit({{"event": "progress", "stage": "translation", "model": "llm", "elapsed_s": 0.1}})
    emit({{"event": "progress", "stage": "inpainting", "model": "lama", "elapsed_s": 0.1}})
    emit({{"event": "done", "ok": True, "pages": pages, "elapsed_s": 1.5}})
    """
)


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self._env = {key: os.environ.get(key) for key in ENV_KEYS}
        self.addCleanup(self._restore_env)
        settings_mod.configure(None)
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(self._rmtree, self.tmp)
        script = self.tmp / "fake_koharu_batch.py"
        script.write_text(FAKE_RUNNER.format(python=sys.executable))
        if WINDOWS:
            self.runner = self.tmp / "koharu-batch.cmd"
            self.runner.write_text(f'@"{sys.executable}" "{script}" %*\n')
        else:
            self.runner = script
            self.runner.chmod(0o755)
        self.exports = self.tmp / "exports"
        self.log = self.tmp / "fake.log"
        self.home = self.tmp / "home"
        self.home.mkdir()
        os.environ.update(
            KOHARU_RUNNER=str(self.runner),
            KOHARU_EXPORT_DIR=str(self.exports),
            FAKE_LOG=str(self.log),
            FAKE_MODE="ok",
            HOME=str(self.home),
            USERPROFILE=str(self.home),
        )
        os.environ.pop("KOHARU_TIMEOUT", None)
        os.environ.pop("FAKE_DELAY", None)
        self.pages = self.tmp / "chapter 1"
        self.pages.mkdir()
        for name in ("001.png", "002.png"):
            (self.pages / name).write_bytes(b"png")

    def _restore_env(self) -> None:
        for key, value in self._env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    @staticmethod
    def _rmtree(path: Path) -> None:
        import shutil

        shutil.rmtree(path, ignore_errors=True)

    def calls(self) -> list:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def translate(self, **args) -> dict:
        return json.loads(tools.handle_koharu_translate(args))


class TranslateTests(Base):
    def setUp(self) -> None:
        super().setUp()
        self.addCleanup(self._kill_jobs)

    def _kill_jobs(self) -> None:
        for call in self.calls():
            for pid in (call["pid"], call.get("child")):
                if not pid:
                    continue
                if WINDOWS:
                    tools._kill_tree(pid)
                    continue
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        while tools._children:
            tools._children.popitem()[1].wait()

    def assert_dead(self, pid: int) -> None:
        for _ in range(50):
            if not tools._alive(pid):
                return
            time.sleep(0.1)
        self.fail(f"process {pid} survived")

    def test_success_passes_arguments_and_returns_media(self) -> None:
        cwd = os.getcwd()
        os.chdir(self.tmp)
        self.addCleanup(os.chdir, cwd)
        out = self.translate(
            paths=["chapter 1/001.png", str(self.pages / "002.png")],
            target_language="English",
            instructions="keep honorifics",
            output_dir="out",
        )
        self.assertTrue(out["ok"], out)
        self.assertTrue(out["done"])
        output_dir = os.path.abspath(self.tmp / "out")
        self.assertEqual(
            self.calls()[0]["argv"],
            [
                os.path.abspath(self.pages / "001.png"),
                os.path.abspath(self.pages / "002.png"),
                "--output",
                output_dir,
                "--target-language",
                "English",
                "--instructions",
                "keep honorifics",
            ],
        )
        self.assertEqual(out["output_dir"], output_dir)
        expected = [os.path.join(output_dir, "001.png"), os.path.join(output_dir, "002.png")]
        self.assertEqual([p["output"] for p in out["pages"]], expected)
        self.assertEqual(out["media"], ["MEDIA:" + p for p in expected])
        self.assertEqual(out["elapsed_s"], 1.5)
        self.assertIn("MEDIA", out["note"])

    def test_default_output_dir_and_optional_flags_omitted(self) -> None:
        out = self.translate(paths=[str(self.pages)])
        self.assertTrue(out["ok"], out)
        output_dir = Path(out["output_dir"])
        self.assertEqual(output_dir.parent, self.exports)
        self.assertRegex(output_dir.name, r"^chapter 1-\d{8}-\d{6}$")
        self.assertEqual(self.calls()[0]["argv"], [str(self.pages), "--output", str(output_dir)])

    def test_default_output_dir_uses_file_stem_and_expands_home(self) -> None:
        (self.home / "page.jpg").write_bytes(b"jpg")
        out = self.translate(paths=["~/page.jpg"])
        self.assertTrue(out["ok"], out)
        self.assertRegex(Path(out["output_dir"]).name, r"^page-\d{8}-\d{6}$")
        self.assertEqual(self.calls()[0]["argv"][0], str(self.home / "page.jpg"))

    def test_unfinished_job_reports_progress_blocks_others_and_resumes(self) -> None:
        os.environ["FAKE_DELAY"] = "3"
        files = [str(self.pages / "001.png"), str(self.pages / "002.png")]
        first = self.translate(paths=files, wait=1)
        self.assertEqual(first["ok"], True)
        self.assertEqual(first["done"], False)
        self.assertEqual(
            first["progress"], {"pages_total": 2, "translated": 0, "stages_done": ["detection", "ocr"]}
        )
        self.assertIn(first["job"], first["note"])

        busy = self.translate(paths=[str(self.pages)], output_dir=str(self.tmp / "other"), wait=0)
        self.assertEqual((busy["ok"], busy["error"], busy["job"]), (False, "busy", first["job"]))
        self.assertEqual(len(self.calls()), 1)

        resumed = self.translate(job=first["job"], wait=10)
        self.assertTrue(resumed["done"], resumed)
        self.assertEqual(resumed["output_dir"], first["job"])
        self.assertEqual(len(resumed["media"]), 2)

        os.environ["FAKE_DELAY"] = "0"
        self.assertTrue(self.translate(paths=[str(self.pages)], output_dir=str(self.tmp / "next"))["done"])

    def test_runner_failure_surfaces_error_stages_and_log_tail(self) -> None:
        os.environ["FAKE_MODE"] = "fail"
        out = self.translate(paths=[str(self.pages)], output_dir=str(self.tmp / "out"))
        self.assertFalse(out["ok"])
        self.assertEqual(out["error"], "translation provider refused")
        self.assertEqual(out["job"], str(self.tmp / "out"))
        self.assertEqual(out["stages_done"], ["detection", "ocr"])
        self.assertEqual(len(out["log_tail"]), 20)
        self.assertEqual(out["log_tail"][-1], "ERROR line 29")
        os.environ["FAKE_MODE"] = "ok"
        self.assertTrue(self.translate(paths=[str(self.pages)])["ok"])  # lock released

    def test_runner_dying_without_result_is_a_failure(self) -> None:
        os.environ["FAKE_MODE"] = "die"
        out = self.translate(paths=[str(self.pages)])
        self.assertFalse(out["ok"])
        self.assertIn("without a result", out["error"])
        self.assertEqual(out["stages_done"], ["detection"])
        self.assertEqual(out["log_tail"][-1], "panic: boom")

    def test_timeout_kills_process_group(self) -> None:
        os.environ["FAKE_MODE"] = "hang"
        os.environ["KOHARU_TIMEOUT"] = "1"
        started = time.monotonic()
        out = self.translate(paths=[str(self.pages)], wait=30)
        self.assertLess(time.monotonic() - started, 10)
        self.assertFalse(out["ok"])
        self.assertIn("timed out", out["error"])
        self.assertEqual(out["stages_done"], ["detection", "ocr"])
        runner, child = self.calls()
        self.assert_dead(runner["pid"])
        self.assert_dead(child["child"])

    def test_bad_requests_rejected_without_launching(self) -> None:
        out = self.translate(paths=[str(self.pages / "001.png"), str(self.tmp / "nope.png")])
        self.assertFalse(out["ok"])
        self.assertEqual(out["missing"], [str(self.tmp / "nope.png")])
        self.assertFalse(self.translate(paths=[])["ok"])
        unknown = self.translate(job=str(self.tmp / "nojob"))
        self.assertIn("No Koharu job", unknown["error"])
        os.environ["KOHARU_RUNNER"] = str(self.tmp / "absent")
        self.assertIn("scripts/install.sh", self.translate(paths=[str(self.pages)])["error"])
        self.assertEqual(self.calls(), [])

    def test_hermes_config_used_when_env_unset(self) -> None:
        os.environ.pop("KOHARU_RUNNER")
        settings_mod.configure(lambda key, default=None: {"runner": str(self.runner)}.get(key, default))
        self.assertTrue(self.translate(paths=[str(self.pages)])["ok"])


class _Models(BaseHTTPRequestHandler):
    hits: list = []

    def do_GET(self) -> None:  # noqa: N802
        _Models.hits.append(self.path)
        body = b'{"data": []}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        pass


class StatusTests(Base):
    def write_config(self, base_url: str) -> Path:
        path = self.home / ".koharu" / "config.toml"
        path.parent.mkdir()
        path.write_text(
            textwrap.dedent(
                f"""\
                [pipeline.detection]
                model = "det-model"

                [pipeline.ocr]
                model = "ocr-model"

                [pipeline.inpainting]
                model = "lama"

                [pipeline.translation]
                target_language = "id-ID"

                [pipeline.translation.model]
                model = "DeepSeek"
                provider = "openai-compatible"
                reasoning = true

                [providers.openai-compatible]
                base_url = "{base_url}"

                [providers.openai]
                """
            )
        )
        return path

    def status(self) -> dict:
        return json.loads(tools.handle_koharu_status({}))

    def test_reports_runner_config_and_reachable_provider(self) -> None:
        server = ThreadingHTTPServer(("127.0.0.1", 0), _Models)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        config = self.write_config(f"http://127.0.0.1:{server.server_port}/v1")
        _Models.hits.clear()
        out = self.status()
        self.assertTrue(out["ok"], out)
        self.assertEqual(out["runner"], {"path": str(self.runner), "exists": True, "version": "koharu-batch 0.83.5"})
        self.assertEqual(
            out["config"],
            {
                "path": str(config),
                "exists": True,
                "target_language": "id-ID",
                "translation_model": "DeepSeek",
                "translation_provider": "openai-compatible",
                "provider_base_url": f"http://127.0.0.1:{server.server_port}/v1",
                "detection": "det-model",
                "ocr": "ocr-model",
                "inpainting": "lama",
            },
        )
        self.assertIs(out["provider_reachable"], True)
        self.assertEqual(_Models.hits, ["/v1/models"])
        self.assertEqual(out["notes"], [])

    def test_unreachable_provider_and_missing_runner(self) -> None:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        self.write_config(f"http://127.0.0.1:{port}/v1")
        os.environ["KOHARU_RUNNER"] = str(self.tmp / "absent")
        out = self.status()
        self.assertFalse(out["ok"])
        self.assertIs(out["provider_reachable"], False)
        self.assertFalse(out["runner"]["exists"])
        self.assertTrue(any("scripts/install.sh" in note for note in out["notes"]))
        self.assertTrue(any("not reachable" in note for note in out["notes"]))

    def test_missing_config(self) -> None:
        out = self.status()
        self.assertFalse(out["config"]["exists"])
        self.assertIsNone(out["provider_reachable"])
        self.assertTrue(any("No Koharu config" in note for note in out["notes"]))


if __name__ == "__main__":
    unittest.main()
