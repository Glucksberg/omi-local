#!/usr/bin/env python3
"""Small local API for omi-local desktop development.

This service implements the chat/session routes that the macOS app already
expects from the hosted backend. It is intentionally boring: stdlib HTTP,
SQLite persistence, local loopback only by default.
"""

from __future__ import annotations

import json
import os
import re
import signal
import sqlite3
import sys
import threading
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse


APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Omi Local"
DEFAULT_DB_PATH = APP_SUPPORT / "local-api" / "omi-local.db"
HOST = os.environ.get("OMI_LOCAL_API_HOST", "127.0.0.1")
PORT = int(os.environ.get("OMI_LOCAL_API_PORT", "10201"))
DB_PATH = Path(os.environ.get("OMI_LOCAL_API_DB_PATH", str(DEFAULT_DB_PATH))).expanduser()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def parse_int(value: str | None, default: int, minimum: int = 0, maximum: int = 500) -> int:
    if value is None:
        return default
    try:
        parsed = int(value)
    except ValueError:
        return default
    return min(max(parsed, minimum), maximum)


def parse_bool(value: str | None) -> bool | None:
    if value is None:
        return None
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    return None


def clean_optional_text(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        value = str(value)
    value = value.strip()
    if not value or value.lower() in {"null", "none"}:
        return None
    return value


def title_from_messages(messages: list[dict[str, Any]]) -> str:
    for message in messages:
        text = clean_optional_text(message.get("text"))
        if not text:
            continue
        title = " ".join(text.split())
        if len(title) > 56:
            title = title[:53].rstrip() + "..."
        return title or "New Chat"
    return "New Chat"


class LocalStore:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("PRAGMA journal_mode = WAL")
        return conn

    def _init_db(self) -> None:
        with self._lock, self._connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS chat_sessions (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    preview TEXT,
                    app_id TEXT,
                    message_count INTEGER NOT NULL DEFAULT 0,
                    starred INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_chat_sessions_created_at
                    ON chat_sessions(created_at DESC);
                CREATE INDEX IF NOT EXISTS idx_chat_sessions_app_id
                    ON chat_sessions(app_id);
                CREATE INDEX IF NOT EXISTS idx_chat_sessions_starred
                    ON chat_sessions(starred);

                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY,
                    text TEXT NOT NULL,
                    sender TEXT NOT NULL CHECK(sender IN ('human', 'ai')),
                    app_id TEXT,
                    session_id TEXT,
                    rating INTEGER,
                    reported INTEGER NOT NULL DEFAULT 0,
                    metadata TEXT,
                    created_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_messages_created_at
                    ON messages(created_at DESC);
                CREATE INDEX IF NOT EXISTS idx_messages_app_id
                    ON messages(app_id);
                CREATE INDEX IF NOT EXISTS idx_messages_session_id
                    ON messages(session_id);

                CREATE TABLE IF NOT EXISTS llm_usage (
                    id TEXT PRIMARY KEY,
                    account TEXT,
                    input_tokens INTEGER NOT NULL DEFAULT 0,
                    output_tokens INTEGER NOT NULL DEFAULT 0,
                    cache_read_tokens INTEGER NOT NULL DEFAULT 0,
                    cache_write_tokens INTEGER NOT NULL DEFAULT 0,
                    total_tokens INTEGER NOT NULL DEFAULT 0,
                    cost_usd REAL NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL
                );
                """
            )

    def create_session(self, title: str | None, app_id: str | None, session_id: str | None = None) -> dict[str, Any]:
        now = utc_now()
        sid = session_id or str(uuid.uuid4())
        session = {
            "id": sid,
            "title": title or "New Chat",
            "preview": None,
            "app_id": app_id,
            "message_count": 0,
            "starred": False,
            "created_at": now,
            "updated_at": now,
        }
        with self._lock, self._connect() as conn:
            conn.execute(
                """
                INSERT OR IGNORE INTO chat_sessions
                    (id, title, preview, app_id, message_count, starred, created_at, updated_at)
                VALUES
                    (:id, :title, :preview, :app_id, :message_count, :starred, :created_at, :updated_at)
                """,
                {**session, "starred": 1 if session["starred"] else 0},
            )
            row = conn.execute("SELECT * FROM chat_sessions WHERE id = ?", (sid,)).fetchone()
        return self._session_from_row(row)

    def list_sessions(
        self,
        app_id: str | None,
        app_id_filter_present: bool,
        starred: bool | None,
        limit: int,
        offset: int,
    ) -> list[dict[str, Any]]:
        where: list[str] = []
        params: list[Any] = []
        if app_id_filter_present:
            if app_id is None:
                where.append("app_id IS NULL")
            else:
                where.append("app_id = ?")
                params.append(app_id)
        if starred is not None:
            where.append("starred = ?")
            params.append(1 if starred else 0)
        sql = "SELECT * FROM chat_sessions"
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
        params.extend([limit, offset])
        with self._lock, self._connect() as conn:
            rows = conn.execute(sql, params).fetchall()
        return [self._session_from_row(row) for row in rows]

    def get_session(self, session_id: str) -> dict[str, Any] | None:
        with self._lock, self._connect() as conn:
            row = conn.execute("SELECT * FROM chat_sessions WHERE id = ?", (session_id,)).fetchone()
        return self._session_from_row(row) if row else None

    def update_session(self, session_id: str, title: str | None, starred: bool | None) -> dict[str, Any] | None:
        assignments: list[str] = []
        params: list[Any] = []
        if title is not None:
            assignments.append("title = ?")
            params.append(title)
        if starred is not None:
            assignments.append("starred = ?")
            params.append(1 if starred else 0)
        assignments.append("updated_at = ?")
        params.append(utc_now())
        params.append(session_id)

        with self._lock, self._connect() as conn:
            conn.execute(f"UPDATE chat_sessions SET {', '.join(assignments)} WHERE id = ?", params)
            row = conn.execute("SELECT * FROM chat_sessions WHERE id = ?", (session_id,)).fetchone()
        return self._session_from_row(row) if row else None

    def delete_session(self, session_id: str) -> bool:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM messages WHERE session_id = ?", (session_id,))
            cursor = conn.execute("DELETE FROM chat_sessions WHERE id = ?", (session_id,))
        return cursor.rowcount > 0

    def save_message(
        self,
        text: str,
        sender: str,
        app_id: str | None,
        session_id: str | None,
        metadata: str | None,
    ) -> dict[str, Any]:
        now = utc_now()
        message_id = str(uuid.uuid4())
        with self._lock, self._connect() as conn:
            conn.execute(
                """
                INSERT INTO messages
                    (id, text, sender, app_id, session_id, rating, reported, metadata, created_at)
                VALUES (?, ?, ?, ?, ?, NULL, 0, ?, ?)
                """,
                (message_id, text, sender, app_id, session_id, metadata, now),
            )
            if session_id:
                self._ensure_session_in_conn(conn, session_id, app_id)
                self._refresh_session_preview_in_conn(conn, session_id, text, now)
        return {"id": message_id, "created_at": now}

    def list_messages(
        self,
        app_id: str | None,
        app_id_filter_present: bool,
        session_id: str | None,
        limit: int,
        offset: int,
    ) -> list[dict[str, Any]]:
        where: list[str] = []
        params: list[Any] = []
        if app_id_filter_present:
            if app_id is None:
                where.append("app_id IS NULL")
            else:
                where.append("app_id = ?")
                params.append(app_id)
        if session_id is not None:
            where.append("session_id = ?")
            params.append(session_id)

        sql = "SELECT * FROM messages"
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
        params.extend([limit, offset])

        with self._lock, self._connect() as conn:
            rows = conn.execute(sql, params).fetchall()
        return [self._message_from_row(row) for row in rows]

    def delete_messages(self, app_id: str | None, app_id_filter_present: bool) -> int:
        with self._lock, self._connect() as conn:
            if not app_id_filter_present:
                cursor = conn.execute("DELETE FROM messages")
            elif app_id is None:
                cursor = conn.execute("DELETE FROM messages WHERE app_id IS NULL")
            else:
                cursor = conn.execute("DELETE FROM messages WHERE app_id = ?", (app_id,))
            conn.execute(
                """
                UPDATE chat_sessions
                SET preview = NULL,
                    message_count = (
                        SELECT COUNT(*) FROM messages WHERE messages.session_id = chat_sessions.id
                    ),
                    updated_at = ?
                """,
                (utc_now(),),
            )
        return cursor.rowcount

    def rate_message(self, message_id: str, rating: int | None) -> bool:
        with self._lock, self._connect() as conn:
            cursor = conn.execute("UPDATE messages SET rating = ? WHERE id = ?", (rating, message_id))
        return cursor.rowcount > 0

    def record_usage(self, payload: dict[str, Any]) -> None:
        now = utc_now()
        with self._lock, self._connect() as conn:
            conn.execute(
                """
                INSERT INTO llm_usage
                    (id, account, input_tokens, output_tokens, cache_read_tokens,
                     cache_write_tokens, total_tokens, cost_usd, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    clean_optional_text(payload.get("account")),
                    int(payload.get("input_tokens") or 0),
                    int(payload.get("output_tokens") or 0),
                    int(payload.get("cache_read_tokens") or 0),
                    int(payload.get("cache_write_tokens") or 0),
                    int(payload.get("total_tokens") or 0),
                    float(payload.get("cost_usd") or 0),
                    now,
                ),
            )

    def total_usage_cost(self) -> float:
        with self._lock, self._connect() as conn:
            row = conn.execute("SELECT COALESCE(SUM(cost_usd), 0) AS total FROM llm_usage").fetchone()
        return float(row["total"] or 0)

    def message_count(self) -> int:
        with self._lock, self._connect() as conn:
            row = conn.execute("SELECT COUNT(*) AS total FROM messages").fetchone()
        return int(row["total"] or 0)

    def _ensure_session_in_conn(self, conn: sqlite3.Connection, session_id: str, app_id: str | None) -> None:
        exists = conn.execute("SELECT 1 FROM chat_sessions WHERE id = ?", (session_id,)).fetchone()
        if exists:
            return
        now = utc_now()
        conn.execute(
            """
            INSERT INTO chat_sessions
                (id, title, preview, app_id, message_count, starred, created_at, updated_at)
            VALUES (?, 'New Chat', NULL, ?, 0, 0, ?, ?)
            """,
            (session_id, app_id, now, now),
        )

    def _refresh_session_preview_in_conn(
        self,
        conn: sqlite3.Connection,
        session_id: str,
        preview: str,
        now: str,
    ) -> None:
        conn.execute(
            """
            UPDATE chat_sessions
            SET preview = ?,
                message_count = (
                    SELECT COUNT(*) FROM messages WHERE session_id = ?
                ),
                updated_at = ?
            WHERE id = ?
            """,
            (preview, session_id, now, session_id),
        )

    @staticmethod
    def _session_from_row(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "title": row["title"],
            "preview": row["preview"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "app_id": row["app_id"],
            "message_count": int(row["message_count"]),
            "starred": bool(row["starred"]),
        }

    @staticmethod
    def _message_from_row(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "text": row["text"],
            "created_at": row["created_at"],
            "sender": row["sender"],
            "app_id": row["app_id"],
            "session_id": row["session_id"],
            "rating": row["rating"],
            "reported": bool(row["reported"]),
            "metadata": row["metadata"],
        }


STORE = LocalStore(DB_PATH)


class LocalAPIHandler(BaseHTTPRequestHandler):
    server_version = "omi-local-api/0.1"

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self._cors_headers()
        self.end_headers()

    def do_GET(self) -> None:
        path, query = self._path_and_query()
        if path in {"/", "/health"}:
            self._send_json({"status": "ok", "mode": "omi-local", "db_path": str(DB_PATH)})
            return

        if path == "/v2/chat-sessions":
            self._handle_list_sessions(query)
            return

        if match := re.fullmatch(r"/v2/chat-sessions/([^/]+)", path):
            session = STORE.get_session(match.group(1))
            if session is None:
                self._send_error(HTTPStatus.NOT_FOUND, "chat session not found")
                return
            self._send_json(session)
            return

        if path in {"/v2/desktop/messages", "/v2/messages"}:
            self._handle_list_messages(query)
            return

        if path == "/v1/users/me/llm-usage/total":
            self._send_json({"total_cost_usd": STORE.total_usage_cost()})
            return

        if path == "/v1/users/me/usage-quota":
            self._send_json(
                {
                    "plan": "Local",
                    "plan_type": "local",
                    "unit": "questions",
                    "used": 0,
                    "limit": None,
                    "percent": 0,
                    "allowed": True,
                    "reset_at": None,
                }
            )
            return

        if path == "/v1/users/stats/chat-messages":
            self._send_json({"count": STORE.message_count()})
            return

        if path == "/v1/config/api-keys":
            self._send_json(
                {
                    "deepgram_api_key": None,
                    "gemini_api_key": None,
                    "firebase_api_key": None,
                    "google_calendar_api_key": None,
                }
            )
            return

        if path == "/v1/crisp/unread":
            self._send_json({"unread_count": 0, "messages": []})
            return

        self._send_error(HTTPStatus.NOT_FOUND, "not found")

    def do_POST(self) -> None:
        path, _query = self._path_and_query()
        payload = self._read_json()
        if payload is None:
            return

        if path == "/v2/chat-sessions":
            session = STORE.create_session(
                title=clean_optional_text(payload.get("title")),
                app_id=clean_optional_text(payload.get("app_id")),
            )
            self._send_json(session, HTTPStatus.CREATED)
            return

        if path in {"/v2/desktop/messages", "/v2/messages"}:
            self._handle_save_message(payload)
            return

        if path == "/v2/chat/initial-message":
            session_id = clean_optional_text(payload.get("session_id"))
            if session_id is None:
                self._send_error(HTTPStatus.BAD_REQUEST, "session_id is required")
                return
            app_id = clean_optional_text(payload.get("app_id"))
            greeting = "Ola. Estou pronto para ajudar no Omi Local."
            saved = STORE.save_message(greeting, "ai", app_id, session_id, None)
            self._send_json({"message": greeting, "message_id": saved["id"]})
            return

        if path == "/v2/chat/generate-title":
            session_id = clean_optional_text(payload.get("session_id"))
            messages = payload.get("messages") if isinstance(payload.get("messages"), list) else []
            title = title_from_messages(messages)
            if session_id:
                STORE.update_session(session_id, title=title, starred=None)
            self._send_json({"title": title})
            return

        if path == "/v1/users/me/llm-usage":
            STORE.record_usage(payload)
            self._send_json({"status": "ok"})
            return

        self._send_error(HTTPStatus.NOT_FOUND, "not found")

    def do_PATCH(self) -> None:
        path, _query = self._path_and_query()
        payload = self._read_json()
        if payload is None:
            return

        if match := re.fullmatch(r"/v2/chat-sessions/([^/]+)", path):
            session = STORE.update_session(
                match.group(1),
                title=clean_optional_text(payload.get("title")) if "title" in payload else None,
                starred=parse_bool(str(payload.get("starred")).lower()) if "starred" in payload else None,
            )
            if session is None:
                self._send_error(HTTPStatus.NOT_FOUND, "chat session not found")
                return
            self._send_json(session)
            return

        if match := re.fullmatch(r"/v2/(?:desktop/)?messages/([^/]+)/rating", path):
            rating = payload.get("rating")
            if rating is not None:
                try:
                    rating = int(rating)
                except (TypeError, ValueError):
                    self._send_error(HTTPStatus.BAD_REQUEST, "rating must be 1, -1, or null")
                    return
                if rating not in {1, -1}:
                    self._send_error(HTTPStatus.BAD_REQUEST, "rating must be 1, -1, or null")
                    return
            if not STORE.rate_message(match.group(1), rating):
                self._send_error(HTTPStatus.NOT_FOUND, "message not found")
                return
            self._send_json({"status": "ok"})
            return

        self._send_error(HTTPStatus.NOT_FOUND, "not found")

    def do_DELETE(self) -> None:
        path, query = self._path_and_query()
        if match := re.fullmatch(r"/v2/chat-sessions/([^/]+)", path):
            STORE.delete_session(match.group(1))
            self._send_json({"status": "ok"})
            return

        if path in {"/v2/desktop/messages", "/v2/messages"}:
            app_id_present = "app_id" in query
            app_id = clean_optional_text(query.get("app_id", [None])[0])
            deleted = STORE.delete_messages(app_id, app_id_present)
            self._send_json({"status": "ok", "deleted_count": deleted})
            return

        self._send_error(HTTPStatus.NOT_FOUND, "not found")

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[%s] local-api %s\n" % (datetime.now().strftime("%H:%M:%S"), fmt % args))

    def _handle_list_sessions(self, query: dict[str, list[str]]) -> None:
        limit = parse_int(query.get("limit", [None])[0], default=50, maximum=200)
        offset = parse_int(query.get("offset", [None])[0], default=0, maximum=100_000)
        app_id_present = "app_id" in query
        app_id = clean_optional_text(query.get("app_id", [None])[0])
        starred = parse_bool(query.get("starred", [None])[0])
        sessions = STORE.list_sessions(app_id, app_id_present, starred, limit, offset)
        self._send_json(sessions)

    def _handle_list_messages(self, query: dict[str, list[str]]) -> None:
        limit = parse_int(query.get("limit", [None])[0], default=100, maximum=500)
        offset = parse_int(query.get("offset", [None])[0], default=0, maximum=100_000)
        app_id_present = "app_id" in query
        app_id = clean_optional_text(query.get("app_id", [None])[0])
        session_id = clean_optional_text(query.get("session_id", [None])[0])
        messages = STORE.list_messages(app_id, app_id_present, session_id, limit, offset)
        self._send_json(messages)

    def _handle_save_message(self, payload: dict[str, Any]) -> None:
        text = clean_optional_text(payload.get("text"))
        sender = clean_optional_text(payload.get("sender"))
        if text is None:
            self._send_error(HTTPStatus.BAD_REQUEST, "text is required")
            return
        if sender not in {"human", "ai"}:
            self._send_error(HTTPStatus.BAD_REQUEST, "sender must be human or ai")
            return
        saved = STORE.save_message(
            text=text,
            sender=sender,
            app_id=clean_optional_text(payload.get("app_id")),
            session_id=clean_optional_text(payload.get("session_id")),
            metadata=clean_optional_text(payload.get("metadata")),
        )
        self._send_json(saved, HTTPStatus.CREATED)

    def _path_and_query(self) -> tuple[str, dict[str, list[str]]]:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") if parsed.path != "/" else parsed.path
        return path, parse_qs(parsed.query, keep_blank_values=True)

    def _read_json(self) -> dict[str, Any] | None:
        raw_length = self.headers.get("Content-Length")
        length = parse_int(raw_length, default=0, maximum=10_000_000)
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send_error(HTTPStatus.BAD_REQUEST, "invalid json")
            return None
        if not isinstance(payload, dict):
            self._send_error(HTTPStatus.BAD_REQUEST, "json object expected")
            return None
        return payload

    def _send_json(self, payload: Any, status: HTTPStatus = HTTPStatus.OK) -> None:
        data = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self._cors_headers()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _send_error(self, status: HTTPStatus, message: str) -> None:
        self._send_json({"detail": message}, status)

    def _cors_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header(
            "Access-Control-Allow-Headers",
            "Authorization, Content-Type, X-App-Platform, X-Request-Start-Time",
        )
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")


def main() -> int:
    httpd = ThreadingHTTPServer((HOST, PORT), LocalAPIHandler)

    def shutdown(_signum: int, _frame: Any) -> None:
        httpd.shutdown()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    print(f"omi-local-api listening on http://{HOST}:{PORT} db={DB_PATH}", flush=True)
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
