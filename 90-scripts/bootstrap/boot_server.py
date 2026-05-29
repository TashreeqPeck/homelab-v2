import os
import pathlib
import sys
import importlib.util
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

LOGGING_DIR = pathlib.Path(__file__).resolve().parents[1] / "logging"
COMMON_LOGGING_PY = LOGGING_DIR / "common_logging.py"
if not COMMON_LOGGING_PY.is_file():
    raise FileNotFoundError(f"Shared logging module not found: {COMMON_LOGGING_PY}")

_logging_spec = importlib.util.spec_from_file_location("common_logging", COMMON_LOGGING_PY)
if _logging_spec is None or _logging_spec.loader is None:
    raise ImportError(f"Unable to load logging module: {COMMON_LOGGING_PY}")

_logging_module = importlib.util.module_from_spec(_logging_spec)
_logging_spec.loader.exec_module(_logging_module)
_shared_log = _logging_module.log


SCRIPT_NAME = pathlib.Path(__file__).name


def log(message: str, level: str = "INFO") -> None:
    _shared_log(message, level=level, script_name=SCRIPT_NAME)


def get_env_required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"missing required environment variable: {name}")
    return value


def normalize_answer_path(value: str) -> str:
    if not value.startswith("/"):
        raise ValueError("ANSWER_PATH must start with '/'")
    return value.rstrip("/") or "/"


def normalize_request_path(value: str) -> str:
    path = urlsplit(value).path.rstrip("/")
    return path or "/"


class BootHandler(SimpleHTTPRequestHandler):
    pxe_dir = pathlib.Path(".")
    answer_file = pathlib.Path(".")
    answer_path = "/answer"


    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(self.pxe_dir), **kwargs)

    def _serve_answer(self):
        try:
            body = self.answer_file.read_bytes()
        except OSError as exc:
            self.send_response(HTTPStatus.INTERNAL_SERVER_ERROR)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(f"failed to read answer file: {exc}\\n".encode("utf-8"))
            log(f"Failed to read answer file: {exc}", "ERROR")
            return

        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if normalize_request_path(self.path) == self.answer_path:
            self._serve_answer()
            return
        super().do_GET()

    def do_POST(self):
        if normalize_request_path(self.path) == self.answer_path:
            _ = self.rfile.read(int(self.headers.get("Content-Length", "0") or "0"))
            self._serve_answer()
            return

        self.send_response(HTTPStatus.NOT_FOUND)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"not found\\n")
        log(f"Unhandled POST path: {self.path}", "WARN")


def main() -> int:
    try:
        pxe_dir = pathlib.Path(get_env_required("PXE_DIR")).resolve()
        answer_file = pathlib.Path(get_env_required("ANSWER_FILE")).resolve()
        bind_addr = get_env_required("BIND_ADDR")
        port = int(get_env_required("PORT"))
        answer_path = normalize_answer_path(get_env_required("ANSWER_PATH"))
    except ValueError as exc:
        log(str(exc), "ERROR")
        return 2

    if not pxe_dir.is_dir():
        log(f"PXE directory not found: {pxe_dir}", "ERROR")
        return 2

    if not answer_file.is_file():
        log(f"Answer file not found: {answer_file}", "ERROR")
        return 2

    if port < 1 or port > 65535:
        log("PORT must be an integer between 1 and 65535", "ERROR")
        return 2

    BootHandler.pxe_dir = pxe_dir
    BootHandler.answer_file = answer_file
    BootHandler.answer_path = answer_path

    try:
        server = ThreadingHTTPServer((bind_addr, port), BootHandler)
    except OSError as exc:
        log(f"Failed to bind HTTP server on {bind_addr}:{port}: {exc}", "ERROR")
        return 2

    log(f"Serving PXE files from: {pxe_dir}")
    log(f"Serving answer file: {answer_file}")
    log(f"HTTP server listening on http://{bind_addr}:{port}")
    log("Press Ctrl+C to stop.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Stopping server...")
    finally:
        server.server_close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
