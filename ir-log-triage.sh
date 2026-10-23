#!/bin/sh
# =====================================================================
#  ir-log-triage.sh  --  应急响应 / 安全加固 日志自动分析
#  只读脚本: 不修改被检查主机的任何文件
#  默认仅屏幕输出; -o DIR 生成 Markdown 报告
#  兼容: Debian/Ubuntu, RHEL/CentOS/Rocky/Alma, SUSE, Alpine (busybox)
# =====================================================================
VERSION="1.0.0"

DAYS=7
OUTDIR=""
QUICK=0
NOCOLOR=0
MAXLINES=200000
CH=0
CW=0
CI=0

usage() {
  cat <<'EOF'
用法: sh ir-log-triage.sh [选项]

  -o DIR    生成报告到 DIR (默认只打印到屏幕, 不落任何文件)
  -d DAYS   分析时间窗口, 单位天 (默认 7)
  -q        快速模式: 跳过耗时的大目录遍历
  -n        关闭颜色
  -h        显示帮助

说明: 本脚本只读, 不会修改被检查主机。建议 root 运行, 否则部分日志不可读。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift; OUTDIR="$1" ;;
    -d) shift; DAYS="$1" ;;
    -q) QUICK=1 ;;
    -n) NOCOLOR=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

case "$DAYS" in
  ''|*[!0-9]*) echo "错误: -d 需要正整数" >&2; exit 2 ;;
esac

if [ -t 1 ] && [ "$NOCOLOR" -eq 0 ]; then
  C_R=$(printf '\033[31m'); C_Y=$(printf '\033[33m')
  C_G=$(printf '\033[32m'); C_B=$(printf '\033[36m'); C_0=$(printf '\033[0m')
else
  C_R=""; C_Y=""; C_G=""; C_B=""; C_0=""
fi

FENCE_OPEN=0
REPORT=""
if [ -n "$OUTDIR" ]; then
  mkdir -p "$OUTDIR" 2>/dev/null || { echo "错误: 无法创建目录 $OUTDIR" >&2; exit 1; }
  REPORT="$OUTDIR/irtriage_$(hostname 2>/dev/null || echo host)_$(date +%Y%m%d_%H%M%S).md"
  : > "$REPORT" 2>/dev/null || { echo "错误: 无法写入 $REPORT" >&2; exit 1; }
fi

p() {
  printf '%s\n' "$*"
  [ -n "$REPORT" ] && printf '%s\n' "$*" >> "$REPORT"
}

h1() {
  p ""
  if [ -n "$REPORT" ]; then
    [ "$FENCE_OPEN" = "1" ] && p '```'
    p "## $*"
    p ""
    p '```text'
    FENCE_OPEN=1
  else
    p "$C_B==================================================================$C_0"
    p "$C_B $*$C_0"
    p "$C_B==================================================================$C_0"
  fi
}

h2() {
  p ""
  if [ -n "$REPORT" ]; then
    [ "$FENCE_OPEN" = "1" ] && p '```'
    p "### $*"
    p ""
    p '```text'
    FENCE_OPEN=1
  else
    p "$C_B--- $* ---$C_0"
  fi
}

ok()   { p "  [OK]   $*"; CI=$((CI+1)); }
warn() { p "  $C_Y[注意]$C_0 $*"; CW=$((CW+1)); }
crit() { p "  $C_R[高危]$C_0 $*"; CH=$((CH+1)); }
info() { p "         $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

readfile() {
  case "$1" in
    *.gz) gzip -dc "$1" 2>/dev/null ;;
    *.bz2) bzip2 -dc "$1" 2>/dev/null ;;
    *.xz) xz -dc "$1" 2>/dev/null ;;
    *) cat "$1" 2>/dev/null ;;
  esac
}

tailed() { readfile "$1" | tail -n "$MAXLINES"; }

