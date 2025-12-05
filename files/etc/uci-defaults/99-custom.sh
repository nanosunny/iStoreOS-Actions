#!/bin/sh
# 仅首次运行iStoreOS时，会执行以下脚本。重启后消失
# Log file for debugging
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE

# 设置默认防火墙规则，方便虚拟机首次访问WebUI。之后可手动关闭
uci set firewall.@zone[1].input='ACCEPT'

# 设置主机名映射，解决安卓原生TV无法联网的问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 设置主机名
uci set system.@system[0].hostname='iStoreOS'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'

# 设置默认语言
uci set luci.main.lang='zh_cn'
# 保存设置
uci commit system
uci commit luci

# 【网络设置-static】
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.5.88'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='192.168.5.1'
uci set network.lan.dns='223.5.5.5'
uci commit network

# 【网络设置-dhcp】
# -1、获取物理接口列表
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        ifnames="$ifnames $iface_name"
    fi
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')

count=$(echo "$ifnames" | wc -w)
echo "Detected physical interfaces: $ifnames" >>$LOGFILE
echo "Interface count: $count" >>$LOGFILE

# -2、根据板子型号映射WAN和LAN接口
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown")
echo "Board detected: $board_name" >>$LOGFILE

wan_ifname=""
lan_ifnames=""
# 处理个别特殊开发板网口顺序
case "$board_name" in
    "radxa,e20c"|"friendlyarm,nanopi-r5c")
        wan_ifname="eth1"
        lan_ifnames="eth0"
        echo "Using $board_name mapping: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        ;;
    *)
        # 默认第一个接口为WAN，其余为LAN
        wan_ifname=$(echo "$ifnames" | awk '{print $1}')
        lan_ifnames=$(echo "$ifnames" | cut -d ' ' -f2-)
        echo "Using default mapping: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        ;;
esac

# -3、开始配置网络
if [ "$count" -eq 1 ]; then
    # 单网口设备，DHCP模式
    uci set network.lan.proto='dhcp'
    uci delete network.lan.ipaddr
    uci delete network.lan.netmask
    uci delete network.lan.gateway
    uci delete network.lan.dns
    uci commit network
elif [ "$count" -gt 1 ]; then
    # 多网口设备
    # 配置WAN
    uci set network.wan=interface
    uci set network.wan.device="$wan_ifname"
    uci set network.wan.proto='dhcp'
	
    # 配置WAN6
    uci set network.wan6=interface
    uci set network.wan6.device="$wan_ifname"
    uci set network.wan6.proto='dhcpv6'
	
    # 查找br-lan设备section
    section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
    if [ -z "$section" ]; then
        echo "error：cannot find device 'br-lan'." >>$LOGFILE
    else
        # 删除原有ports
        uci -q delete "network.$section.ports"
        # 添加LAN接口端口
        for port in $lan_ifnames; do
            uci add_list "network.$section.ports"="$port"
        done
        echo "Updated br-lan ports: $lan_ifnames" >>$LOGFILE
    fi
	
    # LAN口设置静态IP
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr='192.168.100.1'
    uci set network.lan.netmask='255.255.255.0'
    
	uci commit network
fi

# 设置所有网口可访问ttyd
uci delete ttyd.@ttyd[0].interface

# 设置所有网口可连接SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit

# 还原banner并清除/etc/banner1
cp /etc/banner1/banner /etc/
rm -r /etc/banner1

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="iStoreOS 版本号"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

exit 0
