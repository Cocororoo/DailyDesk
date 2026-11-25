"""Concise, read-only result presentation. Original evidence is never rewritten."""
import json
import re

NAMES = {"Genshin": "原神", "StarRail": "星穹铁道", "Endfield": "终末地"}
LABELS = {"completed": "已完成", "executed": "已执行", "skipped": "已跳过",
          "failed": "失败", "incomplete": "未完成", "missing": "记录缺失",
          "cancelled": "已中止", "running": "运行中", "not_run": "未执行"}
KINDS = {"completed": "success", "executed": "", "skipped": "", "failed": "failed",
         "incomplete": "warning", "missing": "warning", "cancelled": "failed", "running": "running"}
ATTENTION = {"failed", "incomplete", "missing"}
NOTES = {"委托页截图／OCR", "秘境掉落物品", "资源与奖励实际收益", "理智最终余量", "日志异常／提示"}
TITLES = {"秘境／清树脂": "清树脂", "遗器清体力": "体力副本", "每日实训500与领奖": "每日实训奖励",
          "刷本队伍／还原原队": "切队与还原",
          "退出／恢复显示设置": "退出与恢复分辨率",
          "特产采集／存仓": "特产采集与存仓", "源质／基质清理智": "源质清理智",
          "日常／邮件／活动／通行证领奖": "日常与通行证奖励"}


def find(pattern, text, default=""):
    match = re.search(pattern, text)
    return match.group(1) if match else default


def startup_failure_details(error):
    prefix = "Daily preflight failed: "
    if not error.startswith(prefix):
        return []
    try:
        checks = json.loads(error.removeprefix(prefix)).get("Checks", [])
    except (ValueError, AttributeError):
        return []
    if not isinstance(checks, list):
        return []
    return [check for check in checks if isinstance(check, dict) and check.get("Ready") is False]


def configuration_failure_reason(reason):
    if "Daily plan drift: CreditShoppingN2.optionValues." in reason:
        return "信用购物配置与原生计划不一致"
    if "Daily plan drift:" in reason:
        return "原生配置与保存的计划不一致"
    return "启动检查未通过"


