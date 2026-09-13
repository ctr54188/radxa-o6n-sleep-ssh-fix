#!/usr/bin/env bash
#
# radxa-fix-sleep-ssh.sh
# ---------------------------------------------------------------------------
# 用途：
#   一键修复 Radxa Orion O6N (CIX P1 / Debian 12) 上的两个问题：
#     1) 系统会"自动休眠"（进入 S3 deep 后无法唤醒 -> 机器睡死）
#     2) SSH 服务每次开机不自启 / 唤醒后失联，必须人工 systemctl restart ssh
#
# 用法：
#   sudo bash radxa-fix-sleep-ssh.sh              # 标准修复
#   sudo bash radxa-fix-sleep-ssh.sh --keep-dpms  # 保留"平时自动息屏"行为
#   sudo bash radxa-fix-sleep-ssh.sh --no-desktop # 无桌面环境 / 不碰 GNOME 设置
#   sudo bash radxa-fix-sleep-ssh.sh --verify     # 只检查当前状态，不做修改
#   sudo bash radxa-fix-sleep-ssh.sh --reboot     # 修复完自动重启
#
# 特性：
#   * 幂等：重复执行不会重复写入，已正确的项会跳过
#   * 改动前自动备份到 /var/backups/radxa-fix/<时间戳>/
#   * 网络接口 / 桌面用户数 / 会话类型均自动探测，不写死 enp1s0、UID
#
# 适用：Debian 12 (bookworm) 及衍生系统，aarch64 / amd64 通用
# ---------------------------------------------------------------------------

set -uo pipefail

PROG="$(basename "$0")"

# --------------------------------------------------------------------------
# 命令行参数
# --------------------------------------------------------------------------
KEEP_DPMS=0        # 保留息屏
SKIP_DESKTOP=0     # 跳过桌面设置
DO_REBOOT=0        # 结束时重启
VERIFY_ONLY=0      # 只检查
FORCE=0            # 跳过确认

usage() {
    # 打印文件头部的注释块（从第 2 行到第一个空行）作为帮助信息
    sed -n '2,/^$/p' "$0" | sed -n 's/^# *//p'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --keep-dpms)   KEEP_DPMS=1 ;;
        --no-desktop)  SKIP_DESKTOP=1 ;;
        --verify)      VERIFY_ONLY=1 ;;
        --reboot)      DO_REBOOT=1 ;;
        -y|--yes)      FORCE=1 ;;
        -h|--help)     usage 0 ;;
        *) echo "$PROG: 未知参数 '$1'" >&2; usage 1 ;;
    esac
    shift
done

# --------------------------------------------------------------------------
# 输出辅助
# --------------------------------------------------------------------------
if [ -t 1 ]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
    C_B=$'\033[1m';  C_N=$'\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_N=''
fi

step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_N"; }
ok()   { printf '  %s[OK]%s   %s\n'   "$C_G" "$C_N" "$*"; }
chg()  { printf '  %s[改]%s   %s\n'   "$C_Y" "$C_N" "$*"; }
skip() { printf '  %s[跳过]%s %s\n'   "$C_Y" "$C_N" "$*"; }
bad()  { printf '  %s[异常]%s %s\n'   "$C_R" "$C_N" "$*"; }
warn() { printf '  %s[注意]%s %s\n'   "$C_Y" "$C_N" "$*"; }
die()  { printf '\n%s错误：%s%s\n' "$C_R" "$*" "$C_N" >&2; exit 1; }

# --------------------------------------------------------------------------
# 前置检查
# --------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    die "需要 root 权限，请用：sudo bash $PROG"
fi

if ! command -v systemctl >/dev/null 2>&1; then
    die "未找到 systemctl，本脚本仅适用于 systemd 系统"
fi

[ -r /etc/os-release ] && . /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) : ;;
    *) warn "当前系统为 ${PRETTY_NAME:-未知}，脚本按 Debian 系编写，请自行确认" ;;
esac

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/backups/radxa-fix/$STAMP"

# 备份单个文件（保留目录结构）
backup() {
    local f
    for f in "$@"; do
        [ -e "$f" ] || continue
        mkdir -p "$BACKUP_DIR$(dirname "$f")"
        cp -a "$f" "$BACKUP_DIR$f" 2>/dev/null || true
    done
}

