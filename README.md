# DSH 启动器（DeepSeek Harness Launcher）

DeepSeek Harness（DSH）的 Windows 桌面启动器：官网风格控制台 + 独立透明桌宠。

## 功能

- **一键打开 / 重启**：按端口 3080 找到占用进程并重启；服务未运行则自动启动（约 5-15 秒）并打开浏览器；配置损坏时自动以安全模式重试
- **环境状态**：DSH 版本、PID、视觉 Key、技能数量、配置备份、安全模式
- **技能库**：浏览 `~/.dsh/skills` 下的本地技能，点击卡片打开目录
- **运行日志 / 配置备份 / .dsh 目录**：一键打开
- **控制台界面**：DeepSeek 官网风格 —— 暖白底 + 顶部淡蓝晕染（"纱布撒蓝"）、大字距标题、方形按钮、玻璃胶囊、footer 小字链接；顶栏「🐳 桌宠」开关控制桌宠显示
- **独立透明桌宠**（借鉴 大肥鱼 / Desktop-Pet，置顶悬浮可拖到桌面任意位置）
  - 动画：待机 / 左右行走 / 挥手 / 跳跃 / 失败 / 等待 / 思考 / 检查 / 16 方向注视（标准 Codex 图集 8×11）
  - 互动：**按住拖动整窗**、**双击跳跃**、**短按挥手**、**右键菜单**（散步 / 跟随鼠标 / 原地待着 / 喂食 / 缩放 / 退出）
  - **气泡跟随**：白底蓝边气泡悬在头顶随人物移动，内容可变（闲聊 / 思考 / 任务完成庆祝 / 互动回嘴 / 系统提醒）
  - **DSH 联动**：`~/.dsh/sessions` 活跃 → 自动切 think/review 动画陪思考；忙完跳跃庆祝
  - 系统监控：内存 >90%、CPU >85% 自动冒泡提醒
  - 细节：呼吸摇摆 / 加减速惯性 / 转身淡化 / 说话冷却 / 表情自动消退
- **六层防火墙**：配置快照、坏条目隔离、安全模式、自动降级、UI 异常兜底（事件处理器异常不再崩进程）、启动重试

## 用法

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File dsh-launcher.ps1
```

| 参数 | 说明 |
|---|---|
| `-HideConsole` | 启动后隐藏控制台窗口（桌面快捷方式使用） |
| `-AutoTest` | 自动测试：模拟点击 + 验证防崩防火墙后自动关闭 |
| `-Diag` | 2 秒后写诊断信息到 `%TEMP%\dsh-diag.txt` |

其他脚本：

- `launch-dsh.ps1`：无界面版，启动 DSH 并打开浏览器（安全模式自动重试）
- `restart-dsh.ps1`：延迟 25 秒重启（供 agent 自动重启使用），按端口杀旧进程后委托 `launch-dsh.ps1`

## 环境要求

- Windows + PowerShell 5.1（自带，无需安装）
- [Node.js](https://nodejs.org/) 与 [DeepSeek Harness](https://github.com/deepseek-ai/DeepSeek-Harness)（`dsh` 命令可用；启动器会自动探测安装位置）

## 目录结构

```
dsh-launcher.ps1        # 主启动器（双主题 WPF）
launch-dsh.ps1          # 无界面启动脚本
restart-dsh.ps1         # 延迟重启脚本
whale-assets/           # 桌宠图集与鲸鱼素材
dsh-whale-girl-source.png  # 鲸鱼娘原始透明底大图
dsh-whale-girl.ico      # 桌面快捷方式图标（多尺寸）
```

## 素材署名与许可

鲸鱼娘形象素材（`dsh-whale-girl-source.png`、`dsh-whale-girl.ico`、`whale-assets/` 内素材）：

- 角色形象来源：上善无相（原创 OC「渊月」）
- DeepSeek 元素二创：zipZipPipe
- 改进版修图：QYQCAMIAO
- 图标整理与仓库：[fornarwhal/deepseek-whale-girl-icon](https://github.com/fornarwhal/deepseek-whale-girl-icon)
- 许可协议：**CC BY-NC-SA 4.0**（须署名、非商用、相同方式共享）

桌宠图集动画规范参考：[GaoHaoSong/Desktop-Pet](https://github.com/GaoHaoSong/Desktop-Pet)（Codex 鲸鱼娘图集，MIT）。

> 请勿将本仓库用于商业用途。启动器代码本身可自由使用。

## 免责声明

本启动器通过启动/重启本地 DSH 服务管理你的环境，重启会强制结束 3080 端口进程。使用前请确认该端口没有其他重要服务。
