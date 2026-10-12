#!/bin/bash
# ============================================================
# server-setup.sh - Ubuntu 22.04 服务端配置
# 功能：网络静态IP、DHCP、NFS、Samba、UFW 一键部署
# 要求：可重复执行（幂等）、set -euo pipefail
# ============================================================
set -euo pipefail

# -------------------- 环境变量 --------------------
APT_MIRROR="${APT_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu/}"
UBUNTU_CODENAME="jammy"

echo "=============================================="
echo "  服务端配置开始"
echo "  APT 镜像源: ${APT_MIRROR}"
echo "=============================================="

# --------------------------------------------------
# 1. 配置 APT 镜像源
# --------------------------------------------------
echo "[1/9] 配置 APT 镜像源..."

if ! grep -qF "${APT_MIRROR}" /etc/apt/sources.list 2>/dev/null; then
    cat > /etc/apt/sources.list << SRCEOF
deb ${APT_MIRROR} ${UBUNTU_CODENAME} main restricted universe multiverse
deb ${APT_MIRROR} ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb ${APT_MIRROR} ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb ${APT_MIRROR} ${UBUNTU_CODENAME}-security main restricted universe multiverse
SRCEOF
    echo "  ✓ APT 镜像源已更新为 ${APT_MIRROR}"
else
    echo "  - APT 镜像源已配置，跳过"
fi

# --------------------------------------------------
# 2. 识别网卡（NAT 管理网卡 + 两张实验网卡）
# --------------------------------------------------
echo "[2/9] 识别网卡..."

# 默认路由所在网卡 = NAT 管理网卡
DEFAULT_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
if [ -z "${DEFAULT_IFACE}" ]; then
    echo "  ❌ 错误：无法找到默认路由网卡"
    exit 1
fi
echo "  NAT 管理网卡: ${DEFAULT_IFACE}"

# 收集所有非 lo、非默认路由的网卡，按名称排序
mapfile -t EXP_IFACES < <(
    ip -4 -br addr show | awk '{print $1}' \
        | grep -v lo \
        | grep -v "${DEFAULT_IFACE}" \
        | sort
)

