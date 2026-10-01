import importlib.util
import json
import tempfile
import types
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]
SCRIPT = REPOSITORY / "packages" / "bililive-recorder-notifier.py"
SPEC = importlib.util.spec_from_file_location("bililive_recorder_notifier", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
notifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notifier)


def event(event_type, event_id, **data):
    return {
        "EventType": event_type,
        "EventId": event_id,
        "EventTimestamp": "2026-08-24T18:00:00+08:00",
        "EventData": {
            "RoomId": 12345,
            "SessionId": "session-1",
            "Name": "Streamer",
            "Title": "Test stream",
            **data,
        },
    }


class BililiveRecorderNotifierTests(unittest.TestCase):
    def filtered_upload(
        self, temporary, durations, probe_error=False, upload_error=False
    ):
        root = Path(temporary) / "recordings"
        root.mkdir()
        for name in durations:
            (root / name).write_bytes(b"original recording")
        calls = []

        def run(command, **options):
            calls.append(command)
            if command[0] == "/bin/ffprobe":
                return types.SimpleNamespace(
                    returncode=int(probe_error),
                    stdout=json.dumps(
                        {"format": {"duration": durations[Path(command[-1]).name]}}
                    ),
                )
            return types.SimpleNamespace(returncode=int(upload_error))

        app = notifier.NotificationApp(
            node="edge-a",
            room_ids=[12345],
            ntfy_server="https://ntfy.example",
            ntfy_topic="inbox",
            store=notifier.StateStore(Path(temporary) / "state.json"),
            uploader=Path("/bin/biliup"),
            uploader_cookie=Path("/run/cookies.json"),
            recording_root=root,
            ffprobe=Path("/bin/ffprobe"),
            minimum_upload_duration=10,
            run_command=run,
            wall_time=lambda: 1000,
        )
        app.state["uploads"]["test-upload"] = {
            "upload_id": "test-upload",
            "name": "Streamer",
            "title": "Live",
            "room_id": 12345,
            "started_at": "2026-10-01T00:00:00+08:00",
            "paths": list(durations),
            "attempts": 0,
            "next_attempt_at": 0,
        }
        app.flush_uploads()
        return app, calls, root

    def test_short_parts_are_retained_and_not_marked_uploaded(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, calls, root = self.filtered_upload(
                temporary,
                {"short.flv": "0.789", "boundary.flv": "10", "long.flv": "3600"},
            )
            uploads = [c for c in calls if c[0] == "/bin/biliup"]
            self.assertEqual(len(uploads), 1)
            self.assertEqual(
                uploads[0][-2:], [str(root / "boundary.flv"), str(root / "long.flv")]
            )
            self.assertTrue((root / "short.flv").is_file())
            self.assertEqual(
                set(app.state["completed_uploads"]["test-upload"]["files"]),
                {"boundary.flv", "long.flv"},
            )
            self.assertEqual(
                set(app.state["skipped_uploads"]["test-upload"]["files"]), {"short.flv"}
            )
            self.assertEqual(app.state["uploads"], {})

    def test_all_short_parts_finish_without_submission_or_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, calls, root = self.filtered_upload(temporary, {"short.flv": "5.678"})
            self.assertFalse(any(c[0] == "/bin/biliup" for c in calls))
            self.assertEqual(app.state["uploads"], {})
            self.assertEqual(app.state["completed_uploads"], {})
            self.assertIn("test-upload-skipped", app.state["outbox"])
            self.assertTrue((root / "short.flv").is_file())
            loaded = app.store.load()
            self.assertEqual(loaded["uploads"], {})
            self.assertIn("test-upload", loaded["skipped_uploads"])

    def test_probe_failure_preserves_queue_and_original(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, calls, root = self.filtered_upload(
                temporary, {"part.flv": "10"}, probe_error=True
            )
            self.assertEqual(app.state["uploads"]["test-upload"]["attempts"], 1)
            self.assertFalse(any(c[0] == "/bin/biliup" for c in calls))
            self.assertTrue((root / "part.flv").is_file())

    def test_unknown_duration_is_not_treated_as_short(self):
        for duration in ("N/A", "NaN", "Infinity", "-1"):
            with (
                self.subTest(duration=duration),
                tempfile.TemporaryDirectory() as temporary,
            ):
                app, calls, root = self.filtered_upload(
                    temporary, {"part.flv": duration}
                )
                self.assertIn("test-upload", app.state["uploads"])
                self.assertEqual(app.state["skipped_uploads"], {})
                self.assertFalse(any(c[0] == "/bin/biliup" for c in calls))

    def test_submission_failure_does_not_mark_long_parts_completed(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, calls, root = self.filtered_upload(
                temporary, {"short.flv": "3", "long.flv": "600"}, upload_error=True
            )
            self.assertIn("test-upload", app.state["uploads"])
            self.assertEqual(app.state["completed_uploads"], {})
            self.assertEqual(len(list(root.iterdir())), 2)

    def make_app(self, path, clock):
        return notifier.NotificationApp(
            node="edge-a",
            room_ids=[12345],
            ntfy_server="https://ntfy.example",
            ntfy_topic="inbox",
            store=notifier.StateStore(path),
            wall_time=lambda: clock[0],
        )

    def test_session_start_is_persisted_and_deduplicated(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "state.json"
            app = self.make_app(path, [100.0])
            payload = event("SessionStarted", "start-event")

            app.handle_event(payload)
            app.handle_event(payload)

            self.assertEqual(list(app.state["outbox"]), ["rec-edge-a-start-event"])
            self.assertEqual(app.state["seen"], ["start-event"])
            self.assertTrue(path.is_file())

    def test_loads_multiline_upload_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "metadata.json"
            path.write_text(
                json.dumps(
                    {
                        "title": "{name} - {title}",
                        "description": "第一行\n第二行 {room_id}\n",
                        "tags": ["录播", "直播回放"],
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            title, description, tags = notifier.load_upload_metadata(path)

            self.assertEqual(title, "{name} - {title}")
            self.assertEqual(description, "第一行\n第二行 {room_id}\n")
            self.assertEqual(tags, "录播,直播回放")

    def test_file_closed_after_session_end_is_included_in_delayed_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            clock = [100.0]
            app = self.make_app(Path(temporary) / "state.json", clock)

            app.handle_event(event("SessionStarted", "start-event"))
            app.handle_event(event("SessionEnded", "end-event"))
            app.handle_event(
                event(
                    "FileClosed",
                    "file-event",
                    FileSize=2 * 1024**3,
                    Duration=3661.2,
                )
            )
            clock[0] += notifier.SUMMARY_GRACE_SECONDS
            app.finalize_sessions()

            summary = app.state["outbox"]["rec-edge-a-end-event"]
            self.assertIn("1 files", summary["message"])
            self.assertIn("01:01:01", summary["message"])
            self.assertIn("2.00 GiB", summary["message"])
            self.assertEqual(app.state["sessions"], {})

    def test_accepts_multiple_rooms_and_rejects_another_room(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = notifier.NotificationApp(
                node="edge-a",
                room_ids=[12345, 732],
                ntfy_server="https://ntfy.example",
                ntfy_topic="inbox",
                store=notifier.StateStore(Path(temporary) / "state.json"),
            )
            app.handle_event(event("SessionStarted", "start-event", RoomId=732))
            self.assertIn(
                "Room 732", app.state["outbox"]["rec-edge-a-start-event"]["message"]
            )

            with self.assertRaisesRegex(ValueError, "configured room"):
                app.handle_event(event("SessionStarted", "other-event", RoomId=5440))

    def test_primary_node_queues_all_closed_segments_for_private_upload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "recordings"
            root.mkdir()
            first = root / "part-1.flv"
            second = root / "part-2.flv"
            first.touch()
            second.touch()
            calls = []

            def run(command, **options):
                calls.append((command, options))
                return types.SimpleNamespace(returncode=0)

            clock = [100.0]
            app = notifier.NotificationApp(
                node="edge-a",
                room_ids=[12345],
                ntfy_server="https://ntfy.example",
                ntfy_topic="inbox",
                store=notifier.StateStore(Path(temporary) / "state.json"),
                uploader=Path("/bin/biliup"),
                uploader_cookie=Path("/run/cookies.json"),
                recording_root=root,
                upload_title="[{date}] {name} - {title}",
                upload_description="Room {room_id} recorded by {node}",
                upload_tags="录播,我的世界,直播回放",
                run_command=run,
                wall_time=lambda: clock[0],
            )
            app.handle_event(event("SessionStarted", "start-event"))
            app.handle_event(event("FileClosed", "file-1", RelativePath="part-1.flv"))
            app.handle_event(event("FileClosed", "file-2", RelativePath="part-2.flv"))
            app.handle_event(event("SessionEnded", "end-event"))
            clock[0] += notifier.UPLOAD_GRACE_SECONDS

            app.finalize_sessions()
            app.flush_uploads()

            self.assertEqual(len(calls), 1)
            command, options = calls[0]
            self.assertIn("--is-only-self", command)
            self.assertEqual(command[command.index("--is-only-self") + 1], "1")
            self.assertEqual(
                command[command.index("--title") + 1],
                "[2026-08-24] Streamer - Test stream",
            )
            self.assertEqual(
                command[command.index("--desc") + 1],
                "Room 12345 recorded by edge-a",
            )
            self.assertEqual(
                command[command.index("--tag") + 1],
                "录播,我的世界,直播回放",
            )
            self.assertEqual(command[-2:], [str(first), str(second)])
            self.assertEqual(options["timeout"], 24 * 60 * 60)
            self.assertEqual(app.state["uploads"], {})
            self.assertIn("upload-edge-a-session-1-done", app.state["outbox"])

    def test_reconnected_sessions_are_uploaded_as_one_multi_part_submission(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "recordings"
            root.mkdir()
            first = root / "part-1.flv"
            second = root / "part-2.flv"
            first.touch()
            second.touch()
            calls = []
            clock = [100.0]

            def run(command, **options):
                calls.append((command, options))
                return types.SimpleNamespace(returncode=0)

            app = notifier.NotificationApp(
                node="edge-a",
                room_ids=[12345],
                ntfy_server="https://ntfy.example",
                ntfy_topic="inbox",
                store=notifier.StateStore(Path(temporary) / "state.json"),
                uploader=Path("/bin/biliup"),
                uploader_cookie=Path("/run/cookies.json"),
                recording_root=root,
                run_command=run,
                wall_time=lambda: clock[0],
            )

            app.handle_event(event("SessionStarted", "start-1", SessionId="session-1"))
            app.handle_event(
                event(
                    "FileClosed",
                    "file-1",
                    SessionId="session-1",
                    RelativePath="part-1.flv",
                )
            )
            clock[0] = 110.0
            app.handle_event(event("SessionEnded", "end-1", SessionId="session-1"))

            clock[0] = 111.0
            app.handle_event(event("SessionStarted", "start-2", SessionId="session-2"))
            app.handle_event(
                event(
                    "FileClosed",
                    "file-2",
                    SessionId="session-2",
                    RelativePath="part-2.flv",
                )
            )
            clock[0] = 120.0
            app.handle_event(event("SessionEnded", "end-2", SessionId="session-2"))
            clock[0] = 120.0 + notifier.UPLOAD_GRACE_SECONDS

            app.finalize_sessions()
            app.flush_uploads()

            self.assertEqual(len(calls), 1)
            command, _ = calls[0]
            self.assertEqual(command[-2:], [str(first), str(second)])
            self.assertEqual(app.state["uploads"], {})

    def test_summary_waits_for_full_reconnect_window_before_finalizing(self):
        with tempfile.TemporaryDirectory() as temporary:
            clock = [100.0]
            app = self.make_app(Path(temporary) / "state.json", clock)
            app.handle_event(event("SessionStarted", "start-1", SessionId="session-1"))
            clock[0] = 110.0
            app.handle_event(event("SessionEnded", "end-1", SessionId="session-1"))

            clock[0] += 30.0
            app.finalize_sessions()
            self.assertFalse(app.state["sessions"]["session-1"]["summary_queued"])

            app.handle_event(event("SessionStarted", "start-2", SessionId="session-2"))
            self.assertNotIn("session-1", app.state["sessions"])
            self.assertIn("session-2", app.state["sessions"])

    def test_late_file_closed_for_merged_session_stays_in_the_multi_part_upload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "recordings"
            root.mkdir()
            first = root / "part-1.flv"
            second = root / "part-2.flv"
            first.touch()
            second.touch()
            clock = [100.0]
            app = notifier.NotificationApp(
                node="edge-a",
                room_ids=[12345],
                ntfy_server="https://ntfy.example",
                ntfy_topic="inbox",
                store=notifier.StateStore(Path(temporary) / "state.json"),
                uploader=Path("/bin/biliup"),
                uploader_cookie=Path("/run/cookies.json"),
                recording_root=root,
                run_command=lambda command, **options: types.SimpleNamespace(
                    returncode=0
                ),
                wall_time=lambda: clock[0],
            )

            app.handle_event(event("SessionStarted", "start-1", SessionId="session-1"))
            clock[0] = 110.0
            app.handle_event(event("SessionEnded", "end-1", SessionId="session-1"))
            clock[0] = 111.0
            app.handle_event(event("SessionStarted", "start-2", SessionId="session-2"))
            app.handle_event(
                event(
                    "FileClosed",
                    "late-file-1",
                    SessionId="session-1",
                    RelativePath="part-1.flv",
                )
            )
            app.handle_event(
                event(
                    "FileClosed",
                    "file-2",
                    SessionId="session-2",
                    RelativePath="part-2.flv",
                )
            )
            self.assertNotIn("session-1", app.state["sessions"])
            self.assertEqual(app.state["sessions"]["session-2"]["files"], 2)

    def test_sessions_outside_reconnect_window_remain_separate(self):
        with tempfile.TemporaryDirectory() as temporary:
            clock = [100.0]
            app = self.make_app(Path(temporary) / "state.json", clock)
            app.handle_event(event("SessionStarted", "start-1", SessionId="session-1"))
            clock[0] = 110.0
            app.handle_event(event("SessionEnded", "end-1", SessionId="session-1"))
            clock[0] = 110.0 + notifier.RECONNECT_MERGE_SECONDS + 1
            app.handle_event(event("SessionStarted", "start-2", SessionId="session-2"))
            self.assertEqual(set(app.state["sessions"]), {"session-1", "session-2"})


if __name__ == "__main__":
    unittest.main()