# 幂等写文件：内容相同则不动；不同则先备份再写入
# 用法: write_file <路径> [权限] <<'EOF' ... EOF
# 副作用: 真正发生修改时置 WROTE_CHANGES=1
WROTE_CHANGES=0
write_file() {
    local path="$1" mode="${2:-644}" tmp
    tmp="$(mktemp)" || return 1
    cat > "$tmp"
    if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        ok "$path（内容已正确）"
        return 0
    fi
    backup "$path"
    mkdir -p "$(dirname "$path")"
    if install -m "$mode" "$tmp" "$path"; then
        rm -f "$tmp"
        chg "$path"
        WROTE_CHANGES=1
    else
        rm -f "$tmp"
        bad "写入失败：$path"
        return 1
    fi
}

# 以指定用户身份执行命令（runuser 不可用时退回 sudo）
runas() {
    local u="$1"; shift
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$u" -- "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u "$u" -- "$@"
    else
        return 127
    fi
}

# 对某个图形会话设置 gsettings
# 用法: gs_set <uid> <user> <schema> <key> <value>
gs_set() {
    local uid="$1" u="$2"; shift 2
    runas "$u" env "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
                   "XDG_RUNTIME_DIR=/run/user/$uid" \
                   gsettings set "$@" >/dev/null 2>&1
}

# 对某个图形会话恢复 gsettings 默认值
# 用法: gs_reset <uid> <user> <schema> <key>
gs_reset() {
    local uid="$1" u="$2"; shift 2
    runas "$u" env "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
                   "XDG_RUNTIME_DIR=/run/user/$uid" \
                   gsettings reset "$@" >/dev/null 2>&1
}

printf '%s\n' "${C_B}Radxa O6N 自动休眠 / SSH 修复脚本${C_N}"
echo "  主机：$(hostname)    内核：$(uname -r)"
echo "  时间：$(date '+%F %T')"
[ "$VERIFY_ONLY" -eq 1 ] && echo "  模式：${C_Y}只检查，不修改${C_N}"
[ -d "$BACKUP_DIR" ] || mkdir -p "$BACKUP_DIR" 2>/dev/null
echo "  备份：$BACKUP_DIR"

if [ "$VERIFY_ONLY" -eq 0 ] && [ "$FORCE" -eq 0 ] && [ -t 0 ]; then
    printf '\n按回车开始修复，Ctrl-C 取消 ... '
    read -r _ || true
fi

# ==========================================================================
# 1) SSH 服务：安装（如缺）+ 开机自启
# ==========================================================================
step "1/7  SSH 服务：安装与开机自启"

SSHD_BIN=""
for b in /usr/sbin/sshd /usr/local/sbin/sshd; do
    [ -x "$b" ] && SSHD_BIN="$b" && break
done

if [ -z "$SSHD_BIN" ]; then
    if [ "$VERIFY_ONLY" -eq 1 ]; then
        bad "未安装 openssh-server"
    else
        warn "未安装 openssh-server，尝试安装 ..."
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
        fi
        for b in /usr/sbin/sshd /usr/local/sbin/sshd; do
            [ -x "$b" ] && SSHD_BIN="$b" && break
        done
        [ -n "$SSHD_BIN" ] && ok "已安装 openssh-server" || bad "openssh-server 安装失败，请手动处理"
    fi
else
    ok "sshd 已安装：$SSHD_BIN"
fi

if [ -f /etc/ssh/sshd_not_to_be_run ]; then
    if [ "$VERIFY_ONLY" -eq 0 ]; then
        backup /etc/ssh/sshd_not_to_be_run
        mv /etc/ssh/sshd_not_to_be_run "$BACKUP_DIR/etc/ssh/sshd_not_to_be_run" 2>/dev/null || \
            rm -f /etc/ssh/sshd_not_to_be_run
        chg "移除 /etc/ssh/sshd_not_to_be_run（该文件会阻止 sshd 启动）"
    else
        bad "存在 /etc/ssh/sshd_not_to_be_run，sshd 不会被启动"
    fi
fi

if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    if [ "$VERIFY_ONLY" -eq 0 ]; then
        if [ "$(systemctl is-enabled ssh 2>/dev/null)" != "enabled" ]; then
            systemctl enable ssh >/dev/null 2>&1 && chg "systemctl enable ssh （开机自启）" \
                                                 || bad "systemctl enable ssh 失败"
        else
            ok "ssh.service 已是 enabled"
        fi
        if [ "$(systemctl is-active ssh 2>/dev/null)" != "active" ]; then
            systemctl start ssh >/dev/null 2>&1 && chg "已启动 ssh.service" || bad "启动 ssh 失败"
        else
            ok "ssh.service 正在运行"
        fi
    else
        printf '  ssh is-enabled / is-active : %s / %s\n' \
               "$(systemctl is-enabled ssh 2>&1)" "$(systemctl is-active ssh 2>&1)"
    fi