find_logs() {
  _pat="$1"
  shift
  for _d in "$@"; do
    [ -d "$_d" ] || continue
    for _f in "$_d"/$_pat; do
      [ -f "$_f" ] && printf '%s\n' "$_f"
    done
  done
}

WEBLOG_DIRS="/var/log/nginx /var/log/apache2 /var/log/httpd /var/log/apache /usr/local/nginx/logs /usr/local/apache/logs /opt/nginx/logs /www/wwwlogs /data/wwwlogs /var/log/caddy"
TOMCAT_DIRS="/opt/tomcat/logs /usr/local/tomcat/logs /usr/share/tomcat/logs /var/log/tomcat /var/lib/tomcat/logs"

# =====================================================================
h1 "应急响应日志分析  v$VERSION"
p "  生成时间 : $(date '+%Y-%m-%d %H:%M:%S %Z')"
p "  分析窗口 : 最近 $DAYS 天"
if [ "$QUICK" -eq 1 ]; then p "  模式     : 快速"; else p "  模式     : 完整"; fi
[ -n "$REPORT" ] && p "  报告文件 : $REPORT"
if [ "$(id -u 2>/dev/null)" != "0" ]; then
  warn "当前非 root, 部分日志/进程信息不可读, 建议 sudo 运行"
fi

# =====================================================================
h1 "1. 系统基本信息"
OSNAME="未知"
if [ -r /etc/os-release ]; then
  OSNAME=$(. /etc/os-release 2>/dev/null; printf '%s' "$PRETTY_NAME")
  [ -z "$OSNAME" ] && OSNAME="未知"
elif [ -r /etc/redhat-release ]; then
  OSNAME=$(cat /etc/redhat-release)
elif [ -r /etc/alpine-release ]; then
  OSNAME="Alpine $(cat /etc/alpine-release)"
fi
p "  发行版   : $OSNAME"
p "  主机名   : $(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null)"
p "  内核     : $(uname -sr)"
p "  架构     : $(uname -m)"
[ -r /etc/machine-id ] && p "  machine-id: $(cat /etc/machine-id)"
p "  运行时长 : $(uptime 2>/dev/null | sed 's/^ *//')"
p "  当前用户 : $(id 2>/dev/null)"
if have timedatectl; then
  SYNC=$(timedatectl 2>/dev/null | grep -i 'synchronized' | tr -s ' ')
  [ -n "$SYNC" ] && p "  时间同步 :$SYNC"
fi

# =====================================================================
h1 "2. 账号与登录审计"

h2 "2.1 UID 0 账号 / 异常账号"
Z0=$(awk -F: '$3==0 {print $1}' /etc/passwd 2>/dev/null | tr '\n' ' ')
p "  UID=0    : $Z0"
for u in $Z0; do
  [ "$u" = "root" ] || crit "存在非 root 的 UID 0 账号: $u"
done
LOGINABLE=$(grep -vE '/(nologin|false|sync|shutdown|halt)$' /etc/passwd 2>/dev/null | wc -l)
p "  可登录账号数: $LOGINABLE"
EMPTY_PW=$(awk -F: '($2==""){print $1}' /etc/shadow 2>/dev/null | tr '\n' ' ')
[ -n "$EMPTY_PW" ] && crit "存在空密码账号: $EMPTY_PW"

