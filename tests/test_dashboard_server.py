"""HTTP routing smoke tests for the split local dashboard modules."""
from http.server import ThreadingHTTPServer
import json
from datetime import datetime
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen


sys.path.insert(0, str(Path(__file__).parents[1] / "dashboard"))
import server as dashboard_server
from support import now


class FakePlans:
    def configuration(self):
        return {"revision": "test-revision", "games": {}}

    def save(self, body):
        return {"ok": True, "saved": body}


class FakeModel:
    def __init__(self):
        import threading

        self.lock = threading.RLock()
        self.plans = FakePlans()

    def status(self):
        return {"busy": False, "active": None, "processes": [], "supervisors": []}

    def histories(self):
        return [{"id": "run-1", "status": "completed"}]

    def run_detail(self, run_id):
        return {"run": {"id": run_id}}

    def launch(self, game):
        return {"ok": True, "game": game}

    def stop(self, run_id):
        return {"ok": True, "runId": run_id}

    def open_record_folder(self, run_id):
        return {"ok": True, "runId": run_id}


class FakeUpdates:
    operation = None

    def status(self):
        return {"operation": None, "games": {}}

    def installing(self):
        return False

    def start(self, action, game):
        return {"action": action, "game": game}

    def set_auto(self, game, enabled):
        return {"game": game, "enabled": enabled}


class DashboardServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.model = FakeModel()
        with patch.object(dashboard_server, "UpdateManager", return_value=FakeUpdates()):
            cls.http = dashboard_server.create_server(Path.cwd(), port=0, model=cls.model)
        cls.thread = threading.Thread(target=cls.http.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.http.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown()
        cls.http.server_close()
        cls.thread.join(timeout=2)

    def get_json(self, path):
        with urlopen(self.base + path, timeout=3) as response:
            return json.load(response)

    def get_bytes(self, path):
        with urlopen(self.base + path, timeout=3) as response:
            return response.status, response.headers.get_content_type(), response.read()

    def post_json(self, path, payload, token=None):
        headers = {"Content-Type": "application/json", "Origin": self.base}
        if token:
            headers["X-Daily-Token"] = token
        request = Request(self.base + path, data=json.dumps(payload).encode(), headers=headers, method="POST")
        try:
            with urlopen(request, timeout=3) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            return error.code, json.load(error)

    def test_split_modules_serve_bootstrap_configuration_status_and_history(self):
        self.assertEqual(datetime.fromisoformat(now()).utcoffset(), datetime.now().astimezone().utcoffset())
        bootstrap = self.get_json("/api/bootstrap")
        self.assertTrue(bootstrap["token"])
        self.assertEqual(bootstrap["configuration"]["revision"], "test-revision")
        self.assertEqual(self.get_json("/api/status")["busy"], False)
        self.assertEqual(self.get_json("/api/config")["revision"], "test-revision")
        self.assertEqual(self.get_json("/api/runs")["runs"][0]["id"], "run-1")
        self.assertEqual(self.get_json("/api/runs/run-1")["run"]["id"], "run-1")
        self.assertEqual(self.get_json("/api/health")["app"], "daily-desk")
        for path, expected_type in (("/", "text/html"), ("/app.js", "text/javascript"),
                                    ("/styles.css", "text/css"), ("/logo.svg", "image/svg+xml"),
                                    ("/March7th.ico", "image/vnd.microsoft.icon")):
            status, content_type, content = self.get_bytes(path)
            self.assertEqual(status, 200)
            self.assertEqual(content_type, expected_type)
            self.assertTrue(content)

    def test_brand_icon_prefers_local_icon_and_falls_back_to_default(self):
        default_icon = (dashboard_server.STATIC / "logo.svg").read_bytes()
        with TemporaryDirectory() as directory, patch.object(dashboard_server, "STATIC", Path(directory)):
            static = Path(directory)
            (static / "logo.svg").write_bytes(default_icon)
            self.assertEqual(self.get_bytes("/brand-icon"), (200, "image/svg+xml", default_icon))
            local_icon = b"local icon fixture"
            (static / "march7th.ico").write_bytes(local_icon)
            self.assertEqual(self.get_bytes("/brand-icon"), (200, "image/vnd.microsoft.icon", local_icon))

    def test_mutation_routes_require_page_token_and_dispatch_to_modules(self):
        payload = {"revision": "test-revision", "games": {}}
        status, _ = self.post_json("/api/config", payload)
        self.assertEqual(status, 403)

        token = self.get_json("/api/bootstrap")["token"]
        status, saved = self.post_json("/api/config", payload, token)
        self.assertEqual(status, 200)
        self.assertEqual(saved["saved"], payload)

        status, launched = self.post_json("/api/launch", {"game": "Genshin"}, token)
        self.assertEqual(status, 202)
        self.assertEqual(launched["game"], "Genshin")


if __name__ == "__main__":
    unittest.main()
