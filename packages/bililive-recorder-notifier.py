#!/usr/bin/env python3

import argparse
import json
import logging
import os
import re
import signal
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


LOG = logging.getLogger("bililive-recorder-notifier")
SAFE_NODE = re.compile(r"[A-Za-z0-9_-]{1,24}")
MAX_BODY_BYTES = 1024 * 1024
MAX_SEEN_EVENTS = 512
SUMMARY_GRACE_SECONDS = 20
RECONNECT_MERGE_SECONDS = 60
UPLOAD_GRACE_SECONDS = 300


def empty_state() -> dict[str, Any]:
    return {
        "seen": [],
        "outbox": {},
        "sessions": {},
        "session_aliases": {},
        "uploads": {},
    }


class StateStore:
    def __init__(self, path: Path):
        self.path = path

    def load(self) -> dict[str, Any]:
        try:
            state = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return empty_state()
        if not isinstance(state, dict):
            raise ValueError("notification state must be a JSON object")
        state.setdefault("seen", [])
        state.setdefault("outbox", {})
        state.setdefault("sessions", {})
        state.setdefault("session_aliases", {})
        state.setdefault("uploads", {})
        return state

    def save(self, state: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            dir=self.path.parent, prefix=f".{self.path.name}.", text=True
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                json.dump(state, output, ensure_ascii=False, separators=(",", ":"))
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary_name, self.path)
        finally:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def format_duration(seconds: float) -> str:
    total = max(0, round(seconds))
    hours, remainder = divmod(total, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def format_size(size: int) -> str:
    gibibytes = max(0, size) / (1024**3)
    return f"{gibibytes:.2f} GiB"


def load_upload_metadata(path: Path) -> tuple[str, str, str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("upload metadata must be a JSON object")
    title = data.get("title")
    description = data.get("description")
    tags = data.get("tags")
    if not isinstance(title, str) or not title:
        raise ValueError("upload title template must be a non-empty string")
    if not isinstance(description, str) or not description:
        raise ValueError("upload description template must be a non-empty string")
    if not isinstance(tags, list) or not tags or not all(
        isinstance(tag, str) and tag and "," not in tag for tag in tags
    ):
        raise ValueError("upload tags must be non-empty strings without commas")
    return title, description, ",".join(tags)


class NotificationApp:
    def __init__(
        self,
        *,
        node: str,
        room_ids: list[int],
        ntfy_server: str,
        ntfy_topic: str,
        store: StateStore,
        uploader: Path | None = None,
        uploader_cookie: Path | None = None,
        recording_root: Path | None = None,
        upload_line: str = "alia",
        upload_title: str = "{name} 直播回放 {title} {date}",
        upload_description: str = "直播间：https://live.bilibili.com/{room_id}\n由 {node} 自动录制上传。",
        upload_tags: str = "录播,直播回放",
        run_command: Any = subprocess.run,
        wall_time: Any = time.time,
    ):
        if not SAFE_NODE.fullmatch(node):
            raise ValueError("node must contain only letters, numbers, underscores, or hyphens")
        self.node = node
        if not room_ids or len(room_ids) != len(set(room_ids)):
            raise ValueError("room IDs must be non-empty and unique")
        self.room_ids = set(room_ids)
        self.ntfy_server = ntfy_server.rstrip("/")
        self.ntfy_topic = ntfy_topic
        self.store = store
        self.uploader = uploader
        self.uploader_cookie = uploader_cookie
        self.recording_root = recording_root
        self.upload_line = upload_line
        self.upload_title = upload_title
        self.upload_description = upload_description
        self.upload_tags = upload_tags
        self.run_command = run_command
        self.wall_time = wall_time
        self.state = store.load()
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.stopping = threading.Event()

    def handle_event(self, event: dict[str, Any]) -> None:
        event_type = event.get("EventType")
        event_id = event.get("EventId")
        data = event.get("EventData")
        if not isinstance(event_type, str) or not isinstance(event_id, str):
            raise ValueError("webhook event is missing EventType or EventId")
        if not isinstance(data, dict):
            raise ValueError("webhook EventData must be an object")
        room_id = data.get("RoomId")
        if room_id not in self.room_ids:
            raise ValueError("webhook room does not match a configured room")

        with self.lock:
            if event_id in self.state["seen"]:
                return
            self.state["seen"].append(event_id)
            self.state["seen"] = self.state["seen"][-MAX_SEEN_EVENTS:]

            if event_type == "SessionStarted":
                self._session_started(event_id, event, data)
            elif event_type == "FileClosed":
                self._file_closed(event, data)
            elif event_type == "SessionEnded":
                self._session_ended(event_id, event, data)

            self.store.save(self.state)
        self.wake.set()

    def _session(self, event: dict[str, Any], data: dict[str, Any]) -> dict[str, Any]:
        session_id = str(data.get("SessionId", "unknown"))
        session_id = self.state["session_aliases"].get(session_id, session_id)
        session = self.state["sessions"].get(session_id)
        if session is None:
            session = {
                "name": str(data.get("Name", "Unknown streamer")),
                "title": str(data.get("Title", "")),
                "room_id": int(data["RoomId"]),
                "started_at": str(event.get("EventTimestamp", "")),
                "started_at_epoch": self.wall_time(),
                "files": 0,
                "size": 0,
                "duration": 0.0,
                "paths": [],
                "ended_at": None,
                "end_event_id": None,
                "summary_queued": False,
            }
            self.state["sessions"][session_id] = session
            if event.get("EventType") == "SessionStarted":
                predecessor_id, predecessor = self._find_reconnect_predecessor(
                    session_id, session["room_id"], session["started_at_epoch"]
                )
                if predecessor is not None:
                    self._merge_session(session, predecessor)
                    del self.state["sessions"][predecessor_id]
                    self.state["session_aliases"][predecessor_id] = session_id
                    LOG.info(
                        "Merged reconnected session %s into %s",
                        predecessor_id,
                        session_id,
                    )
        session.setdefault("paths", [])
        session.setdefault("started_at_epoch", self.wall_time())
        session.setdefault("summary_queued", False)
        return session

    def _find_reconnect_predecessor(
        self, session_id: str, room_id: int, started_at: float
    ) -> tuple[str, dict[str, Any] | None]:
        candidates: list[tuple[str, dict[str, Any]]] = []
        for predecessor_id, predecessor in self.state["sessions"].items():
            if predecessor_id == session_id or predecessor.get("room_id") != room_id:
                continue
            if predecessor.get("ended_at") is None or predecessor.get("summary_queued"):
                continue
            try:
                gap = started_at - float(predecessor["ended_at"])
            except (KeyError, TypeError, ValueError):
                continue
            if 0 <= gap <= RECONNECT_MERGE_SECONDS:
                candidates.append((predecessor_id, predecessor))
        if not candidates:
            return "", None
        return max(candidates, key=lambda item: float(item[1]["ended_at"]))

    @staticmethod
    def _merge_session(target: dict[str, Any], predecessor: dict[str, Any]) -> None:
        target["files"] += predecessor.get("files", 0)
        target["size"] += predecessor.get("size", 0)
        target["duration"] += predecessor.get("duration", 0.0)
        target["paths"] = list(dict.fromkeys(
            [*predecessor.get("paths", []), *target.get("paths", [])]
        ))
        target["started_at"] = predecessor.get("started_at", target["started_at"])
        target["started_at_epoch"] = min(
            float(predecessor.get("started_at_epoch", target["started_at_epoch"])),
            float(target["started_at_epoch"]),
        )
        if not target.get("name"):
            target["name"] = predecessor.get("name", "Unknown streamer")
        if not target.get("title"):
            target["title"] = predecessor.get("title", "")

    def _queue(
        self, sequence_id: str, *, title: str, message: str, tags: list[str]
    ) -> None:
        self.state["outbox"].setdefault(
            sequence_id,
            {
                "sequence_id": sequence_id,
                "title": title,
                "message": message,
                "tags": tags,
                "attempts": 0,
                "next_attempt_at": 0.0,
            },
        )

    def _session_started(
        self, event_id: str, event: dict[str, Any], data: dict[str, Any]
    ) -> None:
        session = self._session(event, data)
        self._queue(
            f"rec-{self.node}-{event_id}",
            title=f"「{session['name']}」 Recording · {session['title']}",
            message=(
                f"Node {self.node} | Room {session['room_id']}\n"
                f"Started {event.get('EventTimestamp', '')}"
            ),
            tags=["red_circle"],
        )

    def _file_closed(self, event: dict[str, Any], data: dict[str, Any]) -> None:
        session = self._session(event, data)
        session["files"] += 1
        session["size"] += max(0, int(data.get("FileSize", 0)))
        session["duration"] += max(0.0, float(data.get("Duration", 0.0)))
        relative_path = data.get("RelativePath")
        if isinstance(relative_path, str) and relative_path.endswith(".flv"):
            if relative_path not in session["paths"]:
                session["paths"].append(relative_path)

    def _session_ended(
        self, event_id: str, event: dict[str, Any], data: dict[str, Any]
    ) -> None:
        session = self._session(event, data)
        session["ended_at"] = self.wall_time()
        session["end_event_id"] = event_id

    def finalize_sessions(self) -> None:
        now = self.wall_time()
        changed = False
        with self.lock:
            for session_id, session in list(self.state["sessions"].items()):
                ended_at = session.get("ended_at")
                if ended_at is None:
                    continue
                elapsed = now - float(ended_at)
                if elapsed >= SUMMARY_GRACE_SECONDS and not session["summary_queued"]:
                    sequence_id = f"rec-{self.node}-{session['end_event_id']}"
                    self._queue(
                        sequence_id,
                        title=f"「{session['name']}」 Recorded · {self.node}",
                        message=(
                            f"Room {session['room_id']} | {session['files']} files | "
                            f"{format_duration(session['duration'])} | "
                            f"{format_size(session['size'])}"
                        ),
                        tags=["white_check_mark"],
                    )
                    session["summary_queued"] = True
                    changed = True

                if self.uploader is None:
                    if session["summary_queued"]:
                        del self.state["sessions"][session_id]
                        changed = True
                    continue

                if elapsed < UPLOAD_GRACE_SECONDS:
                    continue
                upload_id = f"upload-{self.node}-{session_id}"
                self.state["uploads"].setdefault(
                    upload_id,
                    {
                        "upload_id": upload_id,
                        "name": session["name"],
                        "title": session["title"],
                        "room_id": session["room_id"],
                        "session_id": session_id,
                        "started_at": session["started_at"],
                        "paths": session["paths"],
                        "attempts": 0,
                        "next_attempt_at": 0.0,
                    },
                )
                del self.state["sessions"][session_id]
                changed = True
            if changed:
                self.store.save(self.state)
        if changed:
            self.wake.set()

    def flush_uploads(self) -> None:
        if self.uploader is None:
            return
        now = self.wall_time()
        with self.lock:
            pending = [
                dict(upload)
                for upload in self.state["uploads"].values()
                if float(upload["next_attempt_at"]) <= now
            ]
        for upload in pending:
            try:
                files = self._resolve_recordings(upload["paths"])
                if not files:
                    raise ValueError("upload has no closed FLV segments")
                result = self.run_command(
                    self._upload_command(upload, files),
                    check=False,
                    timeout=24 * 60 * 60,
                )
                if result.returncode != 0:
                    raise OSError(f"biliup exited with status {result.returncode}")
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                with self.lock:
                    current = self.state["uploads"].get(upload["upload_id"])
                    if current is None:
                        continue
                    current["attempts"] += 1
                    current["next_attempt_at"] = self.wall_time() + min(
                        3600, 60 * 2 ** min(current["attempts"] - 1, 6)
                    )
                    if current["attempts"] == 1:
                        self._queue(
                            f"{upload['upload_id']}-failed",
                            title=f"「{upload['name']}」 Upload delayed · {self.node}",
                            message=f"Room {upload['room_id']} | {type(error).__name__}",
                            tags=["warning"],
                        )
                    self.store.save(self.state)
                LOG.warning("Upload %s remains queued: %s", upload["upload_id"], error)
                continue

            with self.lock:
                self.state["uploads"].pop(upload["upload_id"], None)
                self._queue(
                    f"{upload['upload_id']}-done",
                    title=f"「{upload['name']}」 Uploaded privately · {self.node}",
                    message=f"Room {upload['room_id']} | {len(files)} parts",
                    tags=["arrow_up", "lock"],
                )
                self.store.save(self.state)
            LOG.info("Upload %s completed", upload["upload_id"])

    def _resolve_recordings(self, paths: list[str]) -> list[Path]:
        if self.recording_root is None:
            raise ValueError("recording root is not configured")
        root = self.recording_root.resolve()
        files = []
        for relative_path in paths:
            candidate = (root / relative_path).resolve()
            if candidate.suffix != ".flv" or root not in candidate.parents:
                raise ValueError("webhook recording path escapes the recording root")
            if not candidate.is_file():
                raise OSError(f"closed recording is unavailable: {relative_path}")
            files.append(candidate)
        return files

    def _upload_command(self, upload: dict[str, Any], files: list[Path]) -> list[str]:
        if self.uploader_cookie is None:
            raise ValueError("uploader cookie is not configured")
        date = str(upload["started_at"]).split("T", 1)[0]
        values = {
            "name": str(upload["name"]),
            "title": str(upload["title"]),
            "date": date,
            "room_id": str(upload["room_id"]),
            "node": self.node,
        }
        title = self._render_template(self.upload_title, values)[:80]
        description = self._render_template(self.upload_description, values)
        return [
            str(self.uploader),
            "--user-cookie",
            str(self.uploader_cookie),
            "upload",
            "--submit",
            "web",
            "--line",
            self.upload_line,
            "--limit",
            "3",
            "--copyright",
            "2",
            "--source",
            f"https://live.bilibili.com/{upload['room_id']}",
            "--tid",
            "27",
            "--title",
            title,
            "--desc",
            description,
            "--tag",
            self.upload_tags,
            "--is-only-self",
            "1",
            *(str(path) for path in files),
        ]

    @staticmethod
    def _render_template(template: str, values: dict[str, str]) -> str:
        for key, value in values.items():
            template = template.replace("{" + key + "}", value)
        return template

    def flush_outbox(self) -> None:
        now = self.wall_time()
        with self.lock:
            pending = [
                dict(message)
                for message in self.state["outbox"].values()
                if float(message["next_attempt_at"]) <= now
            ]
        for message in pending:
            try:
                self._publish(message)
            except (OSError, urllib.error.URLError, urllib.error.HTTPError) as error:
                with self.lock:
                    current = self.state["outbox"].get(message["sequence_id"])
                    if current is None:
                        continue
                    current["attempts"] += 1
                    current["next_attempt_at"] = self.wall_time() + min(
                        900, 30 * 2 ** min(current["attempts"] - 1, 5)
                    )
                    self.store.save(self.state)
                LOG.warning(
                    "Notification %s remains queued after %s",
                    message["sequence_id"],
                    type(error).__name__,
                )
                continue
            with self.lock:
                self.state["outbox"].pop(message["sequence_id"], None)
                self.store.save(self.state)
            LOG.info("Notification %s delivered", message["sequence_id"])

    def _publish(self, message: dict[str, Any]) -> None:
        payload = json.dumps(
            {
                "topic": self.ntfy_topic,
                "title": message["title"],
                "message": message["message"],
                "tags": message["tags"],
                "sequence_id": message["sequence_id"],
            },
            ensure_ascii=False,
        ).encode("utf-8")
        request = urllib.request.Request(
            self.ntfy_server,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            if not 200 <= response.status < 300:
                raise urllib.error.HTTPError(
                    self.ntfy_server,
                    response.status,
                    "ntfy returned a non-success status",
                    response.headers,
                    None,
                )

    def run_worker(self) -> None:
        while not self.stopping.is_set():
            self.finalize_sessions()
            self.flush_uploads()
            self.flush_outbox()
            self.wake.wait(timeout=5)
            self.wake.clear()


class WebhookHandler(BaseHTTPRequestHandler):
    app: NotificationApp

    def do_GET(self) -> None:
        if self.path != "/health":
            self.send_error(404)
            return
        body = b'{"status":"ok"}\n'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        if self.path != "/webhook":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_BODY_BYTES:
                raise ValueError("invalid webhook body length")
            event = json.loads(self.rfile.read(length))
            if not isinstance(event, dict):
                raise ValueError("webhook body must be a JSON object")
            self.app.handle_event(event)
        except (ValueError, TypeError, json.JSONDecodeError) as error:
            LOG.warning("Rejected webhook: %s", error)
            self.send_error(400)
            return
        self.send_response(204)
        self.end_headers()

    def log_message(self, message: str, *args: Any) -> None:
        LOG.info("Webhook HTTP: " + message, *args)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", required=True)
    parser.add_argument("--room-id", required=True, action="append", type=int)
    parser.add_argument("--ntfy-server", required=True)
    parser.add_argument("--ntfy-topic", required=True)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--uploader", type=Path)
    parser.add_argument("--uploader-cookie", type=Path)
    parser.add_argument("--recording-root", type=Path)
    parser.add_argument("--upload-line", default="alia")
    parser.add_argument("--upload-metadata", type=Path)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", default=22357, type=int)
    return parser.parse_args()


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    args = parse_args()
    upload_title = "{name} 直播回放 {title} {date}"
    upload_description = (
        "直播间：https://live.bilibili.com/{room_id}\n由 {node} 自动录制上传。"
    )
    upload_tags = "录播,直播回放"
    if args.upload_metadata is not None:
        upload_title, upload_description, upload_tags = load_upload_metadata(
            args.upload_metadata
        )
    app = NotificationApp(
        node=args.node,
        room_ids=args.room_id,
        ntfy_server=args.ntfy_server,
        ntfy_topic=args.ntfy_topic,
        store=StateStore(args.state),
        uploader=args.uploader,
        uploader_cookie=args.uploader_cookie,
        recording_root=args.recording_root,
        upload_line=args.upload_line,
        upload_title=upload_title,
        upload_description=upload_description,
        upload_tags=upload_tags,
    )
    WebhookHandler.app = app
    server = ThreadingHTTPServer((args.listen, args.port), WebhookHandler)
    worker = threading.Thread(target=app.run_worker, name="notification-outbox", daemon=True)
    worker.start()

    def stop(_signum: int, _frame: Any) -> None:
        app.stopping.set()
        app.wake.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    LOG.info("Listening on http://%s:%s", args.listen, args.port)
    server.serve_forever()
    server.server_close()
    worker.join(timeout=10)


if __name__ == "__main__":
    main()