h2 "2.2 sudo 权限"
NOPASS=$(grep -rhE 'NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | grep -v '^#' | head -10)
if [ -n "$NOPASS" ]; then
  p "  免密 sudo 条目:"
  printf '%s\n' "$NOPASS" | while read -r l; do p "    $l"; done
else
  ok "未发现 NOPASSWD 条目"
fi

h2 "2.3 SSH 授权公钥"
AK_FOUND=0
for h in /root /home/*; do
  [ -f "$h/.ssh/authorized_keys" ] || continue
  AK_FOUND=1
  AKN=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$h/.ssh/authorized_keys" 2>/dev/null)
  p "  $h/.ssh/authorized_keys : $AKN 个公钥"
  awk '/^(ssh-|ecdsa-|sk-)/ {print "      " $1 " ... " $NF}' "$h/.ssh/authorized_keys" 2>/dev/null | head -5 | while read -r l; do p "$l"; done
done
[ "$AK_FOUND" -eq 0 ] && ok "未找到 authorized_keys"

h2 "2.4 登录失败统计 (auth.log / secure)"
AUTH_FILES=""
for f in /var/log/auth.log /var/log/secure /var/log/auth.log.1; do
  [ -f "$f" ] && AUTH_FILES="$AUTH_FILES $f"
done
SECROT=$(ls /var/log/secure-* /var/log/auth.log.* 2>/dev/null | head -3)
[ -n "$SECROT" ] && AUTH_FILES="$AUTH_FILES $SECROT"

if [ -z "$AUTH_FILES" ]; then
  warn "未找到 auth.log / secure"
  if have journalctl; then
    JN=$(journalctl --since "-$DAYS days" -u sshd -u ssh 2>/dev/null | grep -ciE 'failed|invalid user')
    p "  journald 中 sshd 失败事件: $JN"
    [ "$JN" -gt 0 ] && warn "存在登录失败事件, 建议单独分析 journalctl"
  fi
else
  FAILN=0
  for f in $AUTH_FILES; do
    C=$(grep -acE 'Failed password|authentication failure' "$f" 2>/dev/null)
    case "$C" in ''|*[!0-9]*) C=0 ;; esac
    FAILN=$((FAILN + C))
  done
  p "  失败登录总数: $FAILN"
  if [ "$FAILN" -gt 0 ]; then
    if [ "$FAILN" -ge 100 ]; then crit "失败登录次数偏高: $FAILN"; else warn "存在失败登录: $FAILN"; fi
    p "  失败来源 TOP5:"
    cat $AUTH_FILES 2>/dev/null | grep -aE 'Failed password|authentication failure' | grep -aoE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort | uniq -c | sort -rn | head -5 | while read -r c ip; do p "    $c 次  $ip"; done
  else
    ok "未发现失败登录记录"
  fi
  ACC=$(cat $AUTH_FILES 2>/dev/null | grep -ac 'Accepted')
  p "  成功登录次数: $ACC"
  if [ "$ACC" -gt 0 ]; then
    p "  登录来源 TOP5:"
    cat $AUTH_FILES 2>/dev/null | grep -a 'Accepted' | grep -aoE 'from ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}' | sort | uniq -c | sort -rn | head -5 | while read -r c ip; do p "    $c 次  $ip"; done
  fi
fi

h2 "2.5 最近登录记录"
if have last; then
  last -n 10 2>/dev/null | head -11 | while read -r l; do p "  $l"; done
else
  info "无 last 命令"
fi
if [ -r /var/log/btmp ] && have lastb; then
  p "  失败登录 (lastb):"
  lastb -n 5 2>/dev/null | head -6 | while read -r l; do p "  $l"; done
fi

# =====================================================================
h1 "3. 进程与网络连接"

h2 "3.1 监听端口"
if have ss; then
  ss -lntup 2>/dev/null | head -40 | while read -r l; do p "  $l"; done
elif have netstat; then
  netstat -lntup 2>/dev/null | head -40 | while read -r l; do p "  $l"; done
else
  info "无 ss / netstat"
fi

h2 "3.2 异常进程映像 (/tmp /var/tmp /dev/shm, 已删除可执行文件)"
NPROC=0
for pe in /proc/[0-9]*/exe; do
  [ -e "$pe" ] || continue
  TGT=$(readlink "$pe" 2>/dev/null) || continue
  PID=$(printf '%s' "$pe" | cut -d/ -f3)
  case "$TGT" in
    /tmp/*|/var/tmp/*|/dev/shm/*)
      crit "进程 $PID 从临时目录运行: $TGT"
      NPROC=$((NPROC+1))
      ;;
    *"(deleted)")
      case "$TGT" in
        /tmp/*|/var/tmp/*|/dev/shm/*)
          crit "进程 $PID 从临时目录运行且映像已删除: $TGT"
          NPROC=$((NPROC+1))
          ;;
        /usr/*|/lib/*|/lib64/*|/bin/*|/sbin/*|/opt/*|/snap/*)
          warn "进程 $PID 的映像已删除 (常见于软件包升级后未重启): $TGT"
          ;;
        *)
          crit "进程 $PID 的映像已删除且路径异常: $TGT"
          NPROC=$((NPROC+1))
          ;;
      esac
      ;;
  esac
done
[ "$NPROC" -eq 0 ] && ok "未发现从临时目录运行或映像已删除的进程"

h2 "3.3 高占用进程"
if ps -eo pid,pcpu,pmem,comm --sort=-pcpu >/dev/null 2>&1; then
  ps -eo pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -8 | while read -r l; do p "  $l"; done
else
  ps aux 2>/dev/null | head -9 | while read -r l; do p "  $l"; done
fi

# =====================================================================
h1 "4. 持久化痕迹"

h2 "4.1 计划任务"
CRONFOUND=0
if have crontab; then
  U=$(crontab -l 2>/dev/null | grep -vE '^#|^$' | head -10)
  if [ -n "$U" ]; then
    CRONFOUND=1
    p "  当前用户 crontab:"
    printf '%s\n' "$U" | while read -r l; do p "    $l"; done
  fi
fi
for f in /etc/crontab /etc/cron.d/* /var/spool/cron/* /var/spool/cron/crontabs/*; do
  [ -f "$f" ] || continue
  L=$(grep -vE '^#|^$' "$f" 2>/dev/null | head -5)
  [ -z "$L" ] && continue
  CRONFOUND=1
  p "  $f:"
  printf '%s\n' "$L" | while read -r l; do p "    $l"; done
done
[ "$CRONFOUND" -eq 0 ] && ok "计划任务中无自定义条目"

h2 "4.2 systemd 单元 (近 $DAYS 天变更)"
if have systemctl; then
  S=$(find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system -maxdepth 2 -name '*.service' -mtime -"$DAYS" 2>/dev/null | head -10)
  if [ -n "$S" ]; then
    warn "发现近期变更的 service 单元:"
    printf '%s\n' "$S" | while read -r l; do p "    $l"; done
  else
    ok "近 $DAYS 天无新增/变更的 service 单元"
  fi
else
  info "无 systemd"
fi

h2 "4.3 动态链接器预加载 / 启动脚本"
if [ -f /etc/ld.so.preload ]; then
  PL=$(grep -vE '^#|^$' /etc/ld.so.preload 2>/dev/null)
  if [ -n "$PL" ]; then
    crit "/etc/ld.so.preload 非空 (常见 rootkit 手法)"
    printf '%s\n' "$PL" | while read -r l; do p "    $l"; done
  else
    ok "/etc/ld.so.preload 存在但为空"
  fi
else
  ok "无 /etc/ld.so.preload"
fi
for f in /etc/rc.local /etc/rc.d/rc.local; do
  [ -f "$f" ] || continue
  p "  $f:"
  grep -vE '^#|^$|^exit 0' "$f" 2>/dev/null | head -5 | while read -r l; do p "    $l"; done
done
for f in /etc/profile.d/*.sh; do
  [ -f "$f" ] || continue
  if grep -qE 'curl |wget |base64 -d|/dev/tcp' "$f" 2>/dev/null; then
    warn "启动脚本含可疑下载/网络命令: $f"
    grep -nE 'curl |wget |base64 -d|/dev/tcp' "$f" 2>/dev/null | head -3 | while read -r l; do p "    $l"; done
  fi
done

h2 "4.4 SSH 配置风险项"
if [ -r /etc/ssh/sshd_config ]; then
  grep -qiE '^[[:space:]]*PermitRootLogin[[:space:]]+yes' /etc/ssh/sshd_config && warn "sshd 允许 root 直接登录"
  grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' /etc/ssh/sshd_config && info "sshd 允许密码登录"
  grep -iE '^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)' /etc/ssh/sshd_config 2>/dev/null | head -6 | while read -r l; do p "    $l"; done
else
  info "无 sshd_config"
fi

# =====================================================================
h1 "5. 可疑文件与 web 目录"

h2 "5.1 临时目录中的可执行文件"
TFOUND=0
for d in /tmp /var/tmp /dev/shm; do
  [ -d "$d" ] || continue
  L=$(find "$d" -maxdepth 3 -type f -perm -u+x -mtime -"$DAYS" 2>/dev/null | grep -vE '\.X11-unix|\.X[0-9]+-lock|ir-log-triage|/go-build[0-9]+/' | head -10)
  if [ -n "$L" ]; then
    TFOUND=1
    warn "$d 中近期可执行文件:"
    printf '%s\n' "$L" | while read -r f; do
      SZ2=$(ls -l "$f" 2>/dev/null | awk '{print $5}')
      p "    $f  ($SZ2 bytes)"
    done
  fi
done
[ "$TFOUND" -eq 0 ] && ok "临时目录无近期可执行文件"

h2 "5.2 近期变更的页面/脚本文件"
if [ "$QUICK" -eq 0 ]; then
  ROOTS=""
  for d in /var/www /var/www/html /usr/share/nginx/html /www/wwwroot /srv/www /data/www /opt/lampp/htdocs; do
    [ -d "$d" ] && ROOTS="$ROOTS $d"
  done
  if [ -z "$ROOTS" ]; then
    info "未找到常见 web 根目录"
  else
    for d in $ROOTS; do
      L=$(find "$d" -maxdepth 4 -type f \( -name '*.php' -o -name '*.jsp' -o -name '*.jspx' -o -name '*.asp' -o -name '*.aspx' \) -mtime -"$DAYS" 2>/dev/null | head -15)
      if [ -n "$L" ]; then
        warn "$d 下近期变更的可执行页面:"
        printf '%s\n' "$L" | while read -r f; do p "    $f"; done
      fi
    done
  fi
else
  info "快速模式: 跳过 web 根目录遍历"
fi

h2 "5.3 webshell 特征代码"
if [ "$QUICK" -eq 0 ]; then
  HIT=0
  for d in /var/www /var/www/html /usr/share/nginx/html /www/wwwroot /srv/www; do
    [ -d "$d" ] || continue
    R=$(grep -rlE 'eval[[:space:]]*\([[:space:]]*[$]_(POST|GET|REQUEST)|assert[[:space:]]*\([[:space:]]*[$]_(POST|GET)|base64_decode[[:space:]]*\([[:space:]]*[$]_(POST|GET)|system[[:space:]]*\([[:space:]]*[$]_|passthru[[:space:]]*\([[:space:]]*[$]_|shell_exec[[:space:]]*\([[:space:]]*[$]_' "$d" --include='*.php' 2>/dev/null | head -5)
    if [ -n "$R" ]; then
      HIT=1
      crit "$d 中发现 webshell 特征代码:"
      printf '%s\n' "$R" | while read -r f; do p "    $f"; done
    fi
  done
  [ "$HIT" -eq 0 ] && ok "常见 webshell 特征未命中"
else
  info "快速模式: 跳过 webshell 内容扫描"
fi

# =====================================================================
h1 "6. Web 访问日志分析"

WEB_LOGS=$(find_logs "*access*.log*" $WEBLOG_DIRS; find_logs "*access_log*" $WEBLOG_DIRS)
WEB_LOGS=$(printf '%s\n' "$WEB_LOGS" | grep -vE '^$' | sort -u | head -12)

if [ -z "$WEB_LOGS" ]; then
  WEBSVC=0
  if have ss; then
    ss -lnt 2>/dev/null | grep -qE ':(80|443|8080|8000|8888) ' && WEBSVC=1
  fi
  if [ "$WEBSVC" -eq 1 ]; then
    warn "有 web 端口在监听, 但未找到访问日志 (可能写往他处或未开 access_log)"
  else
    info "本机未运行 web 服务, 跳过访问日志分析"
  fi
  info "已查找: $WEBLOG_DIRS"
else
  WI=0
  for f in $WEB_LOGS; do
    WI=$((WI+1))
    SZ=$(ls -l "$f" 2>/dev/null | awk '{print $5}')
    LINES=$(tailed "$f" | wc -l)
    h2 "6.$WI $f ($SZ bytes, 末 $LINES 行)"
    if [ "$LINES" -eq 0 ]; then info "空文件"; continue; fi

    p "  请求来源 TOP5:"
    tailed "$f" | awk '{print $1}' | grep -E '^[0-9a-fA-F.:]+$' | sort | uniq -c | sort -rn | head -5 | while read -r c ip; do p "    $c 次  $ip"; done

    p "  状态码分布:"
    tailed "$f" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[1-5][0-9][0-9]$/){print $i; break}}' | sort | uniq -c | sort -rn | head -6 | while read -r c code; do p "    $code : $c"; done

    p "  User-Agent TOP5:"
    tailed "$f" | awk -F'"' 'NF>=6 {print $6}' | grep -v '^$' | sort | uniq -c | sort -rn | head -5 | while read -r c ua; do p "    $c  $ua"; done

    SCAN=$(tailed "$f" | grep -aciE 'sqlmap|nikto|nmap|masscan|zgrab|gobuster|dirbuster|nuclei|acunetix|awvs|xray|wpscan|hydra')
    if [ "$SCAN" -gt 0 ]; then warn "扫描器特征命中 $SCAN 次"; else ok "未见常见扫描器 UA"; fi

    SQ=$(tailed "$f" | grep -aciE 'union[[:space:]]+select|information_schema|sleep\([0-9]|benchmark\(|extractvalue\(')
    TR=$(tailed "$f" | grep -acE '\.\./|%2e%2e|/etc/passwd|/etc/shadow')
    RCE=$(tailed "$f" | grep -aciE 'cmd=|exec=|shell=|passthru|base64_decode|php://input|/bin/(ba)?sh')
    WS=$(tailed "$f" | grep -aciE '\.(php|jsp|asp|aspx)[^ ]*\?(cmd|exec|shell|pass|key)=')
    p "  攻击特征统计:"
    p "    SQL 注入特征  : $SQ"
    p "    路径穿越特征  : $TR"
    p "    命令执行特征  : $RCE"
    p "    webshell 访问 : $WS"
    [ "$SQ" -gt 0 ] && crit "疑似 SQL 注入尝试 ($SQ 次)"
    [ "$TR" -gt 0 ] && crit "疑似路径穿越尝试 ($TR 次)"
    [ "$RCE" -gt 0 ] && crit "疑似命令执行尝试 ($RCE 次)"
    [ "$WS" -gt 0 ] && crit "疑似 webshell 访问 ($WS 次)"

    SAMPLE=$(tailed "$f" | grep -aiE 'union[[:space:]]+select|\.\./|/etc/passwd|cmd=|base64_decode|php://input' | head -3 | cut -c1-150)
    if [ -n "$SAMPLE" ]; then
      p "  可疑请求样本:"
      printf '%s\n' "$SAMPLE" | while read -r l; do p "    $l"; done
    fi
  done
fi

h2 "6.4 Web 错误日志"
ERRF=$(find_logs "*error*.log*" $WEBLOG_DIRS | head -4)
if [ -z "$ERRF" ]; then
  info "未发现 web 错误日志"
else
  for f in $ERRF; do
    p "  $f (末 8 行):"
    tailed "$f" | tail -8 | cut -c1-150 | while read -r l; do p "    $l"; done
  done
fi

h2 "6.5 Tomcat 日志"
TLOGS=""
for d in $TOMCAT_DIRS; do
  [ -d "$d" ] || continue
  for f in "$d"/localhost_access_log* "$d"/catalina*.log; do
    [ -f "$f" ] && TLOGS="$TLOGS $f"
  done
done
if [ -z "$TLOGS" ]; then
  info "未发现 Tomcat 日志"
else
  for f in $TLOGS; do
    p "  $f"
    tailed "$f" | tail -5 | cut -c1-150 | while read -r l; do p "    $l"; done
  done
fi

# =====================================================================
h1 "7. 数据库日志"

DB_FOUND=0

h2 "7.1 MySQL / MariaDB"
MY_ERR=""
for d in /var/lib/mysql /var/log/mysql /var/log/mariadb /var/log; do
  [ -d "$d" ] || continue
  for f in "$d"/*.err "$d"/error.log* "$d"/mysqld.log* "$d"/mariadb.log*; do
    [ -f "$f" ] && MY_ERR="$MY_ERR $f"
  done
done
MY_ERR=$(printf '%s\n' $MY_ERR | grep -vE '^$' | sort -u | head -4)
if [ -z "$MY_ERR" ]; then
  info "未发现 MySQL/MariaDB 错误日志"
else
  DB_FOUND=1
  for f in $MY_ERR; do
    E=$(tailed "$f" | grep -aciE 'error|denied|refused')
    p "  $f"
    [ "$E" -gt 0 ] && warn "错误行 $E 条"
    tailed "$f" | tail -4 | cut -c1-150 | while read -r l; do p "    $l"; done
  done
fi
MY_SLOW=$(find_logs "slow*.log*" /var/log/mysql /var/lib/mysql /var/log 2>/dev/null | head -3)
if [ -n "$MY_SLOW" ]; then
  p "  慢查询日志:"
  for f in $MY_SLOW; do
    NQ=$(tailed "$f" | grep -ac 'Query_time')
    p "    $f ($NQ 条慢查询)"
  done
fi
if have ss; then
  DBC=$(ss -tn 2>/dev/null | grep -cE ':3306|:5432|:6379|:27017')
  p "  数据库端口当前连接数: $DBC"
fi

h2 "7.2 PostgreSQL"
PG=$(find_logs "*.log" /var/log/postgresql | head -3)
if [ -z "$PG" ]; then
  info "未发现 PostgreSQL 日志"
else
  DB_FOUND=1
  for f in $PG; do
    F=$(tailed "$f" | grep -acE 'FATAL|authentication failed')
    p "  $f : FATAL/认证失败 $F 条"
    [ "$F" -gt 0 ] && warn "存在认证失败, 排查弱口令爆破"
    tailed "$f" | grep -aE 'FATAL|authentication failed' | tail -3 | cut -c1-150 | while read -r l; do p "    $l"; done
  done
fi

h2 "7.3 Redis / MongoDB"
RD=$(find_logs "*.log" /var/log/redis /var/log/mongodb | head -3)
if [ -z "$RD" ]; then
  info "未发现 Redis/MongoDB 日志"
else
  DB_FOUND=1
  for f in $RD; do
    p "  $f (末 3 行):"
    tailed "$f" | tail -3 | cut -c1-150 | while read -r l; do p "    $l"; done
  done
fi

h2 "7.4 数据库高危配置"
for c in /etc/mysql/my.cnf /etc/my.cnf /etc/mysql/mysql.conf.d/mysqld.cnf /etc/redis/redis.conf; do
  [ -f "$c" ] || continue
  case "$c" in
    *redis.conf)
      grep -qE '^[[:space:]]*bind[[:space:]]+0\.0\.0\.0' "$c" 2>/dev/null && crit "redis 绑定 0.0.0.0: $c"
      grep -qE '^[[:space:]]*protected-mode[[:space:]]+no' "$c" 2>/dev/null && crit "redis 关闭 protected-mode: $c"
      ;;
    *)
      grep -qE '^[[:space:]]*bind-address[[:space:]]*=[[:space:]]*0\.0\.0\.0' "$c" 2>/dev/null && warn "MySQL 监听 0.0.0.0: $c"
      ;;
  esac
done
for c in /etc/postgresql/*/main/pg_hba.conf; do
  [ -f "$c" ] || continue
  grep -qE '^[^#]*[[:space:]]trust([[:space:]]|$)' "$c" 2>/dev/null && crit "pg_hba.conf 存在 trust 认证: $c"
done
[ "$DB_FOUND" -eq 0 ] && info "本机未发现数据库日志"

# =====================================================================
h1 "8. 容器 / 编排"
if have docker; then
  DN=$(docker ps -q 2>/dev/null | wc -l)
  p "  运行中容器: $DN"
  docker ps --format '    {{.Names}}  {{.Image}}  {{.Ports}}' 2>/dev/null | head -10 | while read -r l; do p "$l"; done
  if [ -d /var/lib/docker/containers ] && [ "$QUICK" -eq 0 ]; then
    BIG=$(du -sm /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -rn | head -3)
    if [ -n "$BIG" ]; then
      p "  容器日志体积 TOP3 (MB):"
      printf '%s\n' "$BIG" | while read -r l; do p "    $l"; done
    fi
  fi
else
  info "未安装 docker"
fi

# =====================================================================
h1 "9. 加固项速查"
if [ -r /etc/ssh/sshd_config ] && grep -qiE '^[[:space:]]*PermitRootLogin[[:space:]]+yes' /etc/ssh/sshd_config; then
  warn "SSH 允许 root 登录"
else
  ok "SSH 未显式允许 root 登录"
fi

FW=0
if have systemctl; then
  for svc in firewalld ufw nftables iptables; do
    if systemctl is-active "$svc" >/dev/null 2>&1; then p "  防火墙: $svc 运行中"; FW=1; fi
  done
fi
if [ "$FW" -eq 0 ] && have ufw; then
  if ufw status 2>/dev/null | grep -qi active; then FW=1; p "  防火墙: ufw active"; fi
fi
[ "$FW" -eq 1 ] || warn "未检测到运行中的防火墙服务"

if have getenforce; then p "  SELinux: $(getenforce 2>/dev/null)"; fi
if have aa-status; then
  if aa-status --enabled >/dev/null 2>&1; then p "  AppArmor: enabled"; else p "  AppArmor: disabled"; fi
fi
if [ -r /proc/sys/net/ipv4/ip_forward ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
  warn "开启了 IP 转发 (常见于代理/跳板/容器宿主)"
fi
if [ -r /etc/shadow ]; then
  awk -F: '($2==""){c++} END{printf "  空口令账号数: %d\n", c+0}' /etc/shadow
fi

# =====================================================================
h1 "10. 分析结论"
p "  高危项 : $CH"
p "  注意项 : $CW"
p "  正常项 : $CI"
p ""
if [ "$CH" -gt 0 ]; then
  p "  $C_R结论: 发现 $CH 个高危迹象, 请按上面 [高危] 条目逐项人工确认。$C_0"
  p "  说明: 自动初筛不替代人工取证; 无告警不等于无入侵 (内存马/内核 rootkit 不在此范围)。"
elif [ "$CW" -gt 0 ]; then
  p "  $C_Y结论: 未发现明确高危项, 有 $CW 条需人工复核。$C_0"
else
  p "  $C_G结论: 本次采集范围内未发现明显异常。$C_0"
fi
p ""
p "  采集范围: 账号/登录、进程/网络、持久化、web 访问与错误日志、数据库日志、容器、加固项"
p "  未覆盖  : 内存马、PHP-FPM/Java 内存 shell、内核态 rootkit、流量侧证据"
p "  时间窗口: 最近 $DAYS 天"

if [ -n "$REPORT" ]; then
  p ""
  p "报告已生成: $REPORT"
fi
exit 0
