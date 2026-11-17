# M720 隐藏拇指键适配

## 范围与证据

本文记录 **macOS 上蓝牙直连的 Logitech M720 Triathlon** 隐藏拇指键适配。随后还接入了标准 Unifying `C52B / C532` 上的 M720 拇指键，接口发现、槽位隔离与回测见 [Unifying 说明](m720-unifying.md)。Bolt 等其他接收器与 USB 有线仍不在范围内。对应版本为 `v0.7.12`，以未经实机验证的实验性支持提供；签名身份和配置格式保持不变。

M720 硬件支持这个键自定义，并不是一个只能执行原厂动作的按键：

- [罗技官方文档](https://support.logi.com/hc/en-001/articles/360023188834-Customize-M720-wireless-mouse-gestures-with-Logitech-Options)介绍了手势与自定义组合键分配。
- [Mouser #47 的设备报告](https://github.com/TomBadash/Mouser/issues/47)同时列出了物理控件 `0x00D0` 与虚拟控件 `0x00D7`；物理拇指控件的 flags 为 `0x0171`，包含可接管位 `0x20`。
- [OpenLogi #1385](https://github.com/AprilNEA/OpenLogi/pull/1385)记录了作者在 macOS 蓝牙直连下的单击和按住拖动验证，评论也有 Unifying 接收器的 macOS 成功测试。这是第三方实机证据，**不是 Open Mouse 的实机测试结果**。

## 实现

`LogitechHIDPPProtocol` 将 `0x00D0` 映射到独立逻辑按键 `6`，界面显示「拇指键」。编号沿用现有 `ButtonBinding.button` 持久化机制，不复用 Forward 的 `4` 或 DPI Switch 的 `5`，也不改写旧映射。`0x00D7` 不能代替 M720 的物理拇指键。

- 录入期间临时请求拇指控件，解决「尚无绑定所以不接管、收不到第一次按下」的死循环。
- 接管计划只选择设备真实上报且可接管的控件；没有 DPI Switch 或可调 DPI 功能不妨碍 M720 拇指键录入。
- 有生效绑定时持续接管；退出录入且没有绑定、删除绑定或停用引擎时释放接管。只设置报告模式，不覆盖原厂 target CID。
- HID++ 按下／抬起进入现有 `EventRouter`，复用自定义快捷键、修饰键组合和手势导航，无需新增动作类型或键盘监听。
- 录入中途关闭可能让物理抬起不再通过 HID++ 上报。解除所有权时主动清掉不再拥有的按住状态与 claim，避免下一次首次按下被旧状态吞掉；仍被接管的其他按住会话不受影响。

## 自动检查边界

`SelfCheck` 使用真实控件编号和报告字节驱动纯逻辑及实际 `EventRouter`，覆盖：

- 物理 / 虚拟控件区分、稳定编号、接管 / 释放参数及界面名称；
- 没有任何绑定时首次录入、缺失 DPI 控件、不可接管与未知控件过滤；
- 拇指 / Forward / DPI 同时按住、重复报告、独立释放；
- 拇指自定义快捷键与 Forward 不互相覆盖、配置变化后的抬起及 JSON 往返；
- 拇指手势一次按住只触发一次、原地单击、motion tap 活动通知配对；
- 实际异步录入回调、录入中途关闭且没有硬件 up、重新录入第一下。

蓝牙阶段验证结果（接收器阶段的新增回归见 [Unifying 说明](m720-unifying.md)）：

- `make test`：605 项应用自检全部通过（本次新增 34 项），更新助手自检、6 项发布签名、16 项社区签名与 26 项构建元数据检查全部通过。
- `make debug`：隔离 Debug 包构建、固定社区身份签名及签名验证通过；主程序和更新助手均为 SDK 27.2 / 最低 macOS 14.0。
- 组装后直接运行 Debug 包 `--self-check`：605 项全部通过。

**这些检查不打开 M720 的 IOKit 设备，不能代替实机测试。** 本项目目前没有 M720 硬件，兼容性仍需反馈者按下面步骤回测。

## 测试包

本地生成 `build/OpenMouse-M720-Debug-arm64.zip`，内容为 `Open Mouse Debug.app`。这是 **Apple Silicon / arm64** 的未公证、固定社区身份签名测试包，不是正式发布；Intel Mac 需要另行构建 x86_64 包。配置目录和 TCC 身份均与正式版隔离。

## 反馈者回测

1. 明确使用 **蓝牙直连**，不是插着 Unifying 接收器。回测时只运行一个 Open Mouse 实例，退出 Logi Options+ 等同类工具。
2. 本地测试使用 `build/Open Mouse Debug.app`，不要启动另一个正式名称实例。给 **Open Mouse Debug** 分别授予辅助功能和输入监控；输入监控授权后重新启动测试包。Debug 配置与正式版隔离，不会修改正式偏好。
3. 打开「按键」→「录入按键」，按下拇指托位置的隐藏键，确认显示「拇指键」，而不是「侧键 5」或「DPI 键」。没有动作绑定时也应能完成第一次录入。
4. 选择「自定义快捷键」，录入 `⌘C` 并保存。在文本编辑器选择一段文字，按拇指键，再粘贴确认复制成功。
5. 给前进／后退侧键另设不同动作，确认它们与拇指键独立。再录入 `⌘ + 拇指键`，检查修饰键组合与普通拇指绑定独立。
6. 将拇指键设为手势导航，检查单击、横向与纵向移动。左右桌面测试需在指针所在显示器有可切换的空间；到达边界静默是系统行为，不据此判断接管失败。
7. 在录入时保持拇指键按下并取消录入，再松开并重新录入，确认新的第一次按下仍可识别。删除最后一条拇指绑定并保存后，检查原厂动作恢复；重新启动应用后检查已保存的绑定仍有效。

失败时收集 HID++ 日志，不需要全局键盘 tap 或真实键盘输入记录：

```bash
/usr/bin/log show --last 5m --predicate 'subsystem == "com.openmouse.OpenMouse" && category == "hidpp"' --info
```

预期可见设备连接与控件发现，然后在录入或绑定生效时出现：

```text
control cid=0xd0 button=6 divertable=true
cid=0xd0 divert=true sent=true
activeButtons=[6]
activeButtons=[]
```

退出录入且无绑定后应出现 `cid=0xd0 divert=false sent=true`。`sent=true` 只说明 IOKit 收下请求，不证明硬件实际接管成功；必须结合按下／抬起日志与实际动作判断。反馈请附 macOS 版本、连接方式、权限状态，以及是「录不到」还是「录得到但动作不执行」。
