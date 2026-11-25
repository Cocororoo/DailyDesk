"""Stable upstream releases for the three installed Windows assistants."""
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timedelta
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
import shutil
import stat
import subprocess
import threading
import traceback
from urllib.request import Request, urlopen
import uuid

from support import AppError, NativeMutex, atomic_write, encode_json, now, read_json

POWERSHELL = Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe"
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


@dataclass(frozen=True)
class Assistant:
    repo: str
    executable: str
    asset: str
    preserve: tuple[str, ...]
    overlay: bool = False


ASSISTANTS = {
    "Genshin": Assistant("babalae/better-genshin-impact", "BetterGI.exe", r"BetterGI_v[\d.]+\.7z",
                         ("User", "Cache", "log")),
    "StarRail": Assistant("moesnow/March7thAssistant", "m7a.exe", r"update\.7z",
                          ("config.yaml", "config.yaml.bak", "settings", "config", "logs", "characters.json"), True),
    "Endfield": Assistant("MaaEnd/MaaEnd", "MaaEnd.exe", r"MaaEnd-win-x86_64-v[\d.]+\.zip",
                          ("config", "cache", "debug")),
}


def version_key(version):
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?", version, re.I)
    if not match:
        raise ValueError("Unsupported version format")
    return tuple(int(part or 0) for part in match.groups())


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_version(game, root):
    if game == "Endfield":
        return read_json(root / "interface.json")["version"]
    if game == "StarRail":
        return (root / "assets/config/version.txt").read_text(encoding="utf-8-sig").strip()
    command = "(Get-Item -LiteralPath $env:DAILY_UPDATE_EXE).VersionInfo.ProductVersion"
    result = subprocess.run([str(POWERSHELL), "-NoProfile", "-NonInteractive", "-Command", command],
                            env={**os.environ, "DAILY_UPDATE_EXE": str(root / "BetterGI.exe")},
                            capture_output=True, text=True, check=True, timeout=15, creationflags=NO_WINDOW)
    return result.stdout.strip().split("+", 1)[0]


def latest_release(assistant):
    url = f"https://api.github.com/repos/{assistant.repo}/releases/latest"
    request = Request(url, headers={"User-Agent": "DailyDesk/1.0", "Accept": "application/vnd.github+json"})
    with urlopen(request, timeout=20) as response:
        release = json.load(response)
    tag = release["tag_name"]
    version_key(tag)
    if release.get("prerelease") or release.get("draft"):
        raise AppError("未找到正式版。")
    for asset in release["assets"]:
        if not re.fullmatch(assistant.asset, asset["name"]):
            continue
        if assistant.executable != "m7a.exe" and f"v{tag.lstrip('v')}." not in asset["name"]:
            continue
        digest = str(asset.get("digest") or "")
        download = f"https://github.com/{assistant.repo}/releases/download/{tag}/{asset['name']}"
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest) or asset["browser_download_url"] != download:
            raise AppError("官方安装包缺少可验证的 SHA-256。")
        return tag, asset["name"], download, digest[7:], int(asset["size"])
    raise AppError("没有适合本机的正式版更新包。")


def download_release(release, directory):
    tag, name, url, digest, size = release
    target = directory / tag / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_file() and target.stat().st_size == size:
        if sha256_file(target) == digest:
            return target
    partial = target.with_suffix(target.suffix + ".part")
    sha = hashlib.sha256()
    received = 0
    try:
        request = Request(url, headers={"User-Agent": "DailyDesk/1.0"})
        deadline = datetime.now() + timedelta(minutes=25)
        with urlopen(request, timeout=40) as response, partial.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                received += len(chunk)
                if received > size or datetime.now() > deadline:
                    raise AppError("下载大小异常或超时。")
                sha.update(chunk)
                output.write(chunk)
        if received != size or sha.hexdigest() != digest:
            raise AppError("下载包校验失败。")
        partial.replace(target)
        return target
    finally:
        partial.unlink(missing_ok=True)


