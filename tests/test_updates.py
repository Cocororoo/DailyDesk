import json
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "dashboard"))
from support import AppError
from updates import _read_maa_json, check_maa_upgrade, maa_schema, sha256_file


class MaaJsoncTests(unittest.TestCase):
    def test_sha256_file_streams_release_content(self):
        content = b"DailyDesk updater integrity check"
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "release.7z"
            path.write_bytes(content)
            self.assertEqual(sha256_file(path), hashlib.sha256(content).hexdigest())

    def test_comments_and_trailing_commas_are_accepted_without_changing_strings(self):
        source = '''
        // Full-line comment
        {
          "task": [{"name": "Launch",}],
          "option": {
            "url": "https://example.test/path//segment",
            "pattern": "^a\\/\\/b$",
            /* Inline block comment */
          },
        }
        '''

        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "task.json"
            path.write_text(source, encoding="utf-8")

            self.assertEqual(
                _read_maa_json(path),
                {
                    "task": [{"name": "Launch"}],
                    "option": {
                        "url": "https://example.test/path//segment",
                        "pattern": "^a//b$",
                    },
                },
            )

    def test_schema_reads_commented_task_definitions(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            installation = Path(temporary_directory)
            tasks_directory = installation / "tasks"
            tasks_directory.mkdir()
            (tasks_directory / "launch.json").write_text(
                '{"task":[{"name":"Launch"}],"option":{"Region":{}}}',
                encoding="utf-8",
            )
            (tasks_directory / "daily.json").write_text(
                '{\n// Maintainer note\n"task":[{"name":"Daily",}],\n'
                '"option":{"Repeat":{},},\n}',
                encoding="utf-8",
            )
            (installation / "interface.json").write_text(
                json.dumps({"task": [{"name": "CloseGamePC"}]}),
                encoding="utf-8",
            )

            tasks, options = maa_schema(installation)

            self.assertEqual(tasks, {"Launch", "Daily", "CloseGamePC"})
            self.assertEqual(options, {"Region", "Repeat"})

    def test_removed_option_on_disabled_task_does_not_block_upgrade(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            live = root / "live"
            staging = root / "staging"
            for installation in (live, staging):
                (installation / "tasks").mkdir(parents=True)
                (installation / "interface.json").write_text(
                    json.dumps({"task": []}),
                    encoding="utf-8",
                )

            (live / "tasks/feature.json").write_text(
                json.dumps({"task": [{"name": "TrialOfSwordmancy"}], "option": {"Removed": {}}}),
                encoding="utf-8",
            )
            (staging / "tasks/feature.json").write_text(
                json.dumps({"task": [{"name": "TrialOfSwordmancy"}], "option": {}}),
                encoding="utf-8",
            )
            instance = {
                "tasks": [{
                    "enabled": False,
                    "taskName": "TrialOfSwordmancy",
                    "optionValues": {"Removed": {"value": True}},
                }]
            }

            check_maa_upgrade(live, staging, instance)

            instance["tasks"][0]["enabled"] = True
            with self.assertRaises(AppError):
                check_maa_upgrade(live, staging, instance)


if __name__ == "__main__":
    unittest.main()
