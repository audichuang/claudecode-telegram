#!/usr/bin/env python3
"""Recording + programmable Mock-Telegram HTTP server (stdlib only).

Stands in for https://api.telegram.org so the bridge's real wire boundary
(delivery, threading, reactions, silence, media, getFile/download, dead-topic
bounce) becomes observable and falsifiable in DEFAULT-mode tests — no real
Telegram, no secrets, no third-party deps.

Usage:
    python3 tests/mock_telegram.py --port <P> --record <JSONL>

Bridge wire shapes this server understands (verified against bridge.py; forward-ported
onto the topic-only main base in v1.3.5):

  * JSON POST to /bot<TOKEN>/<method>  (Content-Type: application/json)
      sendMessage, sendChatAction, setMessageReaction, editMessageText,
      setMyCommands, answerCallbackQuery, getFile
  * multipart/form-data POST to /bot<TOKEN>/<method>
      sendPhoto, sendDocument, sendAnimation, sendVideo, sendAudio,
      sendVoice, sendSticker
      fields: chat_id, message_thread_id (ONLY when truthy), the file part,
      optional caption
  * two-step file download: POST /bot<TOKEN>/getFile then
      GET /file/bot<TOKEN>/<file_path>  (raw bytes)

Each /bot<TOKEN>/<method> POST appends ONE record (to the --record JSONL and
to an in-memory list), EXCEPT getFile — it is a QUERY (the first leg of the
two-step download) and is handled but NOT recorded; media tests assert the
downloaded bytes in the inbox, not a getFile record. Records distinguish
message_thread_id ABSENT vs present.

Control / inspection endpoints (no bot token in path):
    GET  /_health     -> 200 {"ok": true}
    GET  /_recorded   -> 200 JSON array of records
    POST /_reset      -> clears records + programmed faults
    POST /_program    -> {"thread_not_found":[<tid>...], "files":{"<path>":"<b64>"}}
"""

import argparse
import base64
import hashlib
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

# ---------------------------------------------------------------------------
# Shared mutable state (lock-guarded — the server is threaded).
# ---------------------------------------------------------------------------

_LOCK = threading.Lock()
_RECORDS: list[dict] = []
_THREAD_NOT_FOUND: set[int] = set()   # message_thread_ids that bounce once
_FILES: dict[str, bytes] = {}         # file_path -> raw bytes for /file download
_MSG_ID = [0]                         # incrementing message_id counter
_RECORD_PATH = None                   # JSONL path, or None for in-memory only


def _next_msg_id() -> int:
    _MSG_ID[0] += 1
    return _MSG_ID[0]


