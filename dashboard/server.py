"""Zero-dependency, loopback-only WebUI for the existing daily launcher."""
import argparse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
from pathlib import Path
import secrets
import traceback
import webbrowser
from urllib.parse import parse_qs, urlparse

from model import DailyModel
from support import AppError, encode_json, now
from updates import UpdateManager

STATIC = Path(__file__).parent / "static"


class Handler(BaseHTTPRequestHandler):
    server_version = "DailyDesk/1.0"

    def log_message(self, fmt, *args):
        print(now(), fmt % args, flush=True)

    def send_bytes(self, content, kind, code=200, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(content)

    def json(self, content, code=200):
        self.send_bytes(encode_json(content), "application/json; charset=utf-8", code)

    def guard(self, mutation=False):
        expected = "127.0.0.1:" + str(self.server.server_port)
        if self.headers.get("Host") != expected:
            raise AppError("仅允许通过本机控制台地址访问。", 403)
        if mutation:
            if self.headers.get("Origin") not in (None, "http://" + expected) or self.headers.get("X-Daily-Token") != self.server.token:
                raise AppError("页面授权已过期，请刷新后重试。", 403)
            if self.headers.get_content_type() != "application/json":
                raise AppError("请求格式无效。", 415)

    def status(self):
        status = self.server.model.status()
        updates = self.server.updates.status()
        if updates["operation"] and updates["operation"]["action"] == "install":
            status["busy"] = True
            status["updating"] = True
        return status

    def configuration(self):
        with self.server.model.lock:
            return self.server.model.plans.configuration()

    def do_GET(self):
        try:
            self.guard()
            parsed = urlparse(self.path)
            path = parsed.path
            if path == "/api/bootstrap":
                return self.json({"token": self.server.token, "configuration": self.configuration(), "status": self.status()})
            if path == "/api/status":
                return self.json(self.status())
            if path == "/api/config":
                return self.json(self.configuration())
            if path == "/api/updates":
                return self.json(self.server.updates.status())
            if path == "/api/runs":
                return self.json({"runs": self.server.model.histories()})
            if path.startswith("/api/runs/"):
                run_id = path.removeprefix("/api/runs/")
                return self.json(self.server.model.run_detail(run_id))
            if path == "/api/evidence":
                query = parse_qs(parsed.query)
                file = self.server.model.evidence(query.get("run", [""])[0], query.get("path", [""])[0])
                raw = file.read_bytes()
                if file.suffix.lower() not in (".png", ".jpg"):
                    raw = raw.decode("utf-8-sig", errors="replace").encode("utf-8")
                    kind = "text/plain; charset=utf-8"
                else:
                    kind = mimetypes.guess_type(file.name)[0]
                return self.send_bytes(raw, kind)
            if path == "/api/health":
                return self.json({"app": "daily-desk", "version": 1,
                                  "configPath": str(getattr(self.server.model, "config_path", ""))})
            if path == "/brand-icon":
                local_icon = STATIC / "march7th.ico"
                if local_icon.is_file():
                    return self.send_bytes(local_icon.read_bytes(), "image/vnd.microsoft.icon")
                path = "/logo.svg"
            files = {"/": "index.html", "/app.js": "app.js", "/styles.css": "styles.css",
                     "/logo.svg": "logo.svg", "/March7th.ico": "march7th.ico"}
            if path not in files or not (STATIC / files[path]).exists():
                raise AppError("页面不存在。", 404)
            file = STATIC / files[path]
            # Keep the local dashboard response types stable across Python and OS MIME tables.
            # Windows maps .js to application/javascript, while the browser contract uses text/javascript.
            kinds = {
                ".html": "text/html; charset=utf-8",
                ".js": "text/javascript; charset=utf-8",
                ".css": "text/css; charset=utf-8",
                ".svg": "image/svg+xml",
                ".ico": "image/vnd.microsoft.icon",
            }
            kind = kinds.get(file.suffix.lower(), mimetypes.guess_type(file.name)[0] or "application/octet-stream")
            return self.send_bytes(file.read_bytes(), kind)
        except AppError as exc:
            self.json({"error": str(exc)}, exc.status)
        except Exception:
            traceback.print_exc()
            self.json({"error": "读取失败，请稍后刷新；原始记录与配置已保留。"}, 500)

    def do_POST(self):
        try:
            self.guard(mutation=True)
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 64000:
                raise AppError("请求内容过大或为空。", 413)
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise AppError("请求格式无效。")
            path = urlparse(self.path).path
            if path == "/api/updates" and set(body) == {"action", "game"}:
                return self.json(self.server.updates.start(body["action"], body["game"]), 202)
            if path == "/api/updates/auto" and set(body) == {"game", "enabled"}:
                return self.json(self.server.updates.set_auto(body["game"], body["enabled"]))
            if path == "/api/config":
                with self.server.model.lock:
                    if self.server.updates.installing():
                        raise AppError("软件正在更新，请稍后再保存。", 409)
                    return self.json(self.server.model.plans.save(body))
            if path == "/api/launch" and set(body) == {"game"}:
                with self.server.model.lock:
                    if self.server.updates.installing():
                        raise AppError("软件正在更新，请稍后再运行日常。", 409)
                    return self.json(self.server.model.launch(body["game"]), 202)
            if path == "/api/stop" and set(body) == {"runId"}:
                return self.json(self.server.model.stop(body["runId"]))
            if path == "/api/open-record" and set(body) == {"runId"}:
                return self.json(self.server.model.open_record_folder(body["runId"]))
            raise AppError("操作不存在。", 404)
        except AppError as exc:
            self.json({"error": str(exc)}, exc.status)
        except (ValueError, TypeError, KeyError):
            self.json({"error": "配置数据无效，请刷新后重试。"}, 400)
        except Exception:
            traceback.print_exc()
            self.json({"error": "操作未完成，已保留备份。请检查控制台日志。"}, 500)


def create_server(root, port=17861, model=None):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    server.model = model or DailyModel(root)
    server.updates = UpdateManager(server.model)
    server.token = secrets.token_urlsafe(32)
    return server


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).parent.parent)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--port", type=int, default=17861)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--open", action="store_true")
    args = parser.parse_args()
    model = DailyModel(args.root, args.config)
    if args.check:
        model.plans.configuration()
        print("Dashboard configuration ready.")
        raise SystemExit(0)
    with create_server(args.root, args.port, model) as server:
        url = "http://127.0.0.1:" + str(server.server_port)
        print("DailyDesk  " + url, flush=True)
        if args.open:
            webbrowser.open(url)
        server.updates.start_scheduler()
        try:
            server.serve_forever(poll_interval=0.5)
        except KeyboardInterrupt:
            pass
