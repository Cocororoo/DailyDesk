"""Read and edit the three native assistants' daily plans."""

import datetime as dt
import hashlib
from pathlib import Path
import re

from results import NAMES as GAMES
from support import AppError, NativeMutex, atomic_write, encode_json, now, read_json

DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
END_TASKS = {
    "VisitFriends": "拜访好友", "GiftOperator": "赠送与收取礼物", "DijiangRewards": "帝江号 / 基建",
    "SellProduct": "据点交易", "AutoStockStaple": "购买稳定物资", "ResourceRecycleStation": "资源回收站",
    "AutoCollect": "特产采集", "AutoStockpile": "自动囤货", "AutoSell": "售卖弹性物资",
    "EnvironmentMonitoring": "环境监测", "AutoEssence": "源质 / 清理智", "CreditShoppingN2": "信用点购物",
    "DailyRewards": "日常与通行证奖励", "CloseGamePC": "关闭游戏",
}
STAR_OPTIONAL = {"reward_dispatch_enable": "收取并重新派遣委托", "reward_mail_enable": "邮件奖励",
                 "reward_assist_enable": "支援收益", "reward_srpass_enable": "无名勋礼"}
GEN_OPTIONAL = {"领取邮件": "邮件奖励", "领取尘歌壶奖励": "尘歌壶宝钱与好感"}


def flow_tasks(flow):
    definitions = flow.get("TaskDefinitions", {})
    return {definitions.get(key, key): bool(enabled) for key, enabled in flow["TaskEnabledList"].items()}


