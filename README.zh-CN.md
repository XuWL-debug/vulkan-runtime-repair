# vulkan-runtime-repair

在不重装显卡驱动的前提下，修复 **Windows 上缺失或损坏的 Vulkan 运行时**。

[English README](README.md)

## 这个工具解决什么问题

不少游戏启动时会弹「显卡驱动版本过低，请更新驱动至最新版本」，但显卡驱动
其实已经是厂商提供的最新版。这类提示往往是**启动时的 Vulkan 能力检查失败**
被笼统归因成了驱动版本问题。此时再更新一次驱动、或者去改注册表里的驱动
版本号字符串，都不会有任何效果。

显卡驱动包里本来就带有 Vulkan loader 和 ICD 清单。有时这些组件没有正确落地
（安装不完整、清理工具误删、驱动回滚、Windows Update 替换了厂商驱动等），
系统里就表现为：

- `%WINDIR%\System32\vulkan-1.dll`、`SysWOW64\vulkan-1.dll` 不存在；
- `HKLM\SOFTWARE\Khronos\Vulkan\Drivers` 下没有任何 ICD 注册；
- 程序列表里没有 Vulkan Runtime Libraries；
- 但驱动包目录里 `amdvlk64.dll` / `nvoglv64.dll` / ICD json 等文件齐全。

本工具把缺的这两样东西补回去：**loader 落地 + ICD 注册**。

## 功能特点

- **厂商无关**：扫描 `DriverStore\FileRepository` 中所有符合标准格式
  （含 `ICD` 与 `library_path`）的 json 清单，不预设 AMD / NVIDIA / Intel 的文件名。
- **真实发现**：通过 PE 头判断 DLL 位数，并确认它确实导出 `vkCreateInstance`，
  不靠文件名猜。
- **真实验证**：内嵌 C# P/Invoke 直接调用 Vulkan API，读取设备名、
  `apiVersion`、`driverVersion`。不依赖 Python、Vulkan SDK 或任何第三方工具。
- **可回滚**：`Fix` 创建的每个文件、注册表值和键都记录在状态文件里，
  `Undo` 精确还原。
- **无硬编码**：不含盘符、用户名、显卡型号、游戏路径等任何机器特定信息。

## 运行环境

- Windows 10 / 11；Windows PowerShell 5.1 或 PowerShell 7
- 仅 `Fix` / `Undo` 需要管理员权限
- 显卡驱动包中仍保留 Vulkan 组件

## 使用方法

| 文件 | 作用 |
| --- | --- |
| `diagnose.cmd` | 只读诊断，不需要管理员 |
| `repair.cmd` | 执行修复，自动弹出 UAC 提权 |
| `undo.cmd` | 回滚修复，自动弹出 UAC 提权 |

也可以用 PowerShell：

```powershell
.\Repair-VulkanRuntime.ps1 -Mode Diagnose
.\Repair-VulkanRuntime.ps1 -Mode Fix
.\Repair-VulkanRuntime.ps1 -Mode Verify
.\Repair-VulkanRuntime.ps1 -Mode Undo
```

### 参数

| 参数 | 说明 |
| --- | --- |
| `-Mode` | `Diagnose`（默认）/ `Verify` / `Fix` / `Undo` |
| `-DriverPackagePath` | 指定某个驱动包目录，跳过全盘扫描 |
| `-PruneInvalidIcd` | 顺带清理指向已不存在 json 的失效 ICD 项（Undo 可恢复） |
| `-Force` | 覆盖已存在的 loader，原文件会备份（Undo 可恢复） |
| `-LogPath` | 追加纯文本日志 |
| `-StatePath` | 自定义撤销状态文件位置 |

`repair.cmd -PruneInvalidIcd -Force` 这样也能把参数直接传进去。

## 怎么看懂输出

正常结果：

```text
=== Vulkan API probe (what games actually see) ===
  [system] OK: <你的显卡> | Vulkan API 1.3.xxx | driverVersion ... | devices 1
  [driver package only] OK: <你的显卡> | Vulkan API 1.3.xxx | ...
```

`[driver package only] OK` 但 `[system] FAILED`，是本问题的典型特征：
**驱动本身完全可用，只是系统级运行时没装好**，正是 `Fix` 要修的情况
（诊断时会先直接用驱动包里的 loader 实测一次，不改任何系统设置）。

如果 `[driver package only]` 也失败，说明驱动包本身不完整，需要重装完整的
厂商驱动并勾选清洁安装 / Factory Reset，然后重启。脚本无法恢复不存在的文件。

## 安全性

- `Diagnose` / `Verify` 严格只读。
- `Fix` 只做两件事：把 loader 复制到 `System32` / `SysWOW64`；在
  `HKLM\SOFTWARE\Khronos\Vulkan\Drivers` 写入 `REG_DWORD` 值。
  不修改驱动二进制、INF、服务，也不改任何驱动版本号。
- 已存在的文件默认跳过；只有加 `-Force` 才覆盖，且先备份。
- 状态文件 `vulkan-repair-state.json` 与 `vulkan-repair-backups/` 请保留到确认无问题。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 成功 / Vulkan 探测正常 |
| 1 | 需要管理员权限 |
| 2 | 找不到可用驱动包，或探针编译失败 |
| 3 | 修复后 Vulkan 探测仍然失败 |

## 局限

- 驱动包里没有 loader 时，只能重装完整驱动。
- 只修运行时；如果游戏确实要求硬件不支持的 Vulkan 特性，本工具无能为力。
- HKLM 改动是系统级的，如有异常请执行 `Undo`。

## 许可证

MIT，见 [LICENSE](LICENSE)。
