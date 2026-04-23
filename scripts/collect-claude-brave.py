#!/usr/bin/env python3
"""Collect recent Claude.ai conversations through a dedicated Brave profile.

This script intentionally avoids Claude Code's browser integration. It owns the
Brave process it starts through the DevTools Protocol and closes only that
process when collection finishes.
"""

from __future__ import annotations

import argparse
import base64
import http.client
import json
import os
import pathlib
import re
import socket
import struct
import subprocess
import sys
import time
import urllib.parse
from typing import Any


CHAT_RE = re.compile(r"/chat/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})")
NO_SOURCE = "NO_SOURCE_CONVERSATIONS"


class CdpError(RuntimeError):
    pass


def log(log_file: str | None, message: str) -> None:
    if not log_file:
        return
    ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    pathlib.Path(log_file).parent.mkdir(parents=True, exist_ok=True)
    with open(log_file, "a", encoding="utf-8") as handle:
        handle.write(f"{ts} {message}\n")


def session_id_from_url(url: str) -> str | None:
    match = CHAT_RE.search(url)
    if not match:
        return None
    return f"claude.ai:{match.group(1).lower()}"


def comment_value(value: str) -> str:
    return value.replace("--", "- -").replace("\n", " ").strip()


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def http_json(port: int, method: str, path: str, timeout: float = 2.0) -> Any:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        conn.request(method, path)
        response = conn.getresponse()
        body = response.read()
        if response.status < 200 or response.status >= 300:
            raise CdpError(f"DevTools HTTP {method} {path} failed with {response.status}: {body[:200]!r}")
        return json.loads(body.decode("utf-8"))
    finally:
        conn.close()