def _append_record(rec: dict) -> None:
    """Append one record to the in-memory list and (if configured) the JSONL."""
    with _LOCK:
        _RECORDS.append(rec)
        if _RECORD_PATH is not None:
            try:
                with open(_RECORD_PATH, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            except Exception:
                # Recording is best-effort; never crash the server on a disk hiccup.
                pass


# ---------------------------------------------------------------------------
# Hand-rolled multipart/form-data parser (cgi.FieldStorage is gone in 3.13).
# ---------------------------------------------------------------------------

def _parse_multipart(body: bytes, boundary: str) -> tuple[dict, dict | None]:
    """Return (form_fields, file_info).

    form_fields maps name -> decoded str value for simple parts.
    file_info (or None) is {"field", "filename", "size", "sha256"} for the
    one uploaded file part (the part carrying a filename=).
    """
    fields: dict[str, str] = {}
    file_info: dict | None = None
    delim = b"--" + boundary.encode()
    # Split on the boundary; first chunk is the preamble, last is the closing "--".
    for part in body.split(delim):
        # Strip EXACTLY one framing CRLF from each end — the \r\n that follows
        # the boundary and the \r\n that precedes the next one. A greedy
        # strip(b"\r\n") would also eat trailing newlines belonging to the
        # payload itself, corrupting the recorded file_size/file_sha256 for any
        # file legitimately ending in a newline (markdown/text/source).
        if part.startswith(b"\r\n"):
            part = part[2:]
        if part.endswith(b"\r\n"):
            part = part[:-2]
        if not part or part == b"--":
            continue
        header_blob, _, payload = part.partition(b"\r\n\r\n")
        headers = header_blob.decode("utf-8", "replace")
        disposition = ""
        for line in headers.split("\r\n"):
            if line.lower().startswith("content-disposition:"):
                disposition = line
                break
        name = _disp_param(disposition, "name")
        filename = _disp_param(disposition, "filename")
        if filename is not None:
            file_info = {
                "field": name,
                "filename": filename,
                "size": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
            }
        elif name is not None:
            fields[name] = payload.decode("utf-8", "replace")
    return fields, file_info


def _disp_param(disposition: str, key: str) -> str | None:
    """Extract a quoted param (e.g. name="x") from a Content-Disposition line."""
    needle = key + '="'
    idx = disposition.find(needle)
    if idx == -1:
        return None
    start = idx + len(needle)
    end = disposition.find('"', start)
    if end == -1:
        return None
    return disposition[start:end]


# ---------------------------------------------------------------------------
# Record building from a parsed call.
# ---------------------------------------------------------------------------

def _build_record(method: str, payload: dict, file_info: dict | None) -> dict:
    """Build a normalized record. message_thread_id is OMITTED when absent."""
    rec: dict = {"method": method}
    if "chat_id" in payload:
        rec["chat_id"] = _maybe_int(payload["chat_id"])
    # Preserve ABSENT vs present distinction — only set when actually sent.
    if "message_thread_id" in payload and payload["message_thread_id"] not in (None, ""):
        rec["message_thread_id"] = _maybe_int(payload["message_thread_id"])
    if "text" in payload:
        rec["text"] = payload["text"]
    if "caption" in payload:
        rec["caption"] = payload["caption"]
    if "reply_to_message_id" in payload:
        rec["reply_to_message_id"] = _maybe_int(payload["reply_to_message_id"])
    if "reaction" in payload:
        # bridge sends [{"type":"emoji","emoji":"👀"}, ...]; flatten to emoji list.
        rec["reaction"] = _reaction_emojis(payload["reaction"])
    if "action" in payload:
        rec["action"] = payload["action"]
    if file_info is not None:
        rec["file_name"] = file_info.get("filename")
        rec["file_size"] = file_info.get("size")
        rec["file_field"] = file_info.get("field")
        rec["file_sha256"] = file_info.get("sha256")
    rec["raw"] = payload
    return rec


def _reaction_emojis(reaction) -> list:
    """Normalize a setMessageReaction `reaction` value to a flat emoji list."""
    out = []
    if isinstance(reaction, list):
        for item in reaction:
            if isinstance(item, dict):
                emoji = item.get("emoji")
                if emoji is not None:
                    out.append(emoji)
                else:
                    out.append(item)
            else:
                out.append(item)
    elif reaction is not None:
        out.append(reaction)
    return out


def _maybe_int(value):
    """Coerce numeric strings (from multipart) to int; pass ints through."""
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return value
    return value


# ---------------------------------------------------------------------------
# HTTP handler.
# ---------------------------------------------------------------------------

class MockTelegramHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # Quiet logging — tests tail bridge.log, not this server's stderr.
    def log_message(self, fmt, *args):  # noqa: A003
        pass

    # -- helpers ------------------------------------------------------------

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _send_json(self, status: int, obj: dict) -> None:
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_bytes(self, status: int, data: bytes, ctype: str = "application/octet-stream") -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    # -- GET ----------------------------------------------------------------

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/_health":
            self._send_json(200, {"ok": True})
            return
        if path == "/_recorded":
            with _LOCK:
                snapshot = list(_RECORDS)
            self._send_json(200, snapshot)
            return
        # File download: GET /file/bot<TOKEN>/<file_path>
        if path.startswith("/file/bot"):
            file_path = self._extract_file_path(path)
            with _LOCK:
                data = _FILES.get(file_path)
            if data is None:
                self._send_json(404, {"ok": False, "error_code": 404,
                                      "description": "Not Found: file not registered"})
                return
            self._send_bytes(200, data)
            return
        self._send_json(404, {"ok": False, "error_code": 404, "description": "Not Found"})

    @staticmethod
    def _extract_file_path(path: str) -> str:
        # path = /file/bot<TOKEN>/<file_path...>; strip /file/bot, then drop the token segment.
        rest = path[len("/file/bot"):]
        # rest = <TOKEN>/<file_path>  — split off the first segment (the token).
        _, _, file_path = rest.partition("/")
        return unquote(file_path)

    # -- POST ---------------------------------------------------------------

    def do_POST(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        body = self._read_body()

        if path == "/_reset":
            with _LOCK:
                _RECORDS.clear()
                _THREAD_NOT_FOUND.clear()
                _FILES.clear()
                _MSG_ID[0] = 0
            self._send_json(200, {"ok": True})
            return

        if path == "/_program":
            self._handle_program(body)
            return

        # Bot API method: /bot<TOKEN>/<method>
        if path.startswith("/bot"):
            self._handle_bot_method(path, body)
            return

        self._send_json(404, {"ok": False, "error_code": 404, "description": "Not Found"})

    def _handle_program(self, body: bytes) -> None:
        try:
            prog = json.loads(body.decode("utf-8")) if body else {}
        except Exception:
            self._send_json(400, {"ok": False, "error_code": 400, "description": "Bad Request: invalid JSON"})
            return
        with _LOCK:
            for tid in prog.get("thread_not_found", []) or []:
                try:
                    _THREAD_NOT_FOUND.add(int(tid))
                except (TypeError, ValueError):
                    pass
            for fpath, b64 in (prog.get("files", {}) or {}).items():
                try:
                    _FILES[fpath] = base64.b64decode(b64)
                except Exception:
                    pass
        self._send_json(200, {"ok": True})

    def _handle_bot_method(self, path: str, body: bytes) -> None:
        # path = /bot<TOKEN>/<method>
        method = path.rsplit("/", 1)[-1]
        # Keep ORIGINAL case for boundary extraction — boundaries are case-sensitive
        # (curl uses mixed-case randoms); only lowercase for the type comparison.
        ctype = self.headers.get("Content-Type") or ""

        if ctype.lower().startswith("multipart/form-data"):
            boundary = _boundary_from_ctype(ctype)
            payload, file_info = _parse_multipart(body, boundary) if boundary else ({}, None)
        else:
            file_info = None
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
            except Exception:
                payload = {}
            if not isinstance(payload, dict):
                payload = {}

        # getFile is a query, not a recorded send — handle before recording.
        if method == "getFile":
            self._handle_getfile(payload)
            return

        rec = _build_record(method, payload, file_info)
        _append_record(rec)

        # Programmed dead-topic fault: bounce a send targeting that thread.
        tid = rec.get("message_thread_id")
        if tid is not None:
            with _LOCK:
                bounce = tid in _THREAD_NOT_FOUND
            if bounce:
                self._send_json(400, {
                    "ok": False,
                    "error_code": 400,
                    "description": "Bad Request: message thread not found",
                })
                return

        # Default success — echo chat_id/message_thread_id so reply-chaining works.
        result = {"message_id": _next_msg_id()}
        if "chat_id" in rec:
            result["chat"] = {"id": rec["chat_id"]}
        if "message_thread_id" in rec:
            result["message_thread_id"] = rec["message_thread_id"]
        self._send_json(200, {"ok": True, "result": result})

    def _handle_getfile(self, payload: dict) -> None:
        # The bridge passes file_id; it does NOT send a file_path. Pick a default
        # path unless a registered file path obviously matches the file_id.
        file_id = payload.get("file_id", "")
        with _LOCK:
            registered = list(_FILES.keys())
        file_path = None
        # If exactly one file is registered, serve it (common single-file test).
        if len(registered) == 1:
            file_path = registered[0]
        elif file_id in registered:
            file_path = file_id
        if file_path is None:
            file_path = f"documents/{file_id or 'mockfile'}.bin"
        with _LOCK:
            size = len(_FILES.get(file_path, b""))
        self._send_json(200, {
            "ok": True,
            "result": {"file_id": file_id, "file_path": file_path, "file_size": size},
        })


def _boundary_from_ctype(ctype: str) -> str | None:
    marker = "boundary="
    idx = ctype.find(marker)
    if idx == -1:
        return None
    boundary = ctype[idx + len(marker):].strip()
    # Strip optional quotes and any trailing params.
    boundary = boundary.split(";", 1)[0].strip().strip('"')
    return boundary or None


def main() -> None:
    global _RECORD_PATH
    parser = argparse.ArgumentParser(description="Mock Telegram HTTP server (stdlib only)")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--record", default=None, help="JSONL path to append records to")
    args = parser.parse_args()

    _RECORD_PATH = args.record
    if _RECORD_PATH:
        # Truncate any prior recording so a fresh run starts clean.
        open(_RECORD_PATH, "w", encoding="utf-8").close()

    class _Server(ThreadingHTTPServer):
        # allow_reuse_address makes TCPServer.server_bind set SO_REUSEADDR.
        allow_reuse_address = True
        daemon_threads = True

    server = _Server(("127.0.0.1", args.port), MockTelegramHandler)
    print(f"mock_telegram listening on 127.0.0.1:{args.port} (record={_RECORD_PATH})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
