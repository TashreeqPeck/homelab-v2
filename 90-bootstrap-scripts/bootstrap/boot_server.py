import datetime
import importlib.util
import json
import os
import pathlib
import sys
import threading
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

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


def normalize_upload_path(value: str) -> str:
    if not value.startswith("/"):
        raise ValueError("UPLOAD_PATH must start with '/'")
    return value.rstrip("/") or "/"


def parse_bool(value: str, default: bool = False) -> bool:
    normalized = (value or "").strip().lower()
    if not normalized:
        return default
    return normalized in {"1", "true", "yes", "on"}


def utc_now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


class RunStateStore:
    def __init__(
        self,
        state_file: pathlib.Path,
        events_file: pathlib.Path,
        complete_file: pathlib.Path | None,
        auto_stop_on_final: bool,
    ) -> None:
        self.state_file = state_file
        self.events_file = events_file
        self.complete_file = complete_file
        self.auto_stop_on_final = auto_stop_on_final
        self._lock = threading.Lock()
        self._state: dict[str, object] = {
            "status": "not-started",
            "events_count": 0,
            "last_update": None,
            "final_status": None,
            "run_id": None,
            "node_id": None,
        }
        self._ensure_parent_dirs()
        self._persist_state()

    def _ensure_parent_dirs(self) -> None:
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        self.events_file.parent.mkdir(parents=True, exist_ok=True)
        if self.complete_file is not None:
            self.complete_file.parent.mkdir(parents=True, exist_ok=True)

    def _persist_state(self) -> None:
        self.state_file.write_text(json.dumps(self._state, indent=2) + "\n", encoding="utf-8")

    def _append_event(self, event: dict[str, object]) -> None:
        with self.events_file.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, ensure_ascii=True) + "\n")

    def record_progress(self, event: dict[str, object]) -> dict[str, object]:
        with self._lock:
            self._state["status"] = "in-progress"
            self._state["last_update"] = event["timestamp"]
            self._state["run_id"] = event.get("run_id")
            self._state["node_id"] = event.get("node_id")
            self._state["events_count"] = int(self._state.get("events_count", 0)) + 1

            self._append_event(event)
            self._persist_state()
            return dict(self._state)

    def record_final(self, event: dict[str, object]) -> dict[str, object]:
        with self._lock:
            final_status = str(event.get("status", "")).strip().lower()
            self._state["status"] = "completed" if final_status == "success" else "failed"
            self._state["final_status"] = final_status
            self._state["last_update"] = event["timestamp"]
            self._state["run_id"] = event.get("run_id")
            self._state["node_id"] = event.get("node_id")
            self._state["events_count"] = int(self._state.get("events_count", 0)) + 1

            self._append_event(event)
            self._persist_state()

            if self.auto_stop_on_final and self.complete_file is not None:
                completion_payload = {
                    "timestamp": event["timestamp"],
                    "status": self._state["status"],
                    "final_status": final_status,
                    "run_id": event.get("run_id"),
                    "node_id": event.get("node_id"),
                }
                self.complete_file.write_text(
                    json.dumps(completion_payload, indent=2) + "\n",
                    encoding="utf-8",
                )

            return dict(self._state)

    def get_state(self) -> dict[str, object]:
        with self._lock:
            return dict(self._state)


