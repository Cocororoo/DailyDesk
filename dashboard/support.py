"""Shared persistence and launch coordination for the local control panel."""

import ctypes
import datetime as dt
import json
import os
from pathlib import Path
import uuid

def now():
    return dt.datetime.now().astimezone().isoformat()


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return default


def encode_json(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".ui-" + uuid.uuid4().hex + ".tmp")
    try:
        with temp.open("wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


class AppError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


class NativeMutex:
    """Same locks as the unchanged native launcher; no edit/start race."""
    def __enter__(self):
        self.handles = []
        if os.name != "nt":
            return self
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
        kernel.CreateMutexW.restype = ctypes.c_void_p
        kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        kernel.ReleaseMutex.argtypes = [ctypes.c_void_p]
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        self.kernel = kernel
        try:
            for name in ["Local\\ThreeGameDailyWindow", "Local\\ThreeGameDailyAutomation"]:
                handle = kernel.CreateMutexW(None, False, name)
                if not handle:
                    raise AppError("无法取得运行锁，请先关闭每日上班窗口。", 409)
                result = kernel.WaitForSingleObject(handle, 0)
                if result not in (0, 0x80):
                    kernel.CloseHandle(handle)
                    raise AppError("每日上班窗口仍在运行。请先结束任务并关闭窗口，再保存配置。", 409)
                self.handles.append(handle)
        except Exception:
            self.__exit__(None, None, None)
            raise
        return self

    def __exit__(self, *_):
        for handle in reversed(self.handles):
            self.kernel.ReleaseMutex(handle)
            self.kernel.CloseHandle(handle)