else
    bad "系统中找不到 ssh.service 单元"
fi

# 语法自检
if [ -n "$SSHD_BIN" ]; then
    if "$SSHD_BIN" -t 2>/dev/null; then
        ok "sshd_config 语法检查通过"
    else
        bad "sshd_config 语法有误：$("$SSHD_BIN" -t 2>&1 | head -3)"
    fi
fi

# ==========================================================================
# 2) sshd 被杀死/唤醒后自动拉起
# ==========================================================================
step "2/7  sshd 崩溃或异常退出后自动拉起"

if [ "$VERIFY_ONLY" -eq 0 ]; then
    write_file /etc/systemd/system/ssh.service.d/10-restart.conf <<'EOF'
[Service]
# 任何退出原因（包括 255）都自动重新拉起 sshd
Restart=always
RestartSec=3
RestartPreventExitStatus=
EOF
else
    printf '  Restart=%s  RestartUSec=%s  RestartPreventExitStatus=%s\n' \
        "$(systemctl show ssh -p Restart --value 2>/dev/null)" \
        "$(systemctl show ssh -p RestartUSec --value 2>/dev/null)" \
        "$(systemctl show ssh -p RestartPreventExitStatus --value 2>/dev/null)"
fi

# ==========================================================================
# 3) 彻底禁止休眠 / 挂起（四层保险）
# ==========================================================================
step "3/7  彻底禁止自动休眠 / 挂起"

if [ "$VERIFY_ONLY" -eq 0 ]; then

    # --- 3.1 logind：忽略空闲、挂起键、合盖 ---
    WROTE_CHANGES=0
    write_file /etc/systemd/logind.conf.d/99-disable-sleep.conf <<'EOF'
[Login]
# 忽略挂起 / 休眠按键
HandleSuspendKey=ignore
HandleHibernateKey=ignore
# 忽略合盖动作
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
# 空闲不做任何动作
IdleAction=ignore
EOF
    LOGIND_CHANGED=$WROTE_CHANGES

    # --- 3.2 sleep.conf：拒绝一切睡眠动作 ---
    write_file /etc/systemd/sleep.conf.d/99-disable-sleep.conf <<'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
EOF

    # --- 3.3 mask 掉睡眠服务：任何程序调用都会被拒绝 ---
    sleep_units="systemd-suspend.service systemd-hibernate.service \
                 systemd-hybrid-sleep.service systemd-suspend-then-hibernate.service"
    for u in $sleep_units; do
        if [ "$(systemctl is-enabled "$u" 2>/dev/null)" = "masked" ]; then
            ok "$u 已是 masked"
        else
            systemctl mask "$u" >/dev/null 2>&1 && chg "masked $u" || warn "$u mask 失败"
        fi
    done

    # --- 3.4 强制走 s2idle（本机 deep/S3 唤醒有 bug） ---
    write_file /etc/tmpfiles.d/99-power.conf <<'EOF'
# 优先使用 s2idle，避免 deep(S3) 唤醒失败导致"睡死"
w /sys/power/mem_sleep - - - - s2idle
EOF
    if [ -w /sys/power/mem_sleep ]; then
        echo s2idle > /sys/power/mem_sleep 2>/dev/null || true
        ok "当前 mem_sleep = $(cat /sys/power/mem_sleep 2>/dev/null)"
    fi

else
    printf '  CanSuspend   : %s\n' "$(dbus-send --system --print-reply \
        --dest=org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager.CanSuspend 2>/dev/null | tail -1 | sed 's/.*string //')"
    printf '  CanHibernate : %s\n' "$(dbus-send --system --print-reply \
        --dest=org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager.CanHibernate 2>/dev/null | tail -1 | sed 's/.*string //')"
    printf '  systemd-suspend.service : %s\n' "$(systemctl is-enabled systemd-suspend.service 2>&1)"
    printf '  mem_sleep    : %s\n' "$(cat /sys/power/mem_sleep 2>/dev/null)"
fi

# ==========================================================================
# 4) 万一真睡了：唤醒后自动恢复网络与 sshd
# ==========================================================================
step "4/7  唤醒(resume)后自动恢复网络与 sshd"

if [ "$VERIFY_ONLY" -eq 0 ]; then
    write_file /etc/systemd/system-sleep/50-restart-ssh.sh 755 <<'EOF'
