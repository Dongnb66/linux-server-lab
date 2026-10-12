# linux-server-lab · Ubuntu 22.04 服务端配置实验

课程实验：在 VirtualBox + Vagrant 里搭一套「服务端 + 客户端」的 Ubuntu 22.04 实验环境，
用**一个幂等脚本**把静态 IP、DHCP、NFS、Samba、UFW 一次性配好。

配套脚本：[`server-setup.sh`](./server-setup.sh) —— 9 步，可重复执行。

---

## 实验拓扑

| 角色 | 系统 | 网卡 | 地址 |
|---|---|---|---|
| 服务端 | Ubuntu 22.04（Vagrant `generic/ubuntu2204`） | eth0 | NAT，管理用 |
| | | eth1 | **192.168.56.10/24** → `linux-lab-net1` |
| | | eth2 | **192.168.57.10/24** → `linux-lab-net2` |
| 客户端 ×2 | Ubuntu 22.04 | eth1 | 由服务端 DHCP 分配 `.100–.200` |

- 实验网段通过 VirtualBox `InternalNetwork` 打通，服务端与客户端互访不经过宿主机。
- 默认路由所在网卡是 NAT 管理网卡，脚本靠它把自己从实验网卡里排除掉。

---

## 脚本做了什么

| 步 | 内容 | 关键细节 |
|---|---|---|
| 1 | 配置 APT 镜像源 | 清华 tuna 源，`jammy` |
| 2 | **识别网卡** | 从默认路由反推 NAT 网卡；其余按名字排序取 2 张，**数量不对直接 `exit 1`** |
| 3 | **netplan 静态 IP** | 生成 `/etc/netplan/60-experimental.yaml`，`renderer: networkd`，`netplan apply` 后**回读验证 IP 生效** |
| 4 | 安装软件包 | `isc-dhcp-server` `nfs-kernel-server` `samba` `smbclient` `rpcbind` `ufw` |
| 5 | **DHCP 双网段地址池** | `/etc/default/isc-dhcp-server` 指定监听网卡 + `dhcpd.conf` 两个 `subnet`，`range .100–.200`，租约 600/7200 |
| 6 | **NFS** | `/srv/nfs/public`（`all_squash`）+ `/srv/nfs/admin`（`root_squash`）；建 `nfsanon(2400)` 映射用户；**固定 mountd 端口 20048** |
| 7 | **Samba** | `[public]` 匿名可读、`[secure]` 仅 `smbstudent`；改前先备份 `smb.conf` |
| 8 | **UFW** | 放行 22 / 67udp / 111 / 2049 / 20048 / 139 / 445 → `ufw --force enable` |
| 9 | 状态汇总 | 打印全部结果 |

---

## 幂等是怎么实现的

每一步都是「先探测、再写」：

- `grep -qF <标记> <配置文件>` —— 配置片段已存在就跳过，不重复追加
- `id -u nfsanon` / `id -u smbstudent` —— 用户已建就跳过
- 对 `/etc/exports`、`smb.conf` 这类用 `>>` 追加的文件，不判重会每跑一次长一截

所以重复执行结果是稳定的。这是脚本开头那句「可重复执行（幂等）」的实际实现，
也是它和「一次性敲命令」的区别。

---

## 用法

```bash
# 在服务端虚拟机上，需要 root
sudo bash server-setup.sh
```

可覆盖的环境变量：

```bash
APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ sudo -E bash server-setup.sh
```

---

## 验证过的点

- `netplan apply` 后回读网卡地址，确认 `192.168.56.10` / `192.168.57.10` 生效
- 客户端能从服务端拿到 `192.168.56.100–200` 的地址（`dhcpd` 租约生效）
- `/srv/nfs/public` 客户端可读写，落盘属主被 squash 成 `nfsanon(2400)`
- `/srv/nfs/admin` 保留 root 压缩，普通用户身份不被改写
- Samba：`[public]` 匿名可访问，`[secure]` 只有 `smbstudent` 能进
- UFW 启用后 SSH / DHCP / NFS / Samba 端口仍可用

---

## 几个不太显然的取舍

**为什么要把 mountd 端口固定成 20048？**
NFS 的 mountd 默认监听随机端口，防火墙没法预先放行。在 `/etc/nfs.conf` 与
`/etc/default/nfs-kernel-server` 两处固定下来，UFW 才能精确开这一个口。
这是 NFS 和防火墙的交互，不是照教程敲能想到的。

**`all_squash` 和 `root_squash` 的区别？**
public 目录用 `all_squash` 把所有客户端用户统一映射成 `nfsanon`，避免客户端 root 越权；
admin 目录用 `root_squash`，只压 root、保留普通用户的真实身份。

**为什么网卡靠探测而不是写死 eth1/eth2？**
虚拟机重建后网卡名会变。从默认路由反推 NAT 网卡、其余按名字排序取两张，
并且断言数量必须等于 2 —— 换一台机器不用改脚本。

---

## 边界

这是**实验环境**，不是生产环境：没有监控告警、没有 7×24 值守、没有工单流程，
NFS 也没上 Kerberos。目的是把 Linux 服务端配置这条链路完整走通一遍。

## License

MIT
