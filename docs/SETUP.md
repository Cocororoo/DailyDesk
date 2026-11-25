# DailyDesk 安装与首次运行

这份说明适用于从仓库副本开始的新用户。DailyDesk 只负责串行调度、配置检查、进程回收、运行记录和本地控制台。三个游戏的实际操作仍由各自的原生助手完成。

## 1. 准备环境

需要一台 Windows 10 或 Windows 11 电脑，并使用已登录的桌面会话。

安装以下组件。

- Windows PowerShell 5.1 和 .NET Framework 4.8
- Python 3.10 或更新版本，并确保 `py.exe` 或 `python.exe` 可在 PowerShell 中找到
- [BetterGI](https://github.com/babalae/better-genshin-impact)
- [三月七小助手](https://github.com/moesnow/March7thAssistant)
- [MaaEnd](https://github.com/MaaEnd/MaaEnd)
- 只有从控制台安装助手更新时才需要 [7-Zip](https://www.7-zip.org/)

三个原生助手都需要先完成自己的首次初始化和账号登录。DailyDesk 不保存账号凭据，也不会替用户确认第三方助手的首次声明。

## 2. 初始化三个原生助手

### BetterGI

在 BetterGI 中完成关联启动，选择原神客户端，并创建一个 OneDragon 配置。配置中打开需要执行的一条龙任务，设置副本目标、队伍、战斗策略和完成后的关闭动作。若使用自动切换显示设置，先手动打开原神并保存正常游玩时的显示模式。

配置目录中应存在以下文件。

```text
BetterGI.exe
User\OneDragon\<配置名>.json
```

### 三月七小助手

在助手中完成首次声明，确认游戏路径和账号。设置清体力、每日实训、奖励领取以及侵蚀隧洞或饰品提取目标。先在原生界面单独运行一次，确认登录、路径和目标都有效。

安装目录中应存在 `m7a.exe`，以及助手自己的配置和资源目录。

### MaaEnd

在 MaaEnd 中创建或确认要运行的实例，启用本机 Web API，记下端口和实例名称。保留原生的启动游戏和关闭游戏任务，并先在原生界面完成一次验证。

安装目录中应存在 `MaaEnd.exe`，实例配置应包含启用的日常任务和关闭游戏任务。

## 3. 生成本机配置

在 `DailyDesk` 目录打开 PowerShell。将三个路径替换为实际安装目录，将实例名称替换为 MaaEnd 中的名称。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 `
  -BetterGI 'C:\Path\To\BetterGI' `
  -BetterGIProfile 'Daily' `
  -March7th 'C:\Path\To\March7thAssistant' `
  -MaaEnd 'C:\Path\To\MaaEnd' `
  -MaaEndInstance '全套日常'
```

示例路径只用于说明格式，请替换为本机实际安装目录。`Setup.ps1` 会检查三个入口文件和 BetterGI 配置文件，并生成 `config.local.json`。该文件只保存在本机，已被 `.gitignore` 排除，不应提交到仓库。

常用可选参数如下。

```text
-DataDirectory                 运行记录和证据目录，默认是项目下的 data
-GameTimeZone                  每日重置时区，默认是 China Standard Time
-ResetHour                     每日重置小时，默认是 4
-GenshinAutomationWidth        原神自动化显示宽度，默认是 1920
-GenshinAutomationHeight       原神自动化显示高度，默认是 1080
-GenshinAutomationFullscreen   让自动化阶段使用全屏
-LeaveGenshinDisplay           不接管原神显示设置
-SevenZip                      指定 7z.exe 的完整路径
```

## 4. 预检和启动

先退出三个游戏和原生助手，再运行无启动预检。

```powershell
.\Run-Daily.cmd -PreflightOnly
.\Open-Dashboard.cmd -CheckOnly
```

预检通过后，可以使用以下入口。

```powershell
.\Run-Daily.cmd                         # 串行运行三个游戏
.\Run-Daily.cmd -Game Genshin           # 只运行原神
.\Run-Daily.cmd -Game StarRail          # 只运行星穹铁道
.\Run-Daily.cmd -Game Endfield          # 只运行终末地
.\Open-Dashboard.cmd                    # 打开本机控制台
```

控制台地址是 `http://127.0.0.1:17861`。控制台可以单独启动游戏、编辑可调整的任务计划、查看运行历史和管理助手更新。端口只监听本机回环地址。

运行期间保持游戏桌面会话可见，避免其他程序抢占键鼠输入。关闭“每日上班”窗口会请求原生助手停止，并回收本轮由它启动的子进程。之后可根据运行记录使用单游戏入口补跑。

## 5. 验证安装

以下命令不需要启动真实游戏。

```powershell
python -m unittest discover -s tests -v
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Preflight.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SuiteLifecycle.ps1
```

若只需要检查当前配置，可再次运行 `Run-Daily.cmd -PreflightOnly`。预检会报告缺失的程序、原生配置、占用进程和 MaaEnd API 问题。

## 6. 运行记录和故障恢复

默认记录位于 `data\history`，每轮包含总调度状态、逐游戏日志、原生证据和 HTML、Markdown 报告。`data` 已被忽略，不会进入 Git。

打开控制台的“运行记录”查看失败项目和证据。根据[失败处理](FAILURE-RECOVERY.md)只补跑未完成的游戏或原生任务。不要用历史配置覆盖原生助手当前配置。

## 7. 更新和图标

控制台的“软件更新”页面可以检查三个助手的官方稳定版。安装更新前会检查运行状态，并保留可恢复的本机备份。自动更新开关默认关闭。

DailyDesk 的主 Logo 已直接随项目保存于 `dashboard\static\march7th.ico`。控制台通过 `/brand-icon` 使用该文件，也可通过 `/March7th.ico` 直接访问。clone 仓库后无需依赖原安装目录中的图标文件。
