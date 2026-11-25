# 每日上班 · DailyDesk

在 Windows 上串行运行原神、崩坏：星穹铁道和明日方舟：终末地日常。DailyDesk 管理任务入口、原生配置、运行记录和软件更新。游戏操作由 BetterGI、三月七小助手和 MaaEnd 执行。

| 入口 | 用途 |
| --- | --- |
| `Run-Daily.cmd` | 一键运行三款游戏，显示进度与停止窗口 |
| `Open-Dashboard.cmd` | 打开本机网页控制台，单独启动游戏、调整任务、查看历史及更新 |

## 依赖

- Windows 10 或 11，已登录的桌面会话，Windows PowerShell 5.1 及 .NET Framework 4.8。
- [BetterGI](https://github.com/babalae/better-genshin-impact)、[三月七小助手](https://github.com/moesnow/March7thAssistant) 和 [MaaEnd](https://github.com/MaaEnd/MaaEnd) 的 Windows 版。分别安装并完成原生初始化。
- 控制台使用 Python 3.10 或更新版本的标准库。通过 `py.exe` 或 `python.exe` 启动，无需安装 Python 包或 JavaScript 依赖。
- 使用控制台安装软件更新需要 [7-Zip](https://www.7-zip.org/)。将 `7z.exe` 加入 PATH，或通过配置项 `SevenZip` 指定路径。检查版本无需 7-Zip。

## 配置

从仓库副本开始的完整安装顺序见 [安装与首次运行](docs/SETUP.md)。

1. 在 BetterGI 中启用关联启动，选择简体中文的原神客户端。在一条龙中启用所需的秘境和每日奖励任务，将完成操作设为「关闭游戏和软件」。确认复活、战斗策略和队伍均已按自己的账号设置。启用显示管理时，首次手动打开游戏并保存正常游玩时使用的分辨率。
2. 在三月七小助手中阅读并确认首次声明，配置本地游戏路径、侵蚀隧洞或饰品提取，并打开清体力、每日实训和奖励。此集成日常使用自然开拓力及饰品任务的已有沉浸器。预检会指出可能覆盖日常目标或消耗额外资源的设置。
3. 在 MaaEnd 中保存要运行的日常实例。控制台的源质、稳定物资及采集设置适用于包含对应任务的原生全套日常实例。启用本机 Web API，记下端口，保留原生「启动游戏（PC）」和「关闭游戏（PC）」任务。建议先在原生工具中验证一次所选实例。
4. 退出游戏与助手。在项目目录用 PowerShell 执行配置命令，将示例路径和实例名称替换为实际值。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 `
    -BetterGI 'C:\Path\To\BetterGI' -BetterGIProfile 'Daily' `
    -March7th 'C:\Path\To\March7thAssistant' `
    -MaaEnd 'C:\Path\To\MaaEnd' -MaaEndInstance '全套日常'
```

三个路径分别指向含 `BetterGI.exe`、`m7a.exe`、`MaaEnd.exe` 的目录。示例路径仅用于说明格式，请替换为本机实际目录。`Setup.ps1` 生成只保存在本机的 `config.local.json`。支持通过 `-DataDirectory` 指定数据位置，通过 `-GameTimeZone` 和 `-ResetHour` 配置每日重置时间。原神分辨率与全屏模式可通过 `-GenshinAutomationWidth`、`-GenshinAutomationHeight` 和 `-GenshinAutomationFullscreen` 设置。默认按中国服凌晨 4 点切换游戏日，也可以按账号所在服务器修改。

```powershell
.\Run-Daily.cmd -PreflightOnly
.\Open-Dashboard.cmd -CheckOnly
```

两项检查均可在不启动游戏的情况下运行。通过后双击所需入口。`Run-Daily.cmd -Game Genshin`、`-Game StarRail` 或 `-Game Endfield` 可单独运行对应游戏。启动时按 Windows 提示确认权限。运行期间让游戏保持前台，避免键鼠输入冲突。

## 记录与恢复

- 每次启动会在数据目录内创建独立记录，包含总调度、逐任务报告和原生日志。关闭监督窗口会尝试请求原生停止，随后使用 Windows Job Object 回收该轮子进程。运行失败时，打开监督窗口中的报告查看原因。
- 常见失败的定位与单游戏恢复步骤见[失败处理](docs/FAILURE-RECOVERY.md)。
- 原神启用显示管理时使用 Setup 中配置的分辨率与窗口／全屏模式，退出后恢复本轮启动前读取的游戏显示偏好。带有专用队伍、编排脚本或资源回退的计划可在 BetterGI 中配置。控制台通过原生自动秘境任务编辑副本目标。
- 星铁实训达到 500 且缺领奖记录时，报告保留“实训已达标，缺少领奖记录”。可在三月七小助手单独运行每日实训，避免重复刷体力。
- 终末地启动界面识别连续超时会在报告里聚合为一项启动异常。进入大世界后，可从 MaaEnd 原生界面单独补跑剩余项目。
- 控制台中的自动更新默认关闭。启用后，仅在控制台服务运行期间检查并尝试安装对应官方稳定版。更新记录和回滚备份保存在本机。

## 项目结构

| 目录 | 职责 |
| --- | --- |
| `runner/` | 配置、串行调度、进程监督、取消及报告 |
| `adapters/` | 三个原生助手的启动、监控和证据解析 |
| `dashboard/` | 本机 HTTP 服务、配置修改、运行记录展示及更新 |
| `tests/` | 纯本地单元测试和 Windows 兼容性预检 |

控制台只监听 `127.0.0.1`。配置、日志、截图、历史和原生程序留在本机。项目不打包第三方二进制、游戏资产或已登录账号配置。`config.local.json` 和 `data/` 已加入忽略规则，克隆项目后需要由 `Setup.ps1` 按当前电脑重新生成。提交前检查 Git 暂存区，尤其留意使用自定义名称放在仓库下的数据目录。

## 开发

```powershell
python -m unittest discover -s tests -v
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Preflight.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SuiteLifecycle.ps1
```

CI 在 Python 3.10 和 3.12 上运行单元测试，并用 Node.js 22 检查前端语法，再执行 Windows 入口和配置预检。真实游戏和助手的端到端运行需要已配置的 Windows 桌面。第三方项目与许可说明见 [THIRD_PARTY.md](THIRD_PARTY.md)。

本项目源码采用 MIT License，详见 [LICENSE](LICENSE)。第三方程序遵循各自许可。
