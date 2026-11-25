import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "dashboard"))
from results import build_display, task_display

SUCCESS = 'native_sequence_completed_requires_reward_review'


def row(name, status, detail='', game='原神'):
    return {'Game':game, 'Task':name, 'Status':status, 'Detail':detail, 'Evidence':''}


class ResultViewTests(unittest.TestCase):
    def display(self, tasks, native=True, status=SUCCESS, game='Genshin', **report):
        stage = {'Game':game, 'NativeCompleted':native, 'Status':'native_completed_requires_reward_review' if native else 'incomplete_closed'}
        return build_display({'Tasks':tasks, **report},[stage],status,[game],'2026-11-17T12:00:00+08:00')

    def test_successful_tasks_do_not_create_reward_audit_alerts(self):
        tasks=[row('秘境／清树脂','日志支持完成','目标：Domain A；挑战完成 5 次；最终原粹 14，浓缩 0'),
               row('秘境掉落物品','掉落数量未核验','奖励识别 0 轮；'),
               row('日志异常／提示','请检查','自动秘境：奖励结果页未检测到退出按钮，已跳过本轮奖励识别')]
        d=self.display(tasks)
        self.assertEqual(d['state'],'completed')
        self.assertEqual(d['alerts'],[])
        self.assertEqual(len(d['games'][0]['tasks']),1)
        self.assertEqual(d['games'][0]['tasks'][0]['summary'],'Domain A · 5 次 · 剩余树脂 14')
        self.assertEqual(len(d['games'][0]['notes']),2)

    def test_action_only_is_not_claimed_reward_and_no_reward_is_normal(self):
        task=task_display(row('邮件','有操作记录；待核验','邮件："全部领取"'))
        self.assertEqual(task['state'],'executed')
        self.assertEqual(task['label'],'已执行')
        task=task_display(row('邮件','有操作记录；待核验','未检测到邮件奖励'))
        self.assertEqual(task['state'],'skipped')
        self.assertEqual(task['label'],'无可领取')

    def test_real_commission_shortfall_is_one_explicit_alert(self):
        detail='委托 3/4；已耗树脂 100/120；树脂缺口 20'
        d=self.display([row('每日委托奖励','前置未满足',detail),
            row('日志异常／提示','请检查','一条龙结束汇总："浓缩树脂 0；原粹树脂 14/200；每日委托奖励：未领取"；Commission verification: prerequisite_incomplete; completed=3; resinConsumed=100; resinShortfall=20')],native=False,status='needs_attention')
        self.assertEqual(d['title'],'1 项未完成')
        self.assertEqual(d['alerts'][0]['message'],'委托 3/4，还差 20 树脂消耗')

    def test_child_failure_remains_failure_among_successful_tasks(self):
        d=self.display([row('特产采集／存仓','失败（含子任务错误）','AutoCollectWulingTalosCap1Start: FailureCollector subtask failed','终末地'),
                        row('信用点购物','原生成功；收益待核验','','终末地')],native=False,status='needs_attention',game='Endfield')
        self.assertEqual(d['alerts'][0]['message'],'进入雪松林失败（塔罗斯菌）')
        self.assertEqual(d['games'][0]['tasks'][0]['state'],'failed')
        self.assertEqual(d['games'][0]['tasks'][1]['state'],'completed')
        other=task_display(row('特产采集／存仓','失败（含子任务错误）','AutoCollectWulingProtocolith2Goto: FailureCollector subtask failed','终末地'))
        self.assertEqual(other['summary'],'武陵采集路线失败')

    def test_scheduled_skip_is_not_failure_or_new_collection(self):
        d=self.display([row('特产采集／存仓','按周计划跳过','本轮为 Monday','终末地')],game='Endfield')
        self.assertEqual(d['state'],'completed')
        self.assertEqual(d['games'][0]['counts']['skipped'],1)
        self.assertEqual(d['games'][0]['tasks'][0]['summary'],'今日不在采集计划内')

    def test_successful_batch_does_not_invent_final_power(self):
        d=self.display([row('遗器清体力','挑战已完成；最终余量待核验','目标：Cavern A；完成 1 批；计划 1 批×每批 3 次；本轮体力观测：149；末次观测不是最终余量','星穹铁道')],game='StarRail')
        task=d['games'][0]['tasks'][0]
        self.assertEqual(task['title'],'体力副本')
        self.assertEqual(task['summary'],'Cavern A · 1 批 × 3 次')
        self.assertNotIn('149',task['summary'])
        self.assertEqual(task['raw']['Status'],'挑战已完成；最终余量待核验')

    def test_missing_evidence_and_unknown_errors_remain_visible(self):
        d=self.display([row('每日委托奖励','待核验；缺少完成证据')])
        self.assertEqual(d['state'],'incomplete')
        self.assertEqual(d['alerts'][0]['state'],'missing')
        d=self.display([row('日志异常／提示','请检查','自动派遣失败：找不到入口')])
        self.assertEqual(d['state'],'incomplete')
        self.assertIn('找不到入口',d['alerts'][0]['message'])

    def test_history_not_rewritten_or_failed_worker_promoted_to_success(self):
        tasks=[row('信用点购物','原生成功；收益待核验','','终末地')]
        before=copy.deepcopy(tasks)
        d=self.display(tasks,status='failed',game='Endfield')
        self.assertEqual(d['state'],'incomplete')
        self.assertEqual(tasks,before)
        d=self.display(tasks,game='Endfield',FinalizeErrors=['failed to close process'])
        self.assertEqual(d['state'],'incomplete')

    def test_running_and_cancelled_are_not_completed(self):
        d=build_display({'Tasks':[]},[{'Game':'Genshin','Status':'running'}],'running',['Genshin'],None)
        self.assertEqual(d['state'],'running')
        self.assertEqual(d['alerts'],[])
        d=self.display([],native=False,status='cancelled',Cancelled=True)
        self.assertEqual(d['state'],'cancelled')


if __name__ == '__main__':
    unittest.main()