class BootHandler(SimpleHTTPRequestHandler):
    pxe_dir = pathlib.Path(".")
    answer_file = pathlib.Path(".")
    answer_path = "/answer"
    progress_path = "/api/progress"
    final_path = "/api/final"
    state_path = "/api/state"
    install_webhook_path = "/api/post-installation-webhook"
    upload_path = "/api/shared-files"
    shared_files_dir = pathlib.Path("shared-files")
    install_webhook_events_file = pathlib.Path("bootstrap-install-webhook-events.jsonl")
    state_store: RunStateStore | None = None


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

    def _send_json(self, status: HTTPStatus, payload: dict[str, object]) -> None:
        body = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self) -> dict[str, object]:
        raw_length = self.headers.get("Content-Length", "0") or "0"
        try:
            content_length = int(raw_length)
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc

        payload = self.rfile.read(content_length)
        try:
            decoded = json.loads(payload.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError("request body must be valid JSON") from exc

        if not isinstance(decoded, dict):
            raise ValueError("request body must be a JSON object")

        return decoded

    def _validate_common(self, payload: dict[str, object]) -> tuple[str | None, str]:
        run_id = payload.get("run_id")
        run_id_value = None if run_id is None else str(run_id).strip() or None

        node_id = str(payload.get("node_id", "")).strip()
        if not node_id:
            raise ValueError("node_id is required")

        return run_id_value, node_id

    def _handle_progress(self) -> None:
        if self.state_store is None:
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "state store unavailable"})
            return

        try:
            payload = self._read_json_body()
            run_id, node_id = self._validate_common(payload)
            phase = str(payload.get("phase", "")).strip()
            step = str(payload.get("step", "")).strip()
            status = str(payload.get("status", "")).strip().lower()
            message = str(payload.get("message", "")).strip()

            if not phase:
                raise ValueError("phase is required")
            if not step:
                raise ValueError("step is required")
            if status not in {"started", "in-progress", "completed", "failed"}:
                raise ValueError("status must be one of: started, in-progress, completed, failed")

            event = {
                "event": "progress",
                "timestamp": utc_now_iso(),
                "run_id": run_id,
                "node_id": node_id,
                "phase": phase,
                "step": step,
                "status": status,
                "message": message,
            }

            state = self.state_store.record_progress(event)
        except ValueError as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return
        except OSError as exc:
            log(f"Failed to record progress event: {exc}", "ERROR")
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "failed to persist progress event"})
            return

        log(
            f"Progress update node={event['node_id']} phase={event['phase']} step={event['step']} status={event['status']}",
            "INFO",
        )
        self._send_json(HTTPStatus.OK, {"ok": True, "state": state})

    def _handle_final(self) -> None:
        if self.state_store is None:
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "state store unavailable"})
            return

        try:
            payload = self._read_json_body()
            run_id, node_id = self._validate_common(payload)
            status = str(payload.get("status", "")).strip().lower()
            message = str(payload.get("message", "")).strip()

            if status not in {"success", "failed"}:
                raise ValueError("status must be either success or failed")

            event = {
                "event": "final",
                "timestamp": utc_now_iso(),
                "run_id": run_id,
                "node_id": node_id,
                "status": status,
                "message": message,
            }

            state = self.state_store.record_final(event)
        except ValueError as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return
        except OSError as exc:
            log(f"Failed to record final event: {exc}", "ERROR")
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "failed to persist final event"})
            return

        log(f"Final status received node={event['node_id']} status={event['status']}", "INFO")
        self._send_json(HTTPStatus.OK, {"ok": True, "state": state})

    def _handle_state(self) -> None:
        if self.state_store is None:
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "state store unavailable"})
            return
        self._send_json(HTTPStatus.OK, {"ok": True, "state": self.state_store.get_state()})

    def _handle_install_webhook(self) -> None:
        try:
            payload = self._read_json_body()
            event = {
                "event": "installer-post-installation-webhook",
                "timestamp": utc_now_iso(),
                "remote": self.client_address[0] if self.client_address else None,
                "payload": payload,
            }

            self.install_webhook_events_file.parent.mkdir(parents=True, exist_ok=True)
            with self.install_webhook_events_file.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(event, ensure_ascii=True) + "\n")
        except ValueError as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return
        except OSError as exc:
            log(f"Failed to persist installer webhook event: {exc}", "ERROR")
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "failed to persist installer webhook event"})
            return

        schema = payload.get("$schema")
        fqdn = payload.get("fqdn")
        machine_id = payload.get("machine-id")
        log(
            "Installer webhook received"
            f" schema={schema} fqdn={fqdn} machine-id={machine_id}",
            "INFO",
        )
        self._send_json(HTTPStatus.OK, {"ok": True})

    @staticmethod
    def _sanitize_upload_name(raw_name: str) -> str:
        name = unquote(raw_name).strip()
        if not name:
            raise ValueError("filename is required")
        if "/" in name or "\\" in name:
            raise ValueError("filename must not include path separators")
        if name in {".", ".."}:
            raise ValueError("invalid filename")
        return name

    def _handle_shared_file_upload(self) -> None:
        raw_length = self.headers.get("Content-Length", "0") or "0"
        try:
            content_length = int(raw_length)
        except ValueError:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid Content-Length"})
            return

        if content_length <= 0:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "request body is required"})
            return

        request_path = normalize_request_path(self.path)
        suffix = request_path[len(self.upload_path):]
        filename = suffix.lstrip("/")
        if not filename:
            filename = str(self.headers.get("X-Filename", "")).strip()

        try:
            safe_name = self._sanitize_upload_name(filename)
        except ValueError as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return

        payload = self.rfile.read(content_length)
        destination = (self.shared_files_dir / safe_name).resolve()

        try:
            self.shared_files_dir.mkdir(parents=True, exist_ok=True)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(payload)
        except OSError as exc:
            log(f"Failed to persist shared file upload {safe_name}: {exc}", "ERROR")
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "failed to save uploaded file"})
            return

        log(f"Shared file uploaded name={safe_name} bytes={len(payload)}", "INFO")
        self._send_json(
            HTTPStatus.OK,
            {
                "ok": True,
                "name": safe_name,
                "bytes": len(payload),
                "path": str(destination),
                "url": f"/shared-files/{safe_name}",
            },
        )

    def do_GET(self):
        request_path = normalize_request_path(self.path)
        if request_path == self.answer_path:
            self._serve_answer()
            return
        if request_path == self.state_path:
            self._handle_state()
            return
        super().do_GET()

    def do_POST(self):
        request_path = normalize_request_path(self.path)
        if request_path == self.answer_path:
            _ = self.rfile.read(int(self.headers.get("Content-Length", "0") or "0"))
            self._serve_answer()
            return
        if request_path == self.progress_path:
            self._handle_progress()
            return
        if request_path == self.final_path:
            self._handle_final()
            return
        if request_path == self.install_webhook_path:
            self._handle_install_webhook()
            return
        if request_path == self.upload_path or request_path.startswith(self.upload_path + "/"):
            self._handle_shared_file_upload()
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
        progress_path = normalize_answer_path(os.environ.get("PROGRESS_PATH", "/api/progress"))
        final_path = normalize_answer_path(os.environ.get("FINAL_PATH", "/api/final"))
        state_path = normalize_answer_path(os.environ.get("STATE_PATH", "/api/state"))
        install_webhook_path = normalize_answer_path(
            os.environ.get("INSTALL_WEBHOOK_PATH", "/api/post-installation-webhook")
        )
        upload_path = normalize_upload_path(os.environ.get("UPLOAD_PATH", "/api/shared-files"))
        shared_files_dir = pathlib.Path(
            os.environ.get("SHARED_FILES_DIR", str(pxe_dir / "shared-files"))
        ).resolve()
        run_state_file = pathlib.Path(
            os.environ.get("RUN_STATE_FILE", str(pxe_dir / "bootstrap-run-state.json"))
        ).resolve()
        events_file = pathlib.Path(
            os.environ.get("EVENTS_FILE", str(pxe_dir / "bootstrap-events.jsonl"))
        ).resolve()
        install_webhook_events_file = pathlib.Path(
            os.environ.get(
                "INSTALL_WEBHOOK_EVENTS_FILE",
                str(pxe_dir / "bootstrap-install-webhook-events.jsonl"),
            )
        ).resolve()
        complete_file_raw = os.environ.get("COMPLETE_FILE", "").strip()
        complete_file = pathlib.Path(complete_file_raw).resolve() if complete_file_raw else None
        auto_stop_on_final = parse_bool(os.environ.get("AUTO_STOP_ON_FINAL", "true"), default=True)
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
    BootHandler.progress_path = progress_path
    BootHandler.final_path = final_path
    BootHandler.state_path = state_path
    BootHandler.install_webhook_path = install_webhook_path
    BootHandler.upload_path = upload_path
    BootHandler.shared_files_dir = shared_files_dir
    BootHandler.install_webhook_events_file = install_webhook_events_file
    BootHandler.state_store = RunStateStore(
        state_file=run_state_file,
        events_file=events_file,
        complete_file=complete_file,
        auto_stop_on_final=auto_stop_on_final,
    )

    try:
        server = ThreadingHTTPServer((bind_addr, port), BootHandler)
    except OSError as exc:
        log(f"Failed to bind HTTP server on {bind_addr}:{port}: {exc}", "ERROR")
        return 2

    log(f"Serving PXE files from: {pxe_dir}")
    log(f"Serving answer file: {answer_file}")
    log(f"Progress endpoint: {progress_path}")
    log(f"Final endpoint: {final_path}")
    log(f"Installer webhook endpoint: {install_webhook_path}")
    log(f"Shared file upload endpoint: {upload_path}/<filename>")
    log(f"State endpoint: {state_path}")
    log(f"Shared files directory: {shared_files_dir}")
    log(f"State file: {run_state_file}")
    log(f"Events file: {events_file}")
    log(f"Installer webhook events file: {install_webhook_events_file}")
    if complete_file is not None:
        log(f"Completion signal file: {complete_file}")
    log(f"HTTP server listening on http://{bind_addr}:{port}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Stopping server...")
    finally:
        server.server_close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