def task_display(row):
    name, status, detail = (str(row.get(k) or "") for k in ("Task", "Status", "Detail"))
    state, text = "missing", "没有完成记录"
    label = None
    if "失败" in status or status == "空间不足；领奖被阻止":
        state, text = "failed", "任务执行失败"
    elif status in ("前置未满足", "可领但未领取"):
        state, text = "incomplete", "奖励未领取"
    elif status == "未执行":
        state, text = "not_run", "本轮未执行"
    elif "中断" in status or "中止" in status:
        state, text = "cancelled", "任务已中止"
    elif "运行中" in status:
        state, text = "running", "正在执行"
    elif "跳过" in status:
        state, text = "skipped", "按计划跳过" if "计划" in status else "原生任务跳过"
    elif any(v in status for v in ("日志支持已领取", "日志支持完成", "原生成功", "已核验", "恢复后继续通关")):
        state, text = "completed", "任务完成"
    elif status.startswith("挑战已完成"):
        state, text = "completed", "挑战完成"
    elif "本轮无可领奖励" in status:
        state, text, label = "skipped", "活跃度已满", "无可领取"
    elif "已观测500" in status:
        state, text = "incomplete", "实训已达标，缺少领奖记录"
    elif "有操作记录" in status:
        # Only an action was observed; do not turn it into a confirmed reward receipt.
        state, text = "executed", "已执行领取操作"
        if re.search(r"未检测到.*奖励|无需领取|没有可领取|无可领取", detail):
            state, text, label = "skipped", "本轮无可领取内容", "无可领取"
        elif "未探索完成或已领取" in detail:
            state, text, label = "skipped", "派遣未到期或已领取", "无需操作"
        elif "再次派遣" in detail or "重新派遣" in detail:
            text = "已执行收取与再派遣"

    title = TITLES.get(name, name)
    if name == "秘境／清树脂" and state == "completed":
        domain = find(r"目标：([^；]+)", detail)
        rounds = find(r"挑战完成 (\d+) 次", detail)
        resin = find(r"最终原粹 (\d+)", detail)
        text = " · ".join(v for v in (domain, f"{rounds} 次" if rounds else "", f"剩余树脂 {resin}" if resin else "") if v)
    elif name == "遗器清体力" and state == "completed":
        target = find(r"目标：([^；]+)", detail)
        settled = find(r"结算 (\d+) 次", detail)
        batches = find(r"完成 (\d+) 批", detail)
        challenges = find(r"每批 (\d+) 次", detail)
        count = f"结算 {settled} 次" if settled else f"{batches} 批 × {challenges} 次" if batches and challenges else f"{batches} 批" if batches else "挑战完成"
        text = " · ".join(v for v in (target, count, "体力不足以继续" if "开拓力不足以继续" in detail else "") if v)
    elif name == "每日委托奖励":
        if state == "completed":
            label, text = "已领取", "每日奖励已领取"
        elif state == "incomplete":
            done = find(r"委托 (\d+)/4", detail)
            short = find(r"树脂缺口 (\d+)", detail)
            text = (f"委托 {done}/4" if done else "奖励未领取") + (f"，还差 {short} 树脂消耗" if short and short != "0" else "，可领取" if status == "可领但未领取" else "")
    elif name == "每日实训500与领奖" and state == "completed":
        label, text = "已领取", "实训达标，奖励已领取"
    elif name == "刷本队伍／还原原队" and state == "completed":
        slot = find(r"原第(\d+)队", detail)
        text = f"已还原第 {slot} 队" if slot else "刷本后已还原原队"
    elif name == "退出／恢复显示设置" and state == "completed":
        text = "已退出，显示设置已处理"
    elif name == "退出游戏" and state == "completed":
        text = "游戏已关闭"
    elif name == "进入大世界" and state == "failed":
        text = "启动界面识别超时"
    elif name == "圣遗物背包" and state == "failed":
        text = "圣遗物背包已满，秘境奖励无法结算"
    elif name == "特产采集／存仓":
        if state == "failed":
            if re.search(r"\bAutoCollectWulingTalosCap1Start\b", detail):
                text = "进入雪松林失败（塔罗斯菌）"
            else:
                text = "武陵采集路线失败" if "AutoCollectWuling" in detail else "采集路线失败"
        elif state == "skipped":
            text = "今日不在采集计划内" if "计划" in status else text
    elif name == "角色倒下后恢复" and state == "completed":
        text = "已复活并继续通关"
    elif name == "体力副本回退" and "已使用授权备用" in status:
        state, text = "completed", "已切换备用副本"
    return {"title": title, "state": state, "label": label or LABELS[state], "kind": KINDS.get(state, ""),
            "summary": text, "raw": row}