#!/bin/sh
# systemd-sleep hook：在唤醒后重新拉起网络与 sshd
# 作者: radxa-fix-sleep-ssh.sh
case "$1" in
    post)
        logger -t radxa-resume "resume: 正在恢复网络与 sshd"
        # 重新连接默认路由所在网卡的连接
        if command -v nmcli >/dev/null 2>&1; then
            for dev in $(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | sort -u); do
                nmcli device connect "$dev" >/dev/null 2>&1
            done
            nmcli networking on >/dev/null 2>&1
        fi
        systemctl restart ssh >/dev/null 2>&1
        logger -t radxa-resume "resume: 恢复完成"
        ;;
esac
exit 0
EOF
else
    if [ -x /etc/systemd/system-sleep/50-restart-ssh.sh ]; then
        ok "resume hook 已存在"
    else
        bad "resume hook 缺失"
    fi
fi

# ==========================================================================
# 5) 桌面层（GNOME）：禁止自动挂起 / 息屏
# ==========================================================================
step "5/7  桌面层设置（GNOME 自动挂起 / 息屏）"

if [ "$SKIP_DESKTOP" -eq 1 ]; then
    skip "已指定 --no-desktop"
else
    # --- 5.1 系统级默认值（对所有用户、以后新建用户都生效） ---
    if command -v dconf >/dev/null 2>&1; then
        if [ "$VERIFY_ONLY" -eq 0 ]; then
            write_file /etc/dconf/profile/user 644 <<'EOF'
user-db:user
system-db:local
EOF
            write_file /etc/dconf/db/local.d/00-radxa-no-suspend 644 <<'EOF'
# 由 radxa-fix-sleep-ssh.sh 写入：禁止自动挂起
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0
EOF

            # 息屏（DPMS）：默认一并关闭；--keep-dpms 时撤销该文件
            DPMS_FILE=/etc/dconf/db/local.d/01-radxa-no-dpms
            if [ "$KEEP_DPMS" -eq 0 ]; then
                write_file "$DPMS_FILE" 644 <<'EOF'
# 由 radxa-fix-sleep-ssh.sh 写入：不自动息屏
# 息屏本身不会断开 SSH，这里只是避免被误认为"休眠"
# 想恢复自动息屏：删除本文件后执行 dconf update，或 gsettings set org.gnome.desktop.session idle-delay 900
[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
idle-activation-enabled=false
EOF
            elif [ -f "$DPMS_FILE" ]; then
                backup "$DPMS_FILE"
                rm -f "$DPMS_FILE"
                chg "已移除 $DPMS_FILE（--keep-dpms：保留自动息屏）"
            else
                skip "--keep-dpms：保留自动息屏"
            fi

            if dconf update >/dev/null 2>&1; then
                ok "已写入系统级 dconf 默认值并执行 dconf update"
            else
                bad "dconf update 失败，系统级默认值可能未生效"
            fi
        else
            printf '  系统级 dconf : %s\n' \
                "$([ -f /etc/dconf/db/local ] && echo 已编译 || echo 未生成)"
        fi
    else
        skip "未安装 dconf 命令，跳过系统级设置"
    fi

    # --- 5.2 对当前已登录的图形会话立即生效 ---
    applied=0
    while read -r sid uid uname _rest; do
        [ -n "${sid:-}" ] || continue
        case "$uid" in ''|*[!0-9]*) continue ;; esac
        stype="$(loginctl show-session "$sid" -p Type --value 2>/dev/null)"
        case "$stype" in
            x11|wayland) ;;
            *) continue ;;
        esac
        [ -S "/run/user/$uid/bus" ] || continue
        [ "$VERIFY_ONLY" -eq 1 ] && { printf '  会话 %s (%s, %s) 使用中\n' "$sid" "$uname" "$stype"; continue; }

        gs_set "$uid" "$uname" org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type        'nothing'
        gs_set "$uid" "$uname" org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type   'nothing'
        gs_set "$uid" "$uname" org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout     0
        gs_set "$uid" "$uname" org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 0
        if [ "$KEEP_DPMS" -eq 0 ]; then
            gs_set   "$uid" "$uname" org.gnome.desktop.session idle-delay 0
            gs_set   "$uid" "$uname" org.gnome.desktop.screensaver idle-activation-enabled false
        else
            # --keep-dpms：把息屏相关项恢复为 GNOME 默认（正常自动息屏）
            gs_reset "$uid" "$uname" org.gnome.desktop.session idle-delay
            gs_reset "$uid" "$uname" org.gnome.desktop.screensaver idle-activation-enabled
        fi
        ok "已对图形会话立即生效：$uname (session $sid, $stype)"
        applied=$((applied + 1))
    done < <(loginctl list-sessions --no-legend --no-pager 2>/dev/null)

    [ "$applied" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ] && \
        skip "当前没有图形会话；系统级默认值会在下次登录时生效"
