"""Native plan read/write tests against isolated assistant configuration files."""
from copy import deepcopy
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "dashboard"))
from plans import NativePlans
from support import AppError


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


class NativePlanTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bgi = self.root / "BetterGI"
        self.star = self.root / "March7th"
        self.end = self.root / "MaaEnd"
        self.config_path = self.root / "config.local.json"
        write_json(self.config_path, {
            "SchemaVersion": 1,
            "DataDirectory": "data",
            "Genshin": {"Directory": "BetterGI", "Profile": "Daily"},
            "StarRail": {"Directory": "March7th"},
            "Endfield": {"Directory": "MaaEnd", "Instance": "Daily"},
        })
        write_json(self.bgi / "User/OneDragon/Daily.json", {
            "Name": "Daily",
            "DomainName": "Testing",
            "WeeklyDomainEnabled": False,
            "SundaySelectedValue": "1",
            "SundayEverySelectedValue": "1",
            "SundayWeeklySelectedValue": "1",
            "TaskDefinitions": {
                "domain": "自动秘境",
                "mail": "领取邮件",
                "pot": "领取尘歌壶奖励",
            },
            "TaskEnabledList": {"domain": True, "mail": True, "pot": False},
        })
        write_json(self.bgi / "User/config.json", {"keep": "unchanged"})
        write_json(self.bgi / "GameTask/AutoTrackPath/Assets/tp.json", {"data": [{"points": [
            {"name": "Testing", "type": "BlessDomain", "country": "Region"},
            {"name": "Alternative", "type": "MasteryDomain", "country": "Region"},
        ]}]})
        (self.star / "assets/config").mkdir(parents=True, exist_ok=True)
        write_json(self.star / "assets/config/instance_names.json", {
            "侵蚀隧洞": {"Testing": "Target A", "Alternative": "Target B"},
            "饰品提取": {"Testing": "Target C"},
        })
        (self.star / "config.yaml").write_text(
            "instance_type: 侵蚀隧洞\n"
            "instance_names:\n"
            "  侵蚀隧洞: Testing # preserve this comment\n"
            "  饰品提取: Testing\n"
            "reward_dispatch_enable: true\n"
            "reward_mail_enable: true\n"
            "reward_assist_enable: false\n"
            "reward_srpass_enable: true\n",
            encoding="utf-8",
        )
        write_json(self.end / "tasks/AutoEssence/Location/ChooseLocation.json", {
            "option": {"AutoEssenceChooseLocation": {"cases": [
                {"name": "RegionA", "label": "$RegionA"},
                {"name": "RegionB", "label": "$RegionB"},
            ]}}
        })
        write_json(self.end / "locales/interface/zh_cn.json", {"RegionA": "区域甲", "RegionB": "区域乙"})
        tasks = [
            {"taskName": "AutoCollect", "enabled": True, "enabledByController": {"Front": True},
             "optionValues": {
                 "AutoCollectSchedule": {"caseNames": ["AutoCollectScheduleTuesday"]},
                 "AutoCollectStashBackpackSubTask": {"value": True},
             }},
            {"taskName": "AutoEssence", "enabled": True, "enabledByController": {"Front": True},
             "optionValues": {
                 "AutoEssenceChooseLocation": {"caseNames": ["RegionA"]},
                 "AutoEssenceMenu": {"caseName": "Random"},
                 "AutoEssenceRepeatCount": {"values": {"AutoEssenceRepeatCountValue": "10"}},
             }},
            {"taskName": "AutoStockStaple", "enabled": True, "enabledByController": {"Front": True},
             "optionValues": {
                 "AutoStockReserveValleyIV": {"values": {"ReserveValleyIV": "150000"}},
                 "AutoStockReserveWuling": {"values": {"ReserveWuling": "150000"}},
             }},
            {"taskName": "CloseGamePC", "enabled": True, "optionValues": {}},
        ]
        write_json(self.end / "config/mxu-MaaEnd.json", {
            "instances": [{"name": "Daily", "controllerName": "Front", "tasks": tasks}],
        })
        self.native = NativePlans(
            json.loads(self.config_path.read_text(encoding="utf-8")),
            self.config_path,
            threading.RLock(),
            lambda force=False: {"processes": [], "supervisors": []},
            lambda: None,
        )
        self.native.refresh_catalog()

    def tearDown(self):
        self.temporary.cleanup()

    def test_saves_selected_native_settings_and_preserves_unrelated_files(self):
        before = self.native.configuration()
        body = {"revision": before["revision"], "games": deepcopy(before["games"])}
        body["games"]["StarRail"]["target"] = "Alternative"
        body["games"]["Endfield"].update({
            "location": "RegionB",
            "repeat": 20,
            "reserve": 200000,
            "days": ["Friday"],
            "stash": False,
            "tasks": {"AutoCollect": False, "AutoEssence": True, "AutoStockStaple": True},
        })

        result = self.native.save(body)

        self.assertEqual(result["configuration"]["games"], body["games"])
        self.assertTrue(Path(result["backup"]).is_dir())
        star_text = (self.star / "config.yaml").read_text(encoding="utf-8")
        self.assertIn("侵蚀隧洞: 'Alternative' # preserve this comment", star_text)
        self.assertEqual(json.loads((self.bgi / "User/config.json").read_text(encoding="utf-8")), {"keep": "unchanged"})
        end_config = json.loads((self.end / "config/mxu-MaaEnd.json").read_text(encoding="utf-8"))
        end_tasks = {task["taskName"]: task for task in end_config["instances"][0]["tasks"]}
        self.assertFalse(end_tasks["AutoCollect"]["enabled"])
        self.assertEqual(end_tasks["AutoEssence"]["optionValues"]["AutoEssenceMenu"]["caseName"], "Random")
        self.assertEqual(end_tasks["AutoStockStaple"]["optionValues"]["AutoStockReserveWuling"]["values"]["ReserveWuling"], "200000")

    def test_stale_revision_refuses_to_overwrite_native_edits(self):
        before = self.native.configuration()
        body = {"revision": before["revision"], "games": deepcopy(before["games"])}
        path = self.star / "config.yaml"
        original = path.read_text(encoding="utf-8")
        path.write_text(original + "# external edit\n", encoding="utf-8")

        with self.assertRaises(AppError) as raised:
            self.native.save(body)

        self.assertEqual(raised.exception.status, 409)
        self.assertTrue(path.read_text(encoding="utf-8").endswith("# external edit\n"))


if __name__ == "__main__":
    unittest.main()