def build_display(report, stages, raw_status, games, finished_at):
    """Native task success means task completion, never an exact inventory audit."""
    tasks = report.get("Tasks") or []
    result_games, alerts = [], []
    startup_failures = startup_failure_details(report.get("WorkerError") or "") if raw_status == "startup_failed" else []
    startup_reasons = {check.get("Game"): str(check.get("Reason") or "") for check in startup_failures}
    for game in games:
        name = NAMES[game]
        stage = next((s for s in reversed(stages) if s.get("Game") == game), {})
        game_tasks = [task_display(t) for t in tasks if t.get("Game") == name and t.get("Task") not in NOTES]
        notes = [t for t in tasks if t.get("Game") == name and t.get("Task") in NOTES]
        # Known OCR limitations and duplicated commission failures are technical notes.
        # Unrecognized warnings remain visible as a concrete exception.
        for note in notes:
            if note.get("Task") != "日志异常／提示":
                continue
            parts = [p for p in str(note.get("Detail") or "").split('；') if p]
            unknown = [p for p in parts if not re.search(r"奖励结果页.*跳过本轮奖励识别|一条龙结束汇总|原粹树脂 \d+/\d+|每日委托奖励：|Commission verification:|completed=|resinConsumed=|resinShortfall=", p)]
            if unknown:
                game_tasks.append({"title": "运行异常", "state": "incomplete", "label": "异常", "kind": "warning",
                                   "summary": "；".join(dict.fromkeys(unknown))[:140], "raw": note})
        problems = [t for t in game_tasks if t["state"] in ATTENTION]
        native_ok = bool(stage.get("NativeCompleted")) or (
            game == "StarRail" and any(
                s.get("Game") == name and s.get("Status") == "复核：清体力与实训奖励已完成"
                for s in (report.get("Games") or [])
            )
        )
        stage_status = stage.get("Status")
        guard_reason = stage.get("ConfigurationGuardReason")
        if guard_reason:
            state = "failed"
            reason = configuration_failure_reason(guard_reason)
            problems = [{"title": "配置校验", "summary": reason + "，任务已中止", "state": state}]
        elif raw_status == "startup_failed":
            state, problems = "not_run", []
            if game in startup_reasons:
                state = "failed"
                problems = [{"title": "启动检查", "summary": configuration_failure_reason(startup_reasons[game]), "state": state}]
        elif stage_status == "running" and not finished_at:
            state = "running"
            # A running report may not have task evidence yet.
            problems = []
        elif stage_status == "cancelled" or (report.get("Cancelled") and not native_ok):
            state = "cancelled"
        elif stage_status == "failed":
            state = "failed"
        elif problems:
            state = "incomplete"
        elif native_ok:
            state = "completed"
        elif not stage:
            state = "not_run"
        elif not finished_at and stage_status in (None, "preparing", "pending"):
            state = "not_run"
        else:
            state = "incomplete"
        if state in ("failed", "incomplete") and not problems:
            problems = [{"title": "日常任务", "summary": "执行失败" if state == "failed" else "缺少完成记录", "state": state}]
        startup_block = next((t for t in problems if t["title"] == "进入大世界"), None)
        if startup_block:
            problems = [startup_block]
        for task in problems:
            alerts.append({"game": game, "task": task["title"], "state": task["state"], "message": task["summary"]})
        counts = {k: sum(t["state"] == k for t in game_tasks) for k in LABELS}
        if problems:
            summary = "；".join(t["title"] + "：" + t["summary"] for t in problems[:2])
        elif state == "completed":
            power = next((t for t in game_tasks if t["title"] in ("清树脂", "体力副本", "源质清理智")), None)
            summary = power["summary"] if power else "日常任务完成"
        else:
            summary = LABELS[state]
        result_games.append({"id": game, "name": name, "state": state, "label": LABELS[state],
                             "kind": KINDS.get(state, ""), "summary": summary, "counts": counts,
                             "tasks": game_tasks, "notes": notes})

    for error in report.get("FinalizeErrors") or []:
        alerts.append({"game": None, "task": "任务收尾", "state": "failed", "message": str(error)[:140]})
    for error in report.get("ReadErrors") or []:
        alerts.append({"game": None, "task": "运行记录", "state": "missing", "message": str(error)[:140]})
    completed = sum(g["state"] == "completed" for g in result_games)
    if report.get("Cancelled") or raw_status == "cancelled":
        state, title = "cancelled", "已中止"
    elif raw_status == "startup_failed":
        state, title = "failed", "启动失败"
    elif not finished_at and raw_status in ("running", "preparing"):
        state, title = "running", "运行中"
    elif alerts:
        state, title = "incomplete", f"{len(alerts)} 项未完成"
    elif completed == len(games) and games and raw_status == "native_sequence_completed_requires_reward_review":
        state, title = "completed", "已完成"
    else:
        # Historical worker failures remain failures even if later reassessed.
        state, title = "incomplete", "运行未完成"
    if state == "completed":
        summary = f"{len(games)} 个游戏日常已完成" if len(games) > 1 else "日常任务已完成"
    elif alerts:
        summary = "；".join((NAMES.get(a["game"], "") + " · " + a["task"] + "：" + a["message"]).lstrip(" ·") for a in alerts[:3])
    else:
        summary = title
    return {"state": state, "title": title, "kind": KINDS.get(state, "warning"), "summary": summary,
            "completedGames": completed, "gameCount": len(games), "alerts": alerts, "games": result_games}


def compact_display(display):
    return {**display, "games": [{k: v for k, v in game.items() if k not in ("tasks", "notes")} for game in display["games"]]}
