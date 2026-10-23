# Linux-Intrusion-Check-Script

Linux 主机入侵排查与安全加固的日志采集/分析脚本集合。

当前包含一个脚本：`ir-log-triage.sh` —— 只读运行，自动发现并分析应急响应所需的日志，默认只在屏幕输出结论，需要留档时生成 Markdown 报告。

## 特性

- **跨发行版**：Debian/Ubuntu、RHEL/CentOS/Rocky/Alma、SUSE、Alpine（busybox）均可运行，仅依赖 sh + 基础 coreutils + grep/awk/sed/sort，无需安装任何额外软件。
- **只读**：不修改系统配置、不写目标机文件、不安装软件。
- **日志路径自动发现**：覆盖 nginx、Apache、Tomcat、Caddy 等常见目录，以及 MySQL/MariaDB、PostgreSQL、Redis、MongoDB 的日志位置，不写死单一发行版路径。
- **三级判定**：`[高危]` / `[注意]` / `[OK]`，末尾给出计数与结论，避免全量报警式噪音。
- **可批量化**：纯 stdout 输出，适合 ssh + for 循环批量采集。

## 仓库结构

```text
.
├── ir-log-triage.sh   # 应急响应日志采集与分析脚本
└── README.md
```

## 快速开始

```bash
# 下载后直接运行（默认只打印到屏幕，不生成文件）
chmod +x ir-log-triage.sh
sudo ./ir-log-triage.sh

# 快速模式：跳过 web 根目录遍历与 webshell 内容扫描
sudo ./ir-log-triage.sh -q

# 生成 Markdown 报告
sudo ./ir-log-triage.sh -o /tmp/ir-report

# 指定时间窗口（天）、关闭颜色
sudo ./ir-log-triage.sh -d 30 -n > ir.txt
```

脚本对 root 无硬性要求，但非 root 时 /var/log 下多数日志、/proc/*/exe、/etc/shadow 不可读，相关段落会降级或跳过，开头会给出提示。

## 参数

| 参数 | 说明 |
|---|---|
| `-o DIR` | 生成 Markdown 报告到 DIR（默认不落盘） |
| `-d DAYS` | 分析时间窗口，默认 7 天 |
| `-q` | 快速模式：跳过 web 根目录遍历与 webshell 内容扫描 |
| `-n` | 关闭颜色（重定向或采集日志时建议加） |
| `-h` | 帮助 |

## 采集与分析范围

| 章节 | 内容 | 关键判定 |
|---|---|---|
| 1. 系统基本信息 | 发行版、内核、架构、machine-id、运行时长、时间同步 | — |
| 2. 账号与登录 | UID=0 账号、可登录账号、空口令、sudo NOPASSWD、authorized_keys、失败/成功登录 TOP、last/lastb | 非 root 的 UID=0、空密码账号 → 高危；失败登录 ≥100 次 → 高危 |
| 3. 进程与网络 | 监听端口、从 /tmp 运行的进程、映像已删除的进程、高占用进程 | 临时目录运行 → 高危；系统路径下 deleted → 注意（多为升级后未重启） |
| 4. 持久化 | crontab 与 /etc/cron.*、近 N 天变更的 systemd 单元、ld.so.preload、rc.local、profile.d、sshd 配置 | ld.so.preload 非空 → 高危 |
| 5. 可疑文件 | 临时目录可执行文件、web 根目录近期变更页面、PHP webshell 特征 | webshell 特征命中 → 高危 |
| 6. Web 日志 | 来源 TOP、状态码分布、UA TOP、扫描器特征、SQLi/穿越/命令执行/webshell 计数与样本、错误日志、Tomcat 日志 | 各类攻击特征命中 → 高危 |
| 7. 数据库日志 | MySQL/MariaDB 错误与慢查询、PostgreSQL FATAL、Redis/MongoDB、连接数、高危配置（bind 0.0.0.0、protected-mode no、pg trust） | 配置暴露 → 高危 |
| 8. 容器 | docker 容器列表、容器日志体积 | — |
| 9. 加固项 | SSH root 登录、防火墙状态、SELinux/AppArmor、IP 转发、空口令数 | 无防火墙或允许 root → 注意 |
| 10. 结论 | 高危/注意/正常 计数与结论、覆盖范围说明 | — |

## 报告模式

`-o DIR` 生成 `irtriage_<主机名>_<时间戳>.md`，按章节分节，日志片段放在代码块中，可直接贴进工单或 Wiki。

报告会包含内网 IP、用户名、主机名及部分日志原文，属于敏感材料，请按内部数据要求存放。

## 实测环境

| 主机 | 系统 | 结果 |
|---|---|---|
| 10.0.0.11 | Kali GNU/Linux Rolling (kernel 6.19) | 通过；1 条真实高危（失败登录 600 次，来源 192.168.150.22） |
| 10.0.0.12 | Ubuntu 24.04.5 LTS | 通过，0 误报 |
| 10.0.0.13 | Ubuntu 24.04.4 LTS（Docker/vulhub 靶场） | 通过，0 误报；3 条注意均为真实状态 |
| 10.0.0.14 | Ubuntu 26.04 LTS | 通过，0 误报 |

四台机器均为 `exit=0`、stderr 为空。Ubuntu 24.04/26.04 上 last 命令可能缺失（改用 wtmpdb），脚本会提示并继续。

## 判定逻辑与已知误报

1. **映像已删除（deleted exe）分路径判定**：/usr、/lib、/bin、/sbin、/opt、/snap 下的 deleted 映像只算注意——软件包升级后旧进程仍持有旧 inode 是常态（实测 python3.14、ssh-agent 均属此类）；只有 /tmp、/var/tmp、/dev/shm 或异常路径才判高危。
2. **临时目录可执行文件**：排除 X11 的 lock/socket、go-build 编译中间产物与脚本自身产物；/tmp 下有可执行位仍会列出，供人工确认是否为自己留下的工具。
3. **失败登录阈值**：≥100 次判高危，否则仅提示；不同发行版日志轮转策略不同，数字只作参考。
4. **webshell 特征**仅覆盖 PHP 常见形态（eval / assert / base64_decode / system / passthru / shell_exec 拼接超全局变量），JSP/ASPX 需人工核查。
5. **未运行 web 服务的主机**不会因为找不到 access.log 报警。
6. **grep 全部带 -a**，避免日志含二进制内容时出现 binary file matches 干扰。

## 覆盖不到的范围

- 内存马、PHP-FPM/Java 进程内 shell（需内存取证或进程 dump）
- 内核态 rootkit（需专门检测工具或离线镜像分析）
- 网络流量侧证据（需流量镜像、NDR）
- 应用层业务日志（如 logback 业务审计），需按业务单独指定
- 文件系统时间线（需 Sleuth Kit 类工具）

脚本定位「哪里值得看」，不替代取证；无告警不等于无入侵。

## 批量执行

```bash
for h in 10.0.0.11 10.0.0.12 10.0.0.14; do
  u=ubuntu; [ $h = 10.0.0.11 ] && u=kali
  scp -q ir-log-triage.sh $u@$h:/tmp/
  ssh $u@$h 'sudo -n sh /tmp/ir-log-triage.sh -q -n' > ./ir-$h.txt 2>&1
done
```

## 安全与合规

- 仅用于**自有或已获书面授权**的主机。
- 脚本只读：不修改配置、不删除文件、不写入目标机；-o 写入的是你指定的目录。
- 排查期间如需清理后门，属独立动作，需单独授权后执行。

## 版本

- v1.0.0 (2026-10-23)：首版。10 个章节、跨发行版日志发现、报告模式、误报分级。
