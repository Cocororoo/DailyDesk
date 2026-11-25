"""Local daily dashboard. Native configurations remain the source of truth."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import uuid
from plans import NativePlans
from results import NAMES as GAMES, build_display, compact_display
from support import AppError, NativeMutex, atomic_write, encode_json, now, read_json


class DailyModel:
    def __init__(self, suite_root, config_path=None, process_provider=None, launcher=None):
        self.root = Path(suite_root).resolve()
        self.config_path = Path(config_path or self.root / "config.local.json").resolve()
        self.config = read_json(self.config_path)
        if not self.config or self.config.get("SchemaVersion") != 1:
            raise RuntimeError("Run Setup.ps1 to create config.local.json.")
        self.lock = threading.RLock()
        self.status_lock = threading.Lock()
        self.process_provider = process_provider
        self.launcher = launcher
        self.launch_process = None
        self.pending = None
        self.cache = (0, None)
        self.data = (self.config_path.parent / self.config["DataDirectory"]).resolve()
        self.plans = NativePlans(self.config, self.config_path, self.lock, self.processes, self.launch_pending)
        from updates import installed_paths, recover_installation
        recover_installation(self.data, installed_paths(self))
        self.plans.refresh_catalog()

    def bridge(self, action, game="All"):
        exe = str(Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe")
        args = [exe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(self.root / "dashboard/Bridge.ps1"),
                "-Action", action, "-ConfigPath", str(self.config_path), "-Game", game]
        return args

    def processes(self, force=False):
        with self.status_lock:
            if self.process_provider:
                return self.process_provider()
            if not force and time.monotonic() - self.cache[0] < 3:
                return self.cache[1]
            result = subprocess.run(self.bridge("Status"), capture_output=True, timeout=15,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            if result.returncode:
                raise AppError("无法读取本机运行状态，请稍后重试。", 503)
            data = json.loads(result.stdout.decode("utf-8-sig"))
            self.cache = (time.monotonic(), data)
            return data

    def launch_pending(self):
        if self.pending and self.launch_process and self.launch_process.poll() is None:
            return self.pending
        return None

    def launch(self, game):
        if game not in (*GAMES, "All"):
            raise AppError("未知的游戏入口。")
        with self.lock, NativeMutex():
            data = self.processes(force=True)
            if data["processes"] or data["supervisors"] or self.launch_pending():
                raise AppError("已有游戏、助手或每日上班窗口打开。请先关闭，避免重复执行。", 409)
            request = {"id": uuid.uuid4().hex, "game": game, "at": now()}
            directory = self.data / "dashboard/launches" / request["id"]
            directory.mkdir(parents=True)
            log = (directory / "dispatch.log").open("wb")
            try:
                launch = self.launcher or (lambda args, log: subprocess.Popen(args, stdout=log, stderr=log,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)))
                self.launch_process = launch(self.bridge("Launch", game), log)
            finally:
                log.close()
            request["pid"] = self.launch_process.pid
            self.pending = request
            atomic_write(directory / "request.json", encode_json(request))
            return {"ok": True, "request": request}

    def histories(self):
        items = []
        for directory in sorted((self.data / "history").glob("*"), reverse=True):
            if not directory.is_dir() or not re.fullmatch(r"[\w-]+", directory.name):
                continue
            try:
                settings = read_json(directory / "supervisor.json", {})
                report = read_json(directory / "report.json", {})
                pointer = directory / "suite-run.txt"
                suite_path = Path(pointer.read_text(encoding="utf-8-sig").strip()) if pointer.exists() else None
                suite = read_json(suite_path / "suite-result.json", {}) if suite_path else {}
                status = suite.get("Status", "preparing")
                if report.get("Cancelled"):
                    status = "cancelled"
                sequence = suite.get("Sequence") or (self.config["Sequence"] if settings.get("Game") == "All" else [settings.get("Game")])
                if isinstance(sequence, str):
                    sequence = [sequence]
                games = [g for g in sequence if g in GAMES]
                error = suite.get("Error") or report.get("WorkerError")
                finished_at = suite.get("FinishedAt") or report.get("FinishedAt")
                if status == "preparing" and not suite and error:
                    status = "startup_failed"
                    finalized = read_json(directory / "finalize-receipt.json", {})
                    finished_at = finished_at or finalized.get("At") or report.get("GeneratedAt")
                stages = suite.get("Stages", [])
                for stage in stages:
                    if not finished_at or stage.get("Game") != "Endfield" or not stage.get("EvidenceDirectory") or stage.get("NativeCompleted"):
                        continue
                    evidence = Path(stage["EvidenceDirectory"]).resolve()
                    if evidence.is_relative_to((self.data / "Endfield").resolve()):
                        try:
                            stop = read_json(evidence / "configuration-guard-stop.json", {})
                        except (ValueError, OSError):
                            continue
                        if stop.get("reason"):
                            stage["ConfigurationGuardReason"] = stop["reason"]
                display = build_display(report, stages, status, games, finished_at)
                items.append({"id": directory.name, "startedAt": settings.get("StartedAt") or report.get("StartedAt"),
                    "finishedAt": finished_at, "status": status, "gameDay": settings.get("GameDay"),
                    "summary": display["summary"], "display": compact_display(display), "games": games,
                    "stages": stages, "error": error,
                    "reportAvailable": bool(report), "source": settings.get("RecordSource")})
            except (ValueError, OSError, TypeError):
                items.append({"id": directory.name, "status": "unreadable", "summary": "记录暂时无法读取", "games": [], "stages": []})
        return items

    def run_detail(self, run_id):
        directory = self.run_directory(run_id)
        report = read_json(directory / "report.json", {})
        item = next((i for i in self.histories() if i["id"] == run_id), None)
        if item is None:
            raise AppError("记录不存在。", 404)
        display = build_display(report, item["stages"], item["status"], item["games"], item.get("finishedAt"))
        return {"run": item, "report": report, "display": display, "log": self.log_tail(run_id)}

    def run_directory(self, run_id):
        if not re.fullmatch(r"[\w-]+", run_id):
            raise AppError("记录编号无效。", 404)
        directory = self.data / "history" / run_id
        if not directory.is_dir():
            raise AppError("记录不存在。", 404)
        return directory

    def log_tail(self, run_id):
        directory = self.run_directory(run_id)
        choices = []
        pointer = directory / "suite-run.txt"
        if pointer.exists():
            run = Path(pointer.read_text(encoding="utf-8-sig").strip())
            suite = read_json(run / "suite-result.json", {})
            for stage in reversed(suite.get("Stages", [])):
                game = stage.get("Game")
                evidence = Path(stage["EvidenceDirectory"]) if stage.get("EvidenceDirectory") else None
                if evidence:
                    if game == "Genshin":
                        session = read_json(evidence / "session.json", {})
                        if session.get("RunDirectory"):
                            choices.append((Path(session["RunDirectory"]) / "run.log", game))
                    elif game == "StarRail":
                        choices += [(evidence / "native-run.log", game), (evidence / "console.log", game)]
                    elif game == "Endfield":
                        choices.append((evidence / "evidence/go-service.log.delta.log", game))
                choices.append((run / (str(game) + ".log"), game))
        choices += [(directory / name, None) for name in ("entry.log", "supervisor.log", "worker-error.txt")]
        for path, game in choices:
            if path.is_file():
                with path.open("rb") as stream:
                    offset = max(0, path.stat().st_size - 20000)
                    stream.seek(offset - offset % 2)
                    data = stream.read()
                if data.startswith((b"\xff\xfe", b"\xfe\xff")) or b"\x00" in data[:100]:
                    text = data.decode("utf-16", errors="replace")
                else:
                    text = data.decode("utf-8-sig", errors="replace")
                lines = text.splitlines()
                if offset:
                    lines = lines[1:]
                lines = lines[-90:]
                if game == "Endfield":
                    formatted = []
                    for line in lines:
                        try:
                            event = json.loads(line)
                        except ValueError:
                            event = None
                        if isinstance(event, dict):
                            line = " ".join(str(event.get(k, "")) for k in ("time", "level", "task", "message")).strip() or line
                        formatted.append(line)
                    lines = formatted
                return "[" + (GAMES.get(game, "总调度")) + " · " + path.name + "]\n" + "\n".join(lines)
        return "本轮尚无日志。"

    def status(self):
        native = self.processes()
        histories = self.histories()
        active = None
        for supervisor in native["supervisors"]:
            item = next((h for h in histories if h["id"] == supervisor["runId"]), None)
            if item:
                active = {**item, "windowOpen": True}
                break
        pending = self.launch_pending()
        failure = None
        if self.pending and not pending and not any(h.get("startedAt", "") > self.pending["at"] for h in histories):
            failure = "启动未完成，可能已取消系统权限提示。请检查后重新启动。"
        return {"at": now(), "gameDay": native.get("gameDay"), "active": active, "pending": pending, "launchError": failure,
                "processes": native["processes"], "busy": bool(active or pending or native["processes"]),
                "latest": histories[:1], "root": str(self.root)}

    def stop(self, run_id):
        with self.lock:
            directory = self.run_directory(run_id)
            native = self.processes(force=True)
            if not any(s["runId"] == run_id for s in native["supervisors"]):
                raise AppError("该轮没有正在运行的监督窗口。", 409)
            atomic_write(directory / "ui-close-request.json", encode_json({"at": now(), "reason": "webui_stop"}))
            return {"ok": True, "message": "正在停止本轮任务并关闭相关进程。"}

    def evidence(self, run_id, value):
        # Only paths that this report explicitly references, within automation roots.
        detail = self.run_detail(run_id)
        paths = {t.get("Evidence") for t in detail["report"].get("Tasks", [])}
        paths.update(g.get("Evidence") for g in detail["report"].get("Games", []))
        if value not in paths:
            raise AppError("该路径不是本轮已记录的证据。", 403)
        path = Path(value).resolve()
        if not any(path.is_relative_to(root.resolve()) for root in [self.data]):
            raise AppError("证据路径超出自动化目录。", 403)
        if not path.is_file() or path.suffix.lower() not in (".json", ".log", ".txt", ".md", ".png", ".jpg"):
            raise AppError("该证据为目录，请在原始报告中查看路径。", 404)
        if path.stat().st_size > 15_000_000:
            raise AppError("证据文件较大，请通过原始报告在本机打开。", 413)
        return path

    def open_record_folder(self, run_id):
        directory = self.run_directory(run_id)
        os.startfile(str(directory))
        return {"ok": True}