fi

# ==========================================================================
# 6) 顺手清理无关的开机失败项
# ==========================================================================
step "6/7  清理常见开机失败项"

if systemctl list-unit-files load-isp-modules.service >/dev/null 2>&1; then
    if [ "$VERIFY_ONLY" -eq 0 ]; then
        write_file /etc/systemd/system/load-isp-modules.service.d/10-condition.conf <<'EOF'
[Unit]
# 内核模块不存在时跳过，避免每次开机出现 failed（与当前运行内核不匹配时）
ConditionPathExists=/lib/modules/%v/extra/armcb_isp_v4l2.ko
EOF
    else
        printf '  load-isp-modules : %s\n' "$(systemctl is-active load-isp-modules.service 2>&1)"
    fi
else
    skip "无 load-isp-modules.service"
fi

# ==========================================================================
# 7) 重新加载 systemd 并汇总
# ==========================================================================
step "7/7  重新加载配置"

if [ "$VERIFY_ONLY" -eq 0 ]; then
    systemctl daemon-reload && ok "systemd daemon-reload"
    systemctl reset-failed 2>/dev/null || true

    # 重启 logind 以立即套用 logind.conf.d（仅当配置真的变了）
    if [ "${LOGIND_CHANGED:-0}" = "1" ]; then
        if systemctl restart systemd-logind >/dev/null 2>&1; then
            ok "已重启 systemd-logind（配置立即生效）"
        else
            warn "systemd-logind 重启失败，配置将在下次重启后生效"
        fi
    else
        ok "logind 配置无变化，无需重启"
    fi

    # 让 tmpfiles 立即套用 mem_sleep
    systemd-tmpfiles --create /etc/tmpfiles.d/99-power.conf >/dev/null 2>&1 || true
fi

# --------------------------------------------------------------------------
# 结果汇总
# --------------------------------------------------------------------------
echo
printf '%s================ 检查结果 ================%s\n' "$C_B" "$C_N"

if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    e="$(systemctl is-enabled ssh 2>&1)"; a="$(systemctl is-active ssh 2>&1)"
    printf '  ssh 开机自启(enable) : %s\n' "$e"
    printf '  ssh 当前运行(active) : %s\n' "$a"
    printf '  SSH 监听端口         : %s\n' \
        "$(ss -tlnH 2>/dev/null | awk '$4 ~ /:22$/ {print $4}' | paste -sd, - | sed 's/^$/ 未监听/')"
    [ "$e" = "enabled" ] && [ "$a" = "active" ] || bad_line=1
fi

cs="$(dbus-send --system --print-reply --dest=org.freedesktop.login1 \
      /org/freedesktop/login1 org.freedesktop.login1.Manager.CanSuspend 2>/dev/null \
      | tail -1 | sed 's/.*string //')"
printf '  挂起能力 CanSuspend  : %s   (na = 已禁止)\n' "${cs:-未知}"
printf '  睡眠服务 mask 状态   : %s\n' "$(systemctl is-enabled systemd-suspend.service 2>&1)"
printf '  mem_sleep            : %s\n' "$(cat /sys/power/mem_sleep 2>/dev/null)"
printf '  失败单元             : '
f="$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{print $1}' | paste -sd' ' -)"
printf '%s\n' "${f:-无}"
echo "  备份目录             : $BACKUP_DIR"

echo
if [ "${bad_line:-0}" = "1" ]; then
    printf '%s 仍有项目未通过，请查看上面的 [异常] 行%s\n' "$C_R" "$C_N"
else
    printf '%s 修复完成。%s\n' "$C_G" "$C_N"
fi
if [ "$VERIFY_ONLY" -eq 0 ]; then
    echo "  建议重启一次以完整验证：sudo reboot"
    echo "  重启后应能直接 SSH 登录，且系统不再自动休眠。"
    if [ "$KEEP_DPMS" -eq 1 ]; then
        echo
        echo "  当前为 --keep-dpms：保留 GNOME 默认的自动息屏（不影响 SSH 连接）。"
    else
        echo
        echo "  如需恢复「平时自动息屏」（不影响 SSH 连接）："
        echo "    gsettings set org.gnome.desktop.session idle-delay 900"
        echo "  或删除 /etc/dconf/db/local.d/01-radxa-no-dpms 后执行 dconf update"
    fi
fi

if [ "$DO_REBOOT" -eq 1 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
    echo
    warn "--reboot 已指定，10 秒后重启（Ctrl-C 取消）"
    sleep 10
    systemctl reboot
fi

exit 0