if [ ${#EXP_IFACES[@]} -ne 2 ]; then
    echo "  ❌ 错误：期望找到 2 张实验网卡，实际找到 ${#EXP_IFACES[@]} 张"
    echo "  所有非 lo 网卡:"
    ip -4 -br addr show | awk '{print "    "$1}'
    exit 1
fi

EXP_NIC1="${EXP_IFACES[0]}"
EXP_NIC2="${EXP_IFACES[1]}"
echo "  实验网卡1 (→ 192.168.56.10/24): ${EXP_NIC1}"
echo "  实验网卡2 (→ 192.168.57.10/24): ${EXP_NIC2}"

# --------------------------------------------------
# 3. 配置 netplan 静态 IP
# --------------------------------------------------
echo "[3/9] 配置实验网卡静态 IP..."

NETPLAN_CFG="/etc/netplan/60-experimental.yaml"

if [ ! -f "${NETPLAN_CFG}" ]; then
    cat > "${NETPLAN_CFG}" << NETEOF
# 实验网卡静态 IP 配置 — 由 server-setup.sh 生成
network:
  version: 2
  renderer: networkd
  ethernets:
    ${EXP_NIC1}:
      dhcp4: no
      addresses:
        - 192.168.56.10/24
    ${EXP_NIC2}:
      dhcp4: no
      addresses:
        - 192.168.57.10/24
NETEOF
    netplan apply
    echo "  ✓ netplan 配置已写入并应用"
else
    echo "  - netplan 配置已存在，跳过写入"
    netplan apply || true
fi

# 等待网卡就绪
sleep 2

# 验证 IP
if ip -4 addr show "${EXP_NIC1}" 2>/dev/null | grep -q "192.168.56.10" && \
   ip -4 addr show "${EXP_NIC2}" 2>/dev/null | grep -q "192.168.57.10"; then
    echo "  ✓ 实验 IP 已生效"
else
    echo "  ⚠ 警告：实验 IP 可能未完全生效，继续执行…"
fi

# --------------------------------------------------
# 4. 安装必要软件包
# --------------------------------------------------
echo "[4/9] 安装软件包..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    isc-dhcp-server \
    nfs-kernel-server \
    samba \
    smbclient \
    rpcbind \
    ufw
echo "  ✓ 软件包安装完成"

# --------------------------------------------------
# 5. 配置 DHCP 服务（双网段地址池）
# --------------------------------------------------
echo "[5/9] 配置 DHCP 服务..."

# 指定 DHCP 监听的实验网卡
DHCP_IFACE_FILE="/etc/default/isc-dhcp-server"
DESIRED_IFACES="INTERFACESv4=\"${EXP_NIC1} ${EXP_NIC2}\""

if ! grep -qF "${DESIRED_IFACES}" "${DHCP_IFACE_FILE}" 2>/dev/null; then
    # 注释掉原有 INTERFACES 配置，写入新的
    sed -i 's/^INTERFACESv4=/#INTERFACESv4=/' "${DHCP_IFACE_FILE}"
    echo "${DESIRED_IFACES}" >> "${DHCP_IFACE_FILE}"
    echo "  ✓ DHCP 监听网卡已配置: ${EXP_NIC1} ${EXP_NIC2}"
else
    echo "  - DHCP 监听网卡已配置，跳过"
fi

# 写入 dhcpd.conf 子网声明
DHCPD_CONF="/etc/dhcp/dhcpd.conf"

if ! grep -q "subnet 192.168.56.0" "${DHCPD_CONF}" 2>/dev/null; then
    cat >> "${DHCPD_CONF}" << 'DHCPEOF'

# ===== 实验 DHCP 子网配置 =====
# 网段 1：192.168.56.0/24 → linux-lab-net1
subnet 192.168.56.0 netmask 255.255.255.0 {
    range 192.168.56.100 192.168.56.200;
    option routers 192.168.56.10;
    option domain-name-servers 8.8.8.8, 8.8.4.4;
    option domain-name "lab1.local";
    default-lease-time 600;
    max-lease-time 7200;
}

# 网段 2：192.168.57.0/24 → linux-lab-net2
subnet 192.168.57.0 netmask 255.255.255.0 {
    range 192.168.57.100 192.168.57.200;
    option routers 192.168.57.10;
    option domain-name-servers 8.8.8.8, 8.8.4.4;
    option domain-name "lab2.local";
    default-lease-time 600;
    max-lease-time 7200;
}
DHCPEOF
    echo "  ✓ DHCP 子网声明已写入"
else
    echo "  - DHCP 子网声明已存在，跳过"
fi

# 重启 DHCP 服务
systemctl restart isc-dhcp-server  2>/dev/null || systemctl start isc-dhcp-server 2>/dev/null || true
systemctl enable  isc-dhcp-server  2>/dev/null || true
echo "  ✓ DHCP 服务已启动"

# --------------------------------------------------
# 6. 配置 NFS 服务
# --------------------------------------------------
echo "[6/9] 配置 NFS 服务..."

# 创建共享目录
mkdir -p /srv/nfs/public /srv/nfs/admin

# 创建映射用户 nfsanon（uid=2400, gid=2400）
if ! id -u nfsanon >/dev/null 2>&1; then
    groupadd -g 2400 nfsanon 2>/dev/null || true
    useradd -u 2400 -g 2400 -r -s /usr/sbin/nologin nfsanon 2>/dev/null || true
    echo "  ✓ 已创建 nfsanon 用户 (uid=2400, gid=2400)"
else
    echo "  - nfsanon 用户已存在，跳过"
fi

chown -R nfsanon:nfsanon /srv/nfs/public
chmod 755 /srv/nfs/public /srv/nfs/admin

# 配置 /etc/exports
EXPORTS_FILE="/etc/exports"

if ! grep -q "/srv/nfs/public" "${EXPORTS_FILE}" 2>/dev/null; then
    cat >> "${EXPORTS_FILE}" << 'NFSEOF'

# ===== 实验 NFS 共享 =====
# public：允许读写，所有客户端映射为 nfsanon
/srv/nfs/public 192.168.56.0/24(rw,sync,all_squash,anonuid=2400,anongid=2400) 192.168.57.0/24(rw,sync,all_squash,anonuid=2400,anongid=2400)
# admin：允许读写，保留 root 压缩
/srv/nfs/admin  192.168.56.0/24(rw,sync,root_squash) 192.168.57.0/24(rw,sync,root_squash)
NFSEOF
    echo "  ✓ NFS 导出配置已写入"
else
    echo "  - NFS 导出配置已存在，跳过"
fi

# 固定 mountd 端口为 20048（方法：/etc/nfs.conf）
if ! grep -q "^port=20048" /etc/nfs.conf 2>/dev/null; then
    if grep -q "^\[mountd\]" /etc/nfs.conf 2>/dev/null; then
        sed -i '/^\[mountd\]/a port=20048' /etc/nfs.conf
    else
        cat >> /etc/nfs.conf << 'NFSCOF'

[mountd]
port=20048
NFSCOF
    fi
    echo "  ✓ mountd 端口已固定为 20048 (nfs.conf)"
else
    echo "  - mountd 端口已固定，跳过"
fi

# 也写入 /etc/default/nfs-kernel-server（双保险）
if ! grep -q "RPCMOUNTDOPTS.*20048" /etc/default/nfs-kernel-server 2>/dev/null; then
    sed -i 's/^#\?RPCMOUNTDOPTS=.*/RPCMOUNTDOPTS="--port 20048"/' /etc/default/nfs-kernel-server
    if ! grep -q "RPCMOUNTDOPTS" /etc/default/nfs-kernel-server; then
        echo 'RPCMOUNTDOPTS="--port 20048"' >> /etc/default/nfs-kernel-server
    fi
fi

# 重启 NFS 相关服务
exportfs -ra 2>/dev/null || true
systemctl restart rpcbind         2>/dev/null || true
systemctl restart nfs-kernel-server 2>/dev/null || systemctl restart nfs-server 2>/dev/null || true
systemctl enable  nfs-kernel-server 2>/dev/null || systemctl enable  nfs-server 2>/dev/null || true
echo "  ✓ NFS 服务已启动"

# --------------------------------------------------
# 7. 配置 Samba 服务
# --------------------------------------------------
echo "[7/9] 配置 Samba 服务..."

# 创建共享目录
mkdir -p /srv/samba/public /srv/samba/secure
chmod 777 /srv/samba/public
chmod 755 /srv/samba/secure

# 创建 smbstudent 用户
if ! id -u smbstudent >/dev/null 2>&1; then
    useradd -m -s /usr/sbin/nologin smbstudent
    echo "  ✓ 已创建系统用户 smbstudent"
else
    echo "  - 系统用户 smbstudent 已存在，跳过"
fi

# 设置 Samba 密码（幂等：重复执行无副作用）
echo -e "Student@123\nStudent@123" | smbpasswd -a smbstudent -s 2>/dev/null || true
echo "  ✓ smbstudent Samba 密码已设置"

# 配置 smb.conf
SMB_CONF="/etc/samba/smb.conf"

if ! grep -q "\[public\]" "${SMB_CONF}" 2>/dev/null; then
    # 备份原配置
    cp "${SMB_CONF}" "${SMB_CONF}.bak.$(date +%Y%m%d%H%M%S)"

    cat >> "${SMB_CONF}" << 'SMBEOF'

# ===== 实验 Samba 共享 =====
[public]
    comment = Public Share (Guest Access)
    path = /srv/samba/public
    browseable = yes
    read only = no
    guest ok = yes
    create mask = 0666
    directory mask = 0777

[secure]
    comment = Secure Share (smbstudent only)
    path = /srv/samba/secure
    browseable = yes
    read only = no
    guest ok = no
    valid users = smbstudent
    create mask = 0644
    directory mask = 0755
SMBEOF
    echo "  ✓ Samba 共享配置已写入"
else
    echo "  - Samba 共享配置已存在，跳过"
fi

# 重启 Samba 服务
systemctl restart smbd nmbd 2>/dev/null || true
systemctl enable  smbd nmbd 2>/dev/null || true
echo "  ✓ Samba 服务已启动"

# --------------------------------------------------
# 8. 配置 UFW 防火墙
# --------------------------------------------------
echo "[8/9] 配置 UFW 防火墙..."

# 按顺序放行必要端口（ufw allow 本身是幂等的）
echo "  → 放行 SSH (22/tcp)"
ufw allow 22/tcp 2>/dev/null || true

echo "  → 放行 DHCP (67/udp)"
ufw allow 67/udp 2>/dev/null || true

echo "  → 放行 RPC portmapper (111)"
ufw allow 111 2>/dev/null || true

echo "  → 放行 NFS (2049)"
ufw allow 2049 2>/dev/null || true

echo "  → 放行 NFS mountd (20048)"
ufw allow 20048 2>/dev/null || true

echo "  → 放行 Samba NetBIOS (139/tcp)"
ufw allow 139/tcp 2>/dev/null || true

echo "  → 放行 Samba SMB (445/tcp)"
ufw allow 445/tcp 2>/dev/null || true

# 启用 UFW
ufw --force enable 2>/dev/null || true
echo "  ✓ UFW 已启用"

# --------------------------------------------------
# 9. 最终状态汇总
# --------------------------------------------------
echo "[9/9] 最终状态汇总..."
echo ""
echo "=============================================="
echo "  服务端配置完成！"
echo "=============================================="
echo "  实验网卡1 : ${EXP_NIC1} → 192.168.56.10/24"
echo "  实验网卡2 : ${EXP_NIC2} → 192.168.57.10/24"
echo "  DHCP 池1  : 192.168.56.100 ~ 192.168.56.200"
echo "  DHCP 池2  : 192.168.57.100 ~ 192.168.57.200"
echo "  NFS 共享  : /srv/nfs/public (all_squash)"
echo "             : /srv/nfs/admin  (root_squash)"
echo "  Samba 共享: public (guest ok)"
echo "             : secure (smbstudent / Student@123)"
echo "  UFW       : 已启用，仅放行必要端口"
echo "=============================================="