class NativePlans:
    def __init__(self, config, config_path, lock, process_provider, pending_launch):
        self.config = config
        self.config_path = config_path
        self.lock = lock
        self.process_provider = process_provider
        self.pending_launch = pending_launch
        base = self.config_path.parent
        self.data = (base / self.config["DataDirectory"]).resolve()
        self.bgi, self.star, self.end = (
            (base / self.config[game]["Directory"]).resolve() for game in GAMES
        )
        self.profile = self.config["Genshin"]["Profile"]
        if not self.profile.strip() or not re.fullmatch(r"[\w -]+", self.profile):
            raise RuntimeError("Invalid BetterGI profile name.")
        self.native_paths = {
            "gen_flow": self.bgi / "User/OneDragon" / (self.profile + ".json"),
            "gen_config": self.bgi / "User/config.json",
            "star": self.star / "config.yaml",
            "end": self.end / "config/mxu-MaaEnd.json",
        }
        if scripts := self.config["Genshin"].get("LocalScripts"):
            assets = (base / scripts).resolve().parent / "assets"
            self.native_paths.update(gen_template=assets / (self.profile + ".json"),
                                     gen_policy=assets / "ResinDomainPolicy.json")

    def refresh_catalog(self):
        self.catalog = self.load_catalog()

    def load_catalog(self):
        m = read_json(self.bgi / "GameTask/AutoTrackPath/Assets/tp.json")
        kind = {"BlessDomain": "圣遗物", "MasteryDomain": "天赋材料", "ForgeryDomain": "武器材料"}
        domains = {}
        for scene in m["data"]:
            for point in scene.get("points", []):
                if point.get("type") in kind:
                    domains[point["name"]] = {"value": point["name"], "label": point["name"],
                        "group": kind[point["type"]], "region": point.get("country", "")}
        star = read_json(self.star / "assets/config/instance_names.json")
        choices = read_json(self.end / "tasks/AutoEssence/Location/ChooseLocation.json")
        locale = read_json(self.end / "locales/interface/zh_cn.json")
        end = [{"value": c["name"], "label": locale.get(c["label"].lstrip("$"), c["name"])}
               for c in choices["option"]["AutoEssenceChooseLocation"]["cases"]]
        return {"Genshin": sorted(domains.values(), key=lambda d: (d["group"], d["region"], d["label"])),
                "StarRail": {k: [{"value": n, "label": n, "description": v} for n, v in star[k].items() if n != "无"]
                             for k in ("侵蚀隧洞", "饰品提取")}, "Endfield": end}

    def revision(self):
        h = hashlib.sha256()
        for key, path in sorted(self.native_paths.items()):
            h.update(key.encode())
            h.update(path.read_bytes())
        return h.hexdigest()

    @staticmethod
    def yaml_scalar(text, key):
        matches = re.findall(r"^" + re.escape(key) + r":[ \t]*([^\r\n#]*)", text, re.M)
        if len(matches) != 1:
            raise AppError("星铁配置字段不唯一：" + key, 409)
        return matches[0].strip().strip("'\"")

    @staticmethod
    def replace_scalar(text, key, value):
        pattern = r"(^" + re.escape(key) + r":[ \t]*)([^\r\n#]*)([^\r\n]*)"
        def replacement(m):
            return m[1] + value + (" " if m[3] else "") + m[3]
        result, count = re.subn(pattern, replacement, text, flags=re.M)
        if count != 1:
            raise AppError("星铁配置字段不唯一：" + key, 409)
        return result

    def configuration(self):
        with self.lock:
            flow = read_json(self.native_paths.get("gen_template", self.native_paths["gen_flow"]))
            policy = read_json(self.native_paths["gen_policy"]) if "gen_policy" in self.native_paths else None
            text = self.native_paths["star"].read_text(encoding="utf-8-sig")
            category = self.yaml_scalar(text, "instance_type")
            block = re.search(r"^instance_names:[ \t]*\r?\n(.*?)(?=^[^\s#][^\r\n]*:|\Z)", text, re.M | re.S)
            match = re.search(r"^  " + re.escape(category) + r":[ \t]*([^#\r\n]*)", block[1], re.M)
            native = read_json(self.native_paths["end"])
            instance = self.end_instance(native)
            tasks = {t["taskName"]: t for t in instance["tasks"]}
            options = tasks["AutoCollect"]["optionValues"]
            essence = tasks["AutoEssence"]["optionValues"]
            reserve = tasks["AutoStockStaple"]["optionValues"]
            native_domain = flow_tasks(flow).get("自动秘境", False)
            return {"revision": self.revision(), "savedAt": read_json(self.data / "dashboard/last-save.json", {}).get("at"),
                "catalog": self.catalog, "profile": self.profile, "nativeGenshinDomain": native_domain, "games": {
                "Genshin": {"domain": policy["PrimaryDomain"] if policy else flow.get("DomainName") or "",
                    "sunday": str(policy["SundaySelectedValue"] if policy else flow.get("SundaySelectedValue") or "1"),
                    "tasks": {name: any(enabled and flow.get("TaskDefinitions", {}).get(key, key) == name
                                       for key, enabled in flow["TaskEnabledList"].items()) for name in GEN_OPTIONAL}},
                "StarRail": {"type": category, "target": match[1].strip().strip("'\""),
                    "tasks": {name: self.yaml_scalar(text, name) == "true" for name in STAR_OPTIONAL}},
                "Endfield": {"location": essence["AutoEssenceChooseLocation"]["caseNames"][0],
                    "repeat": int(essence["AutoEssenceRepeatCount"]["values"]["AutoEssenceRepeatCountValue"]),
                    "reserve": int(reserve["AutoStockReserveValleyIV"]["values"]["ReserveValleyIV"]),
                    "days": [d for d in DAYS if "AutoCollectSchedule" + d in options["AutoCollectSchedule"]["caseNames"]],
                    "stash": options["AutoCollectStashBackpackSubTask"]["value"],
                    "tasks": {name: bool(tasks[name]["enabled"]) for name in END_TASKS if name in tasks and name != "CloseGamePC"}}},
                "taskLabels": {"Genshin": GEN_OPTIONAL, "StarRail": STAR_OPTIONAL,
                    "Endfield": {k: v for k, v in END_TASKS.items() if k in tasks and k != "CloseGamePC"}},
                "paths": {game: str(path) for game, path in zip(GAMES, [self.bgi, self.star, self.end])}}

    def end_instance(self, config):
        matches = [i for i in config["instances"] if i["name"] == self.config["Endfield"]["Instance"]]
        if len(matches) != 1:
            raise AppError("终末地所选日常实例不存在或重名。", 409)
        return matches[0]

    def validate(self, body):
        if set(body) != {"revision", "games"} or set(body["games"]) != set(GAMES):
            raise AppError("配置结构无效，请刷新页面。")
        g, s, e = (body["games"][k] for k in GAMES)
        current = self.configuration()
        old_genshin = current["games"]["Genshin"]
        domain_changed = any(g.get(key) != old_genshin[key] for key in ("domain", "sunday"))
        if set(g) != {"domain", "sunday", "tasks"} or (domain_changed and (
            not current["nativeGenshinDomain"]
            or g["domain"] not in {d["value"] for d in self.catalog["Genshin"]}
            or g["sunday"] not in ("1", "2", "3")
        )):
            raise AppError("请选择原神原生列表中的秘境与周日材料组。")
        if set(s) != {"type", "target", "tasks"} or s["type"] not in self.catalog["StarRail"] or s["target"] not in {d["value"] for d in self.catalog["StarRail"][s["type"]]}:
            raise AppError("请选择星铁原生列表中的副本。")
        if set(e) != {"location", "repeat", "reserve", "days", "stash", "tasks"} or e["location"] not in {d["value"] for d in self.catalog["Endfield"]}:
            raise AppError("请选择终末地原生列表中的源质地区。")
        if type(e["repeat"]) is not int or not 1 <= e["repeat"] <= 99 or type(e["reserve"]) is not int or not 0 <= e["reserve"] <= 2147483647:
            raise AppError("循环次数须为1–99；调度券保留线须为0–2147483647整数。")
        if not isinstance(e["days"], list) or len(set(e["days"])) != len(e["days"]) or not set(e["days"]) <= set(DAYS) or type(e["stash"]) is not bool:
            raise AppError("采集星期或存仓配置无效。")
        if e["tasks"].get("AutoCollect") and not e["days"]:
            raise AppError("开启特产采集时至少选择一天。")
        for name, game in body["games"].items():
            if set(game["tasks"]) != set(current["games"][name]["tasks"]) or any(type(v) is not bool for v in game["tasks"].values()):
                raise AppError("任务开关无效，请刷新后重试。")
        return current["games"]

    def build_changes(self, body):
        previous = self.validate(body)
        g, s, e = (body["games"][k] for k in GAMES)
        p = self.native_paths
        changes = {}
        old_g = previous["Genshin"]
        if g != old_g:
            for path in [p["gen_flow"]] + ([p["gen_template"]] if "gen_template" in p else []):
                flow = read_json(path)
                if g["domain"] != old_g["domain"]:
                    flow.update(DomainName=g["domain"], WeeklyDomainEnabled=False)
                    if "gen_template" in p:
                        for day in DAYS:
                            flow[day + "DomainName"] = g["domain"]
                if g["sunday"] != old_g["sunday"]:
                    for key in ("SundaySelectedValue", "SundayEverySelectedValue", "SundayWeeklySelectedValue"):
                        flow[key] = g["sunday"]
                for key in flow["TaskEnabledList"]:
                    name = flow.get("TaskDefinitions", {}).get(key, key)
                    if name in g["tasks"] and g["tasks"][name] != old_g["tasks"][name]:
                        flow["TaskEnabledList"][key] = g["tasks"][name]
                changes[path] = encode_json(flow)
            if "gen_policy" in p and any(g[key] != old_g[key] for key in ("domain", "sunday")):
                policy = read_json(p["gen_policy"])
                domain = next(d for d in self.catalog["Genshin"] if d["value"] == g["domain"])
                policy.update(PrimaryDomain=g["domain"], PrimaryRegion=domain["region"],
                              SundaySelectedValue=g["sunday"], SundayMaterial=f"第{g['sunday']}组（按游戏内周日列表顺序）",
                              RequestedAt=now())
                if policy["FallbackDomain"] == g["domain"]:
                    policy["AutomaticFallback"] = False
                    policy["FallbackDomain"] = old_g["domain"]
                changes[p["gen_policy"]] = encode_json(policy)
        text = p["star"].read_text(encoding="utf-8-sig")
        text = self.replace_scalar(text, "instance_type", s["type"])
        block = re.search(r"^instance_names:[ \t]*\r?\n(.*?)(?=^[^\s#][^\r\n]*:|\Z)", text, re.M | re.S)
        new_block, count = re.subn(r"(^  " + re.escape(s["type"]) + r":[ \t]*)([^#\r\n]*)([^\r\n]*)",
            lambda m: m[1] + "'" + s["target"].replace("'", "''") + "'" + (" " if m[3] else "") + m[3], block[1], flags=re.M)
        if count != 1:
            raise AppError("星铁副本配置不唯一。", 409)
        text = text[:block.start(1)] + new_block + text[block.end(1):]
        for key, value in s["tasks"].items():
            text = self.replace_scalar(text, key, str(value).lower())
        if s != previous["StarRail"]:
            changes[p["star"]] = text.encode("utf-8")
        native = read_json(p["end"])
        instance = self.end_instance(native)
        tasks = {t["taskName"]: t for t in instance["tasks"]}
        old_end = previous["Endfield"]
        for key, value in e["tasks"].items():
            if value != old_end["tasks"][key]:
                tasks[key]["enabled"] = value
                tasks[key].setdefault("enabledByController", {})[instance["controllerName"]] = value
        essence = tasks["AutoEssence"]["optionValues"]
        if e["location"] != old_end["location"]:
            essence["AutoEssenceChooseLocation"]["caseNames"] = [e["location"]]
            essence["AutoEssenceMenu"]["caseName"] = "Random"
        if e["repeat"] != old_end["repeat"]:
            essence["AutoEssenceRepeatCount"]["values"]["AutoEssenceRepeatCountValue"] = str(e["repeat"])
        collection = tasks["AutoCollect"]["optionValues"]
        if e["days"] != old_end["days"]:
            collection["AutoCollectSchedule"]["caseNames"] = ["AutoCollectSchedule" + day for day in DAYS if day in e["days"]]
        if e["stash"] != old_end["stash"]:
            collection["AutoCollectStashBackpackSubTask"]["value"] = e["stash"]
        stock = tasks["AutoStockStaple"]["optionValues"]
        if e["reserve"] != old_end["reserve"]:
            for region in ["ValleyIV", "Wuling"]:
                stock["AutoStockReserve" + region]["values"]["Reserve" + region] = str(e["reserve"])
        if e != old_end:
            changes[p["end"]] = encode_json(native)
        return changes

    def save(self, body):
        with self.lock, NativeMutex():
            processes = self.process_provider(force=True)
            if processes["processes"] or self.pending_launch():
                raise AppError("游戏或助手正在运行，请完全退出后再保存配置。", 409)
            if body.get("revision") != self.revision():
                raise AppError("配置已被其他窗口或原生助手修改。请刷新后重新编辑。", 409)
            changes = self.build_changes(body)
            if not changes:
                return {"ok": True, "configuration": self.configuration(), "backup": None}
            before = {p: p.read_bytes() for p in changes}
            backup = self.data / "backups" / ("webui-config-" + dt.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S-%f"))
            backup.mkdir(parents=True)
            manifest = []
            for index, (path, content) in enumerate(before.items()):
                name = str(index) + "-" + path.name
                atomic_write(backup / name, content)
                manifest.append({"path": str(path), "backup": name, "sha256": hashlib.sha256(content).hexdigest()})
            atomic_write(backup / "manifest.json", encode_json({"at": now(), "files": manifest}))
            written = []
            try:
                for path, content in changes.items():
                    if content == before[path]:
                        continue
                    if path.read_bytes() != before[path]:
                        raise AppError("保存期间配置被其他程序修改，已中止。", 409)
                    atomic_write(path, content)
                    written.append(path)
                after = self.configuration()
                if after["games"] != body["games"]:
                    raise RuntimeError("Native configuration read-back mismatch")
            except Exception:
                preserved = []
                for path in reversed(written):
                    if path.read_bytes() == changes[path]:
                        atomic_write(path, before[path])
                    else:
                        preserved.append(str(path))
                if preserved:
                    atomic_write(backup / "external-changes-preserved.json", encode_json({"paths": preserved, "at": now()}))
                raise
            receipt = {"at": now(), "backup": str(backup), "revision": after["revision"], "games": body["games"],
                       "note": "Native configurations saved and read back."}
            atomic_write(self.data / "dashboard/last-save.json", encode_json(receipt))
            atomic_write(backup / "save-receipt.json", encode_json(receipt))
            return {"ok": True, "configuration": self.configuration(), "backup": str(backup)}