def extract_release(archive, destination, seven_zip=None):
    seven_zip = seven_zip or shutil.which("7z")
    if not seven_zip or not Path(seven_zip).is_file():
        raise AppError("本机找不到 7-Zip。")
    listed = subprocess.run([seven_zip, "l", "-slt", "-ba", "-sccUTF-8", str(archive)],
                            capture_output=True, encoding="utf-8", errors="replace", check=True,
                            timeout=120, creationflags=NO_WINDOW)
    for line in listed.stdout.splitlines():
        if line.startswith("Path = "):
            path = PureWindowsPath(line[7:])
            if path.anchor or ".." in path.parts or any(":" in part for part in path.parts):
                raise AppError("安装包包含异常路径。")
        elif line.startswith(("Symbolic Link = ", "Hard Link = ")):
            raise AppError("安装包包含链接文件。")
    subprocess.run([seven_zip, "x", "-y", f"-o{destination}", str(archive)], capture_output=True,
                   timeout=360, check=True, creationflags=NO_WINDOW)
    for item in destination.rglob("*"):
        if getattr(item.lstat(), "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            raise AppError("解压结果包含链接文件。")


def copy_item(source, target):
    if source.is_dir():
        shutil.copytree(source, target, dirs_exist_ok=True)
    elif source.is_file():
        shutil.copy2(source, target)


def installed_paths(model):
    return {"Genshin": model.plans.bgi, "StarRail": model.plans.star, "Endfield": model.plans.end}


def _strip_jsonc_comments(text):
    output = []
    in_string = False
    escaped = False
    index = 0

    while index < len(text):
        character = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""

        if in_string:
            output.append(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            index += 1
            continue

        if character == '"':
            in_string = True
            output.append(character)
            index += 1
            continue

        if character == "/" and following == "/":
            index += 2
            while index < len(text) and text[index] not in "\r\n":
                index += 1
            continue

        if character == "/" and following == "*":
            index += 2
            while index < len(text) and not text.startswith("*/", index):
                if text[index] in "\r\n":
                    output.append(text[index])
                index += 1
            if index == len(text):
                raise ValueError("Unterminated JSONC block comment")
            index += 2
            continue

        output.append(character)
        index += 1

    without_comments = "".join(output)
    output = []
    in_string = False
    escaped = False
    index = 0

    while index < len(without_comments):
        character = without_comments[index]

        if in_string:
            output.append(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            index += 1
            continue

        if character == '"':
            in_string = True
            output.append(character)
            index += 1
            continue

        if character == ",":
            lookahead = index + 1
            while lookahead < len(without_comments) and without_comments[lookahead].isspace():
                lookahead += 1
            if lookahead < len(without_comments) and without_comments[lookahead] in "]}":
                index += 1
                continue

        output.append(character)
        index += 1

    return "".join(output)


def _read_maa_json(path):
    text = Path(path).read_text(encoding="utf-8-sig")
    return json.loads(_strip_jsonc_comments(text))


def maa_schema(installation):
    tasks = set()
    options = set()
    for path in (installation / "tasks").rglob("*.json"):
        definition = _read_maa_json(path)
        if not isinstance(definition, dict):
            continue
        entries = definition.get("task")
        if isinstance(entries, list):
            tasks.update(entry["name"] for entry in entries if isinstance(entry, dict) and "name" in entry)
        declared = definition.get("option")
        if isinstance(declared, dict):
            options.update(declared)
    interface = read_json(installation / "interface.json")
    tasks.update(entry["name"] for entry in interface.get("task", []) if isinstance(entry, dict) and "name" in entry)
    return tasks, options


def check_maa_upgrade(live, staging, instance):
    old_tasks, old_options = maa_schema(live)
    new_tasks, new_options = maa_schema(staging)
    removed = []
    for task in instance["tasks"]:
        if not task.get("enabled", True):
            continue
        name = task["taskName"]
        if name in old_tasks - new_tasks or task["optionValues"].keys() & (old_options - new_options):
            removed.append(name)
    if removed:
        raise AppError("新版改动了已保存的原生任务选项，已保留旧版。")


def recover_installation(data, paths):
    journal = data / "dashboard/update-install.json"
    record = read_json(journal)
    if not record:
        return
    live = paths[record["game"]].resolve()
    previous = Path(record["backup"]).resolve()
    if (previous.parent.parent != live.parent / "backups" or previous.name != live.name
            or not previous.parent.name.startswith("software-update-") or previous.parent.parent.name != "backups"):
        raise RuntimeError("Update recovery path is invalid")
    with NativeMutex():
        if previous.exists():
            if live.exists():
                live.rename(previous.parent / "interrupted")
            previous.rename(live)
        journal.unlink()


class UpdateManager:
    def __init__(self, model):
        self.model = model
        self.paths = installed_paths(model)
        self.data = model.data / "dashboard"
        self.settings_file = self.data / "update-settings.json"
        self.results_file = self.data / "update-results.json"
        self.journal = self.data / "update-install.json"
        self.auto = read_json(self.settings_file, {})
        self.results = read_json(self.results_file, {})
        self.versions = {}
        self.lock = threading.RLock()
        self.operation = None

    def installed(self, game):
        root = self.paths[game]
        marker = {"Genshin": "BetterGI.exe", "StarRail": "assets/config/version.txt",
                  "Endfield": "interface.json"}[game]
        try:
            stamp = (root / marker).stat().st_mtime_ns
            cached = self.versions.get(game)
            if not cached or cached[0] != stamp:
                self.versions[game] = (stamp, read_version(game, root))
            return self.versions[game][1]
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            return None

    def status(self):
        with self.lock:
            return {
                "operation": self.operation,
                "games": {game: {
                    "installed": self.installed(game),
                    "auto": bool(self.auto.get(game)),
                    "releaseUrl": f"https://github.com/{assistant.repo}/releases/latest",
                    **self.results.get(game, {}),
                } for game, assistant in ASSISTANTS.items()},
            }

    def installing(self):
        with self.lock:
            return bool(self.operation and self.operation["action"] == "install")

    def set_auto(self, game, enabled):
        if game not in ASSISTANTS or type(enabled) is not bool:
            raise AppError("自动更新设置无效。")
        with self.lock:
            settings = {**self.auto, game: enabled}
            atomic_write(self.settings_file, encode_json(settings))
            self.auto = settings
            if enabled:
                self.results.setdefault(game, {}).pop("attemptedAt", None)
        return self.status()

    def start(self, action, game):
        if action not in ("check", "install") or game not in (*ASSISTANTS, "All"):
            raise AppError("更新请求无效。")
        games = list(ASSISTANTS) if game == "All" else [game]
        self.start_job(action, games)
        return {"ok": True}

    def start_job(self, action, games):
        with self.model.lock, self.lock:
            if self.operation:
                raise AppError("已有更新操作正在执行。", 409)
            if action == "install":
                self.ensure_idle()
            self.operation = {"action": action, "games": games, "game": None, "phase": "checking"}
            threading.Thread(target=self.run, args=(action, games), daemon=True).start()

    def ensure_idle(self):
        services = self.model.processes(force=True)
        if services["processes"] or services["supervisors"] or self.model.launch_pending():
            raise AppError("请先退出游戏、助手和每日上班窗口。", 409)
        command = "if (Get-Process -Name 'BetterGI.update','March7th Launcher','March7th Updater' -ErrorAction SilentlyContinue) {exit 1}"
        result = subprocess.run([str(POWERSHELL), "-NoProfile", "-NonInteractive", "-Command", command],
                                timeout=12, creationflags=NO_WINDOW)
        if result.returncode:
            raise AppError("请先退出原生启动器和更新器。", 409)

    def phase(self, game, phase):
        with self.lock:
            self.operation.update(game=game, phase=phase)

    def record(self, game, current, **fields):
        with self.lock:
            record = {**self.results.get(game, {}), **fields, "checkedAt": now()}
            if current == "install":
                record["attemptedAt"] = now()
            self.results[game] = record
            atomic_write(self.results_file, encode_json(self.results))

    def run(self, action, games):
        try:
            if action == "check":
                with ThreadPoolExecutor(max_workers=3) as pool:
                    list(pool.map(lambda game: self.process(game, action), games))
            else:
                with NativeMutex():
                    self.ensure_idle()
                    for game in games:
                        self.process(game, action)
        except Exception as exc:
            for game in games:
                self.record(game, action, state="failed",
                            message=str(exc) if isinstance(exc, AppError) else "更新任务未能启动。")
            if not isinstance(exc, AppError):
                traceback.print_exc()
        finally:
            with self.lock:
                self.operation = None

    def process(self, game, action):
        fields = {"state": "failed", "message": "", "latest": None}
        try:
            self.phase(game, "checking")
            root = self.paths[game]
            installed = self.installed(game)
            if not installed:
                raise AppError("无法读取当前版本。")
            release = latest_release(ASSISTANTS[game])
            fields["latest"] = release[0]
            if version_key(installed) >= version_key(release[0]):
                fields["state"] = "current"
            elif action == "check":
                fields["state"] = "available"
            else:
                self.install(game, root, release)
                fields["state"] = "updated"
        except AppError as exc:
            fields["message"] = str(exc)
        except Exception:
            traceback.print_exc()
            fields["message"] = "更新操作失败，请查看控制台服务日志。"
        self.record(game, action, **fields)

    def install(self, game, live, release):
        assistant = ASSISTANTS[game]
        home = live.parent
        work = home / "backups" / f"software-update-{uuid.uuid4().hex[:12]}"
        unpacked = work / "unpacked"
        staging = work / "staged"
        backup = work / live.name
        self.phase(game, "downloading")
        archive = download_release(release, home / "downloads/software-updates")
        work.mkdir(parents=True)
        self.phase(game, "extracting")
        configured = self.model.config.get("SevenZip")
        seven_zip = (self.model.config_path.parent / configured).resolve() if configured else None
        extract_release(archive, unpacked, seven_zip)
        candidates = [p.parent for p in unpacked.rglob(assistant.executable)
                      if p.relative_to(unpacked).parts in ((assistant.executable,), (p.parent.name, assistant.executable))]
        if len(candidates) != 1:
            raise AppError("无法识别官方安装包目录。")
        payload = candidates[0]
        if assistant.overlay:
            shutil.copytree(live, staging)
            protected = {name.casefold() for name in assistant.preserve}
            for item in payload.iterdir():
                if item.name.casefold() not in protected:
                    copy_item(item, staging / item.name)
        else:
            payload.rename(staging)
            for name in assistant.preserve:
                copy_item(live / name, staging / name)
        if version_key(read_version(game, staging)) != version_key(release[0]):
            raise AppError("安装包版本与官方发布版本不一致。")
        if game == "Endfield":
            native = read_json(live / "config/mxu-MaaEnd.json")
            check_maa_upgrade(live, staging, self.model.plans.end_instance(native))
        self.phase(game, "installing")
        self.ensure_idle()
        with self.model.lock:
            atomic_write(self.journal, encode_json({"game": game, "backup": str(backup)}))
            try:
                live.rename(backup)
                staging.rename(live)
                self.validate(game)
                self.model.plans.refresh_catalog()
            except Exception:
                if backup.exists():
                    if live.exists():
                        live.rename(work / "rejected")
                    backup.rename(live)
                self.journal.unlink()
                raise
            self.journal.unlink()
            self.versions.pop(game, None)
        print(now(), game, "updated to", release[0], "backup:", backup, flush=True)

    def validate(self, game):
        # Run the same no-launch compatibility check as the existing one-click entry.
        worker = self.model.root / "runner/Start-GameDailySuite.ps1"
        result = subprocess.run([str(POWERSHELL), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                 "-File", str(worker), "-ConfigPath", str(self.model.config_path),
                                 "-Game", game, "-PreflightOnly"],
                                capture_output=True, timeout=90, creationflags=NO_WINDOW)
        if result.returncode:
            raise AppError("新版未通过日常配置检查，已恢复旧版。")

    def automatic(self):
        with self.lock:
            boundary = datetime.fromisoformat(now()) - timedelta(hours=24)
            due = [game for game in ASSISTANTS if self.auto.get(game) and
                   (not (at := self.results.get(game, {}).get("attemptedAt")) or datetime.fromisoformat(at) < boundary)]
        if due:
            try:
                self.start_job("install", due)
            except AppError:
                pass

    def start_scheduler(self):
        def loop():
            pause = threading.Event()
            while not pause.wait(60):
                try:
                    self.automatic()
                except Exception:
                    traceback.print_exc()
        threading.Thread(target=loop, daemon=True).start()
