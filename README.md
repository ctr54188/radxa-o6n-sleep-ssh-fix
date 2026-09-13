# radxa-o6n-sleep-ssh-fix

> Radxa Orion O6N（CIX P1 / Debian 12 bookworm）**一键修复"自动休眠死机"与"SSH 开机不自启"** 的脚本。

[![platform](https://img.shields.io/badge/platform-Radxa%20Orion%20O6N-blue)]()
[![os](https://img.shields.io/badge/OS-Debian%2012%20bookworm-red)]()
[![arch](https://img.shields.io/badge/arch-aarch64%20%7C%20amd64-green)]()

---

## 一、问题现象

| # | 现象 |
|---|---|
| 1 | 机器会**自动休眠**，休眠后**无法唤醒**（黑屏/无响应），只能强制重启 |
| 2 | 重启后 SSH **连不上**；即使把机器"唤醒"，SSH 也依然不通。必须在机器本地执行 `sudo systemctl restart ssh` 才能恢复 |

## 二、根因分析

### 问题 1：自动休眠 —— 进了 S3 就回不来

`journalctl` 中的真实挂起记录（全盘仅 1 次）：

```
2026-09-13 04:46:44  systemd-logind: The system will suspend now!
2026-09-13 04:46:49  systemd[1]: Starting systemd-suspend.service - System Suspend...
2026-09-13 04:46:49  kernel: PM: suspend entry (deep)
```

**之后没有任何 `PM: suspend exit` / `resume` 日志** —— 说明机器进入 S3(deep) 后再也没能成功唤醒，属于"睡死"。

触发链：`GNOME 桌面空闲 15 分钟` → `gsd-power` 请求 `systemd-logind` 挂起
（当时 `sleep-inactive-ac-type='suspend'`、`idle-delay=900`）。

叠加硬件因素：

```console
$ cat /sys/power/state        # freeze mem disk
$ cat /sys/power/mem_sleep    # s2idle [deep]      <-- 默认选中 deep(S3)
```

该 SoC 的 S3 休眠唤醒不可靠，一旦睡下去就回不来。

### 问题 2：SSH 服务 —— 根本没开机自启

```console
$ systemctl is-enabled ssh
disabled                      # <-- 关键
```

`ssh.service` / `ssh.socket` 均为 **disabled**（vendor preset 是 enabled，但被关掉了）。每次开机 sshd 都不会启动，只能人工拉起：

```
2026-09-13 08:21:41  Started ssh.service     <-- 人工启动
2026-09-13 09:53:57  Started ssh.service     <-- 开机 3 分钟后人工启动
```

> boot -2（9/7 ~ 9/13，共 6 天）期间 sshd **一次都没启动过**。

## 三、修复方案

脚本 `radxa-fix-sleep-ssh.sh` 分 7 步处理：

| 步骤 | 内容 | 落盘位置 |
|---|---|---|
| 1 | SSH 安装 + 开机自启 + `sshd -t` 语法自检 | `systemctl enable ssh` |
| 2 | sshd 崩溃/异常退出自动拉起（含 255） | `/etc/systemd/system/ssh.service.d/10-restart.conf` |
| 3 | **四层禁休眠**：logind 忽略 idle/挂起键/合盖 → `Allow*=no` → `mask` 睡眠服务 → 强制 `s2idle` | `/etc/systemd/logind.conf.d/99-disable-sleep.conf`<br>`/etc/systemd/sleep.conf.d/99-disable-sleep.conf`<br>`/etc/tmpfiles.d/99-power.conf` |
| 4 | 万一真睡了：唤醒后自动重连网卡 + 重启 sshd | `/etc/systemd/system-sleep/50-restart-ssh.sh` |
| 5 | 桌面层：系统级 dconf 默认值 + 对现存图形会话立即生效 | `/etc/dconf/profile/user`<br>`/etc/dconf/db/local.d/00-radxa-no-suspend`<br>`/etc/dconf/db/local.d/01-radxa-no-dpms` |
| 6 | 清理无关的开机 failed 项 | `/etc/systemd/system/load-isp-modules.service.d/10-condition.conf` |
| 7 | `daemon-reload` / `reset-failed` / 按需重启 logind / 套用 tmpfiles | — |

## 四、快速使用

```bash
git clone https://github.com/ctr54188/radxa-o6n-sleep-ssh-fix.git
cd radxa-o6n-sleep-ssh-fix

sudo bash radxa-fix-sleep-ssh.sh          # 标准修复
sudo reboot                               # 重启验证
```

重装系统后同样只用这两条命令。

### 参数

```console
sudo bash radxa-fix-sleep-ssh.sh              # 标准修复（默认顺带关闭自动息屏）
sudo bash radxa-fix-sleep-ssh.sh --keep-dpms  # 保留 GNOME 默认"平时自动息屏"
sudo bash radxa-fix-sleep-ssh.sh --no-desktop # 无桌面 / 最小系统，不碰 GNOME
sudo bash radxa-fix-sleep-ssh.sh --verify     # 只体检、零改动
sudo bash radxa-fix-sleep-ssh.sh --reboot     # 修完自动重启
sudo bash radxa-fix-sleep-ssh.sh -h           # 帮助
```

### 脚本工程特性

- **幂等**：写文件前 `cmp -s` 比对，一致则打印 `[OK]` 不动；重复执行无副作用
- **自动备份**：任何改动前备份到 `/var/backups/radxa-fix/<时间戳>/`，保留目录结构
- **不写死环境**：网卡由默认路由探测、用户/UID/会话类型由 `loginctl` 探测、`runuser` → `sudo` 自动降级
- **安全**：非 root 直接拒绝；`bash -n` 语法检查通过；`--verify` 零改动
- **不做 `set -e`**：单点失败不中断，最后统一汇总并标记异常项

## 五、验证结果

修复后脚本会输出体检表：

```
================ 检查结果 ================
  ssh 开机自启(enable) : enabled
  ssh 当前运行(active) : active
  SSH 监听端口         : 0.0.0.0:22,[::]:22
  挂起能力 CanSuspend  : "na"   (na = 已禁止)
  睡眠服务 mask 状态   : masked
  mem_sleep            : [s2idle] deep
  失败单元             : 无
```

## 六、回滚

所有原始文件都备份在 `/var/backups/radxa-fix/<时间戳>/`，按原路径拷贝回去即可。另外：

```bash
# 恢复自动息屏
gsettings set org.gnome.desktop.session idle-delay 900
rm -f /etc/dconf/db/local.d/01-radxa-no-dpms && dconf update

# 恢复允许挂起（不建议，本机 S3 唤醒有 bug）
systemctl unmask systemd-suspend.service systemd-hibernate.service \
                systemd-hybrid-sleep.service systemd-suspend-then-hibernate.service
```

## 七、适用环境

| 项目 | 值 |
|---|---|
| 硬件 | Radxa Orion O6N (CIX P1) |
| 系统 | Debian GNU/Linux 12 (bookworm) |
| 内核 | `6.6.89-3-sky1` (aarch64) |
| 桌面 | GNOME (Wayland) |

理论上同样适用于其他"GNOME 自动挂起导致睡死"的 Debian 12 设备，非 GNOME 桌面请加 `--no-desktop`。

## License

MIT