def wait_for_devtools(port: int, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            http_json(port, "GET", "/json/version", timeout=1.0)
            return
        except Exception as exc:  # noqa: BLE001 - keep retrying while Brave starts.
            last_error = exc
            time.sleep(0.25)
    raise CdpError(f"DevTools endpoint did not become ready on port {port}: {last_error}")


def wait_for_page(port: int, start_url: str, timeout: float) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        targets = http_json(port, "GET", "/json/list", timeout=2.0)
        pages = [target for target in targets if target.get("type") == "page" and target.get("webSocketDebuggerUrl")]
        if pages:
            return pages[0]
        quoted = urllib.parse.quote(start_url, safe="")
        try:
            return http_json(port, "PUT", f"/json/new?{quoted}", timeout=2.0)
        except Exception:
            time.sleep(0.25)
    raise CdpError("No DevTools page target became available")


class WebSocket:
    def __init__(self, url: str) -> None:
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "ws":
            raise CdpError(f"Unsupported DevTools WebSocket URL: {url}")
        self.sock = socket.create_connection((parsed.hostname, parsed.port or 80), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        path = parsed.path or "/"
        if parsed.query:
            path += f"?{parsed.query}"
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {parsed.hostname}:{parsed.port or 80}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(request.encode("ascii"))
        response = self._read_http_response()
        if b" 101 " not in response.split(b"\r\n", 1)[0]:
            raise CdpError(f"DevTools WebSocket handshake failed: {response[:200]!r}")

    def _read_http_response(self) -> bytes:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            data += chunk
        return data

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass

    def send_json(self, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        header = bytearray([0x81])
        length = len(data)
        if length < 126:
            header.append(0x80 | length)
        elif length <= 0xFFFF:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", length))
        mask = os.urandom(4)
        header.extend(mask)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
        self.sock.sendall(bytes(header) + masked)

    def recv_json(self, timeout: float) -> dict[str, Any]:
        self.sock.settimeout(timeout)
        while True:
            message = self._recv_message()
            if message is None:
                continue
            return json.loads(message)

    def _recv_exact(self, size: int) -> bytes:
        data = b""
        while len(data) < size:
            chunk = self.sock.recv(size - len(data))
            if not chunk:
                raise CdpError("DevTools WebSocket closed")
            data += chunk
        return data

    def _recv_message(self) -> str | None:
        first, second = self._recv_exact(2)
        opcode = first & 0x0F
        length = second & 0x7F
        masked = bool(second & 0x80)
        if length == 126:
            length = struct.unpack("!H", self._recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._recv_exact(8))[0]
        mask = self._recv_exact(4) if masked else b""
        payload = self._recv_exact(length) if length else b""
        if masked:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        if opcode == 0x8:
            raise CdpError("DevTools WebSocket closed")
        if opcode == 0x9:
            self._send_control(0xA, payload)
            return None
        if opcode not in (0x1, 0x0):
            return None
        return payload.decode("utf-8")

    def _send_control(self, opcode: int, payload: bytes) -> None:
        mask = os.urandom(4)
        header = bytearray([0x80 | opcode, 0x80 | len(payload)])
        header.extend(mask)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)


class CdpClient:
    def __init__(self, ws_url: str) -> None:
        self.ws = WebSocket(ws_url)
        self.next_id = 1

    def close(self) -> None:
        self.ws.close()

    def call(self, method: str, params: dict[str, Any] | None = None, timeout: float = 30.0) -> dict[str, Any]:
        message_id = self.next_id
        self.next_id += 1
        self.ws.send_json({"id": message_id, "method": method, "params": params or {}})
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CdpError(f"Timed out waiting for CDP method {method}")
            message = self.ws.recv_json(remaining)
            if message.get("id") != message_id:
                continue
            if "error" in message:
                raise CdpError(f"CDP {method} failed: {message['error']}")
            return message.get("result", {})

    def evaluate(self, expression: str, timeout: float = 30.0, await_promise: bool = False) -> Any:
        result = self.call(
            "Runtime.evaluate",
            {
                "expression": expression,
                "awaitPromise": await_promise,
                "returnByValue": True,
                "timeout": int(timeout * 1000),
            },
            timeout=timeout + 2,
        )
        if "exceptionDetails" in result:
            raise CdpError(f"JavaScript evaluation failed: {result['exceptionDetails']}")
        value = result.get("result", {})
        return value.get("value")


def evaluate_stable(
    cdp: CdpClient,
    expression: str,
    timeout: float = 30.0,
    await_promise: bool = False,
    attempts: int = 4,
) -> Any:
    last_error: CdpError | None = None
    for attempt in range(attempts):
        try:
            return cdp.evaluate(expression, timeout=timeout, await_promise=await_promise)
        except CdpError as exc:
            message = str(exc)
            if "Inspected target navigated or closed" not in message:
                raise
            last_error = exc
            time.sleep(0.75 + attempt * 0.5)
    if last_error is not None:
        raise last_error
    raise CdpError("Runtime evaluation failed")


def wait_ready(cdp: CdpClient, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            state = cdp.evaluate("document.readyState", timeout=3)
            if state in ("interactive", "complete"):
                time.sleep(1.0)
                return
        except Exception:
            pass
        time.sleep(0.25)
    raise CdpError("Page did not become ready")


def navigate(cdp: CdpClient, url: str, timeout: float) -> None:
    cdp.call("Page.navigate", {"url": url}, timeout=timeout)
    wait_ready(cdp, timeout)


def auth_state(cdp: CdpClient) -> dict[str, Any]:
    return evaluate_stable(
        cdp,
        """
(() => {
  const text = (document.body && document.body.innerText || "").slice(0, 5000);
  const textLength = (document.body && document.body.innerText || "").trim().length;
  const authText = /log in|sign in|sign up|get started|continue with google|continue with email|email address|로그인|가입|계속|이메일/i.test(text);
  const authUrl = /\\/login|\\/auth|\\/oauth|\\/signup/.test(location.pathname);
  const chatLinkCount = document.querySelectorAll('a[href*="/chat/"]').length;
  const composerCount = document.querySelectorAll('textarea, [contenteditable="true"], [role="textbox"]').length;
  const newChatText = /new chat|새 채팅|새 대화/i.test(text);
  const authenticated = !authUrl && !authText && (chatLinkCount > 0 || composerCount > 0 || newChatText);
  return {
    url: location.href,
    title: document.title,
    auth: !authenticated,
    authenticated,
    authText,
    authUrl,
    chatLinkCount,
    composerCount,
    textLength
  };
})()
""",
        timeout=10,
    )


def collect_links(cdp: CdpClient, max_links: int, scroll_rounds: int) -> list[dict[str, str]]:
    expression = f"""
(async () => {{
  const maxLinks = {int(max_links)};
  const scrollRounds = {int(scroll_rounds)};
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const chatRe = /\\/chat\\/[0-9a-fA-F-]{{36}}/;
  const seen = new Map();
  function clean(value) {{
    return String(value || "").replace(/\\s+/g, " ").trim();
  }}
  function addLinks() {{
    for (const anchor of document.querySelectorAll('a[href]')) {{
      let href = "";
      try {{
        href = new URL(anchor.getAttribute('href'), location.href).href;
      }} catch {{
        continue;
      }}
      if (!chatRe.test(href) || seen.has(href)) continue;
      const row = anchor.closest('li, article, [role="listitem"], [data-testid], div');
      seen.set(href, {{
        url: href,
        title: clean(anchor.innerText || anchor.getAttribute('aria-label') || document.title),
        context: clean(row && row.innerText || anchor.innerText || "")
      }});
      if (seen.size >= maxLinks) return;
    }}
  }}
  function scrollTargets() {{
    return Array.from(document.querySelectorAll('*'))
      .filter((element) => element.scrollHeight > element.clientHeight + 160)
      .sort((a, b) => (b.scrollHeight - b.clientHeight) - (a.scrollHeight - a.clientHeight))
      .slice(0, 6);
  }}
  for (let round = 0; round <= scrollRounds && seen.size < maxLinks; round += 1) {{
    addLinks();
    for (const target of scrollTargets()) {{
      target.scrollTop += Math.max(240, target.clientHeight * 0.9);
    }}
    window.scrollBy(0, Math.max(400, window.innerHeight * 0.8));
    await sleep(600);
  }}
  addLinks();
  return Array.from(seen.values()).slice(0, maxLinks);
}})()
"""
    value = evaluate_stable(cdp, expression, timeout=45, await_promise=True)
    return value if isinstance(value, list) else []


def extract_conversation(cdp: CdpClient, max_chars: int) -> dict[str, Any]:
    expression = f"""
(() => {{
  function clean(value) {{
    return String(value || "")
      .replace(/[\\t\\r ]+\\n/g, "\\n")
      .replace(/\\n{{3,}}/g, "\\n\\n")
      .trim();
  }}
  const roots = Array.from(document.querySelectorAll('main, [role="main"], article, body'));
  let best = document.body;
  for (const root of roots) {{
    if ((root.innerText || "").length > ((best && best.innerText || "").length)) best = root;
  }}
  const text = clean(best && best.innerText || document.body.innerText || "");
  return {{
    url: location.href,
    title: clean(document.title || ""),
    text: text.slice(0, {int(max_chars)}),
    textLength: text.length
  }};
}})()
"""
    value = evaluate_stable(cdp, expression, timeout=20)
    if not isinstance(value, dict):
        raise CdpError("Conversation extraction returned no object")
    return value


def load_existing(path: str | None) -> set[str]:
    if not path:
        return set()
    source = pathlib.Path(path)
    if not source.exists():
        return set()
    return {line.strip() for line in source.read_text(encoding="utf-8").splitlines() if line.strip()}


def write_no_source(output: str) -> None:
    pathlib.Path(output).write_text(f"{NO_SOURCE}\n", encoding="utf-8")


def write_conversations(output: str, conversations: list[dict[str, Any]], date: str) -> None:
    lines = [
        "<!-- scraped:claude-ai-conversations-start -->",
        f"<!-- scraped:kst-date={comment_value(date)} -->",
        "",
    ]
    for item in conversations:
        lines.extend(
            [
                "<!-- scraped:conversation-start -->",
                "<!-- source: claude.ai dedicated Brave profile -->",
                f"<!-- capture:session-id={comment_value(item['session_id'])} -->",
                f"<!-- title: {comment_value(item.get('title') or '')} -->",
                f"<!-- url: {comment_value(item.get('url') or '')} -->",
                "",
                item.get("text", "").strip(),
                "",
                "<!-- scraped:conversation-end -->",
                "",
            ]
        )
    lines.append("<!-- scraped:claude-ai-conversations-end -->")
    pathlib.Path(output).write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def launch_brave(args: argparse.Namespace, port: int) -> subprocess.Popen[Any]:
    profile = pathlib.Path(args.profile_dir).expanduser()
    profile.mkdir(parents=True, exist_ok=True)
    command = [
        args.brave_bin,
        f"--user-data-dir={profile}",
        f"--remote-debugging-port={port}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-mode",
        "--new-window",
        "about:blank",
    ]
    return subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def terminate_process(process: subprocess.Popen[Any], log_file: str | None) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        log(log_file, f"WARN force killing dedicated Brave process pid={process.pid}")
        process.kill()
        process.wait(timeout=5)


def collect(args: argparse.Namespace) -> int:
    existing = load_existing(args.existing_session_ids_file)
    port = args.remote_debugging_port or find_free_port()
    cdp: CdpClient | None = None
    process: subprocess.Popen[Any] | None = None
    keep_open = False

    try:
        process = launch_brave(args, port)
        log(args.log_file, f"INFO launched dedicated Brave profile pid={process.pid} port={port}")
        wait_for_devtools(port, args.browser_timeout)
        page = wait_for_page(port, args.start_url, args.browser_timeout)
        cdp = CdpClient(page["webSocketDebuggerUrl"])
        cdp.call("Page.enable")
        cdp.call("Runtime.enable")

        navigate(cdp, args.start_url, args.browser_timeout)
        state = auth_state(cdp)
        if state.get("auth"):
            log(args.log_file, f"ERROR Claude.ai dedicated Brave profile is not authenticated: {state.get('url')}")
            if args.keep_open_on_auth:
                keep_open = True
                log(args.log_file, f"INFO leaving dedicated Brave profile open for manual login: {args.profile_dir}")
            return 4

        if args.auth_check_only:
            pathlib.Path(args.output).write_text("AUTH_OK\n", encoding="utf-8")
            log(args.log_file, "INFO dedicated Brave profile authentication check passed")
            return 0

        links = collect_links(cdp, args.max_links, args.scroll_rounds)
        if not links and args.start_url.rstrip("/") != "https://claude.ai":
            navigate(cdp, "https://claude.ai/", args.browser_timeout)
            links = collect_links(cdp, args.max_links, args.scroll_rounds)

        unique_links: list[dict[str, str]] = []
        seen_sessions: set[str] = set()
        for link in links:
            session_id = session_id_from_url(link.get("url", ""))
            if not session_id or session_id in existing or session_id in seen_sessions:
                continue
            seen_sessions.add(session_id)
            unique_links.append(link)

        conversations: list[dict[str, Any]] = []
        for link in unique_links[: args.max_conversations]:
            session_id = session_id_from_url(link["url"])
            if not session_id:
                continue
            navigate(cdp, link["url"], args.browser_timeout)
            state = auth_state(cdp)
            if state.get("auth"):
                raise CdpError(f"Authentication required while opening conversation: {state.get('url')}")
            extracted = extract_conversation(cdp, args.max_chars_per_conversation)
            text = (extracted.get("text") or "").strip()
            if len(text) < args.min_conversation_chars:
                log(args.log_file, f"WARN skipped short scraped conversation: {session_id}")
                continue
            conversations.append(
                {
                    "session_id": session_id,
                    "url": link["url"],
                    "title": link.get("title") or extracted.get("title") or "",
                    "context": link.get("context") or "",
                    "text": text,
                }
            )

        if not conversations:
            write_no_source(args.output)
            log(args.log_file, "INFO no new Claude.ai conversations scraped from dedicated Brave profile")
            return 0

        write_conversations(args.output, conversations, args.date)
        log(args.log_file, f"INFO scraped Claude.ai conversations from dedicated Brave profile: count={len(conversations)}")
        return 0
    except Exception as exc:  # noqa: BLE001 - command-line boundary logs concise failure.
        log(args.log_file, f"ERROR dedicated Brave scrape failed: {exc}")
        return 1
    finally:
        if cdp is not None:
            cdp.close()
        if process is not None and not keep_open:
            terminate_process(process, args.log_file)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--log-file")
    parser.add_argument("--existing-session-ids-file")
    parser.add_argument("--brave-bin", default="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")
    parser.add_argument("--profile-dir", required=True)
    parser.add_argument("--start-url", default="https://claude.ai/recents")
    parser.add_argument("--remote-debugging-port", type=int, default=0)
    parser.add_argument("--browser-timeout", type=float, default=45.0)
    parser.add_argument("--max-links", type=int, default=24)
    parser.add_argument("--max-conversations", type=int, default=8)
    parser.add_argument("--max-chars-per-conversation", type=int, default=50000)
    parser.add_argument("--min-conversation-chars", type=int, default=400)
    parser.add_argument("--scroll-rounds", type=int, default=8)
    parser.add_argument("--keep-open-on-auth", action="store_true")
    parser.add_argument("--auth-check-only", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if not pathlib.Path(args.brave_bin).exists():
        log(args.log_file, f"ERROR Brave executable not found: {args.brave_bin}")
        return 1
    return collect(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
