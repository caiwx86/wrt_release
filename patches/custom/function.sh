#!/bin/bash

config_file=".config"

BASE_PATH=$1
if [[ -d $BASE_PATH ]]; then
   cd $BASE_PATH
else
   C_PWD=$(pwd)
   echo "$BASE_PATH 不存在, 当前路径: $C_PWD"
fi

function cat_kernel_config() {
  if [ -f $1 ]; then
    cat >> $1 <<EOF
CONFIG_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_CGROUPS=y
CONFIG_KPROBES=y
CONFIG_NET_INGRESS=y
CONFIG_NET_EGRESS=y
CONFIG_NET_SCH_INGRESS=m
CONFIG_NET_CLS_BPF=m
CONFIG_NET_CLS_ACT=y
CONFIG_BPF_STREAM_PARSER=y
CONFIG_DEBUG_INFO=y
# CONFIG_DEBUG_INFO_REDUCED is not set
CONFIG_DEBUG_INFO_BTF=y
CONFIG_KPROBE_EVENTS=y
CONFIG_BPF_EVENTS=y

CONFIG_SCHED_CLASS_EXT=y
CONFIG_PROBE_EVENTS_BTF_ARGS=y
CONFIG_IMX_SCMI_MISC_DRV=y
CONFIG_ARM64_CONTPTE=y
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y
# CONFIG_TRANSPARENT_HUGEPAGE_MADVISE is not set
# CONFIG_TRANSPARENT_HUGEPAGE_NEVER is not set
EOF
    echo "cat_kernel_config to $1 done"
  fi
}

function cat_ebpf_config() {

#ebpf相关
  cat >> $1 <<EOF
#eBPF
CONFIG_DEVEL=y
CONFIG_KERNEL_DEBUG_INFO=y
CONFIG_KERNEL_DEBUG_INFO_REDUCED=n
CONFIG_KERNEL_DEBUG_INFO_BTF=y
CONFIG_KERNEL_CGROUPS=y
CONFIG_KERNEL_CGROUP_BPF=y
CONFIG_KERNEL_BPF_EVENTS=y
CONFIG_BPF_TOOLCHAIN_HOST=y
CONFIG_KERNEL_XDP_SOCKETS=y
CONFIG_PACKAGE_kmod-xdp-sockets-diag=y
EOF
}

function cat_usb_net() {
  cat >> $1 <<EOF
#USB CPE Driver
CONFIG_PACKAGE_kmod-usb-net=y
CONFIG_PACKAGE_kmod-usb-net-cdc-eem=y
CONFIG_PACKAGE_kmod-usb-net-cdc-ether=y
CONFIG_PACKAGE_kmod-usb-net-cdc-mbim=y
CONFIG_PACKAGE_kmod-usb-net-cdc-ncm=y
CONFIG_PACKAGE_kmod-usb-net-cdc-subset=y
CONFIG_PACKAGE_kmod-usb-net-huawei-cdc-ncm=y
CONFIG_PACKAGE_kmod-usb-net-ipheth=y
CONFIG_PACKAGE_kmod-usb-net-rndis=y
CONFIG_PACKAGE_kmod-usb-net-rtl8150=y
CONFIG_PACKAGE_kmod-usb-net-rtl8152=y
EOF
#6.12内核不包含以下驱动
if echo "$CI_NAME" | grep -v "6.12" > /dev/null; then
  cat >> $1 <<EOF
CONFIG_PACKAGE_kmod-usb-net-qmi-wwan=y
CONFIG_PACKAGE_kmod-usb-net-qmi-wwan-fibocom=y
CONFIG_PACKAGE_kmod-usb-net-qmi-wwan-quectel=y
EOF
fi

}

function set_nss_driver() {
  cat >> $1 <<EOF
#NSS驱动相关
CONFIG_NSS_FIRMWARE_VERSION_11_4=n
# CONFIG_NSS_FIRMWARE_VERSION_12_5 is not set
CONFIG_NSS_FIRMWARE_VERSION_12_2=y
CONFIG_PACKAGE_kmod-qca-nss-dp=y
CONFIG_PACKAGE_kmod-qca-nss-drv=y
CONFIG_PACKAGE_kmod-qca-nss-drv-bridge-mgr=y
CONFIG_PACKAGE_kmod-qca-nss-drv-vlan=y
CONFIG_PACKAGE_kmod-qca-nss-drv-igs=y
#CONFIG_PACKAGE_kmod-qca-nss-drv-map-t=y
CONFIG_PACKAGE_kmod-qca-nss-drv-pppoe=y
CONFIG_PACKAGE_kmod-qca-nss-drv-pptp=y
CONFIG_PACKAGE_kmod-qca-nss-drv-qdisc=y
CONFIG_PACKAGE_kmod-qca-nss-ecm=y
CONFIG_PACKAGE_kmod-qca-nss-macsec=y
CONFIG_PACKAGE_kmod-qca-nss-drv-l2tpv2=y
CONFIG_PACKAGE_kmod-qca-nss-drv-lag-mgr=y
EOF
}
function kernel_version() {
  echo $(sed -n 's/^KERNEL_PATCHVER:=\(.*\)/\1/p' target/linux/qualcommax/Makefile)
}

function set_kernel_size() {
  #修改jdc ax1800 pro 的内核大小为12M
  image_file='./target/linux/qualcommax/image/ipq60xx.mk'
  sed -i "/^define Device\/jdcloud_re-ss-01/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" $image_file
  sed -i "/^define Device\/jdcloud_re-cs-02/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" $image_file
  sed -i "/^define Device\/jdcloud_re-cs-07/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" $image_file
  sed -i "/^define Device\/redmi_ax5-jdcloud/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" $image_file
}
#开启内存回收补丁
function enable_skb_recycler() {
  cat >> $1 <<EOF
CONFIG_KERNEL_SKB_RECYCLER=y
CONFIG_KERNEL_SKB_RECYCLER_MULTI_CPU=y
EOF
}

function generate_config() {
  echo "执行generate_config()"
  #配置文件不存在
  if [[ ! -f $config_file ]]; then
      echo $config_file 文件不存在
      exit
  else
      echo "# function.sh ..." >> $config_file
  fi

  #默认机型为ipq60xx
  local target='ipq60xx'

  # NSS参数配置 
  if [[ $NSS_ENABLE == "true" ]]; then
    set_nss_driver $config_file
  fi
  # cat_usb_net $config_file
  #增加ebpf
  cat_ebpf_config $config_file
  enable_skb_recycler $config_file
  set_kernel_size
  #增加内核选项
  cat_kernel_config "target/linux/qualcommax/${target}/config-default"
}

# Git稀疏克隆，只克隆指定目录到本地
function git_sparse_clone() {
  branch="$1" repourl="$2" && shift 2
  git clone --depth=1 -b $branch --single-branch --filter=blob:none --sparse $repourl
  repodir=$(echo $repourl | awk -F '/' '{print $(NF)}')
  cd $repodir && git sparse-checkout set $@
  mv -f $@ ../package 
  cd .. && rm -rf $repodir
}

function remove_package() {
   packages="$@"
   for package in $packages; do 
      pkg_path=$(find . -type d -name "$package")
      if [[ ! "$pkg_path" == "" ]]; then
         rm -rvf $pkg_path
      fi
   done
}

function add_daed() {
  # 删除不用插件
  remove_package daed luci-app-daed
  # 添加额外插件
  git_sparse_clone master https://github.com/QiuSimons/luci-app-daed \
      daed luci-app-daed 
  #修复daed/Makefile
  if [ -f "package/daed/Makefile" ]; then
      rm -rf package/daed/Makefile && cp -r $GITHUB_WORKSPACE/patches/custom/patch/daed/Makefile package/daed/
      cat package/daed/Makefile
  fi
  # 添加daed配置
  echo "CONFIG_PACKAGE_luci-app-daed=y" >> $config_file 
  # 解决luci-app-daed 依赖问题
  # if [[ ! -d "package/libcron" ]]; then
  #     mkdir -p package/libcron && wget -O package/libcron/Makefile https://raw.githubusercontent.com/immortalwrt/packages/refs/heads/master/libs/libcron/Makefile
  # fi
}

function set_theme() {
  remove_package luci-app-argon-config luci-theme-argon 
  git_sparse_clone openwrt-24.10 https://github.com/sbwml/luci-theme-argon \
     luci-app-argon-config luci-theme-argon 
  # 添加argon主题配置
  echo "CONFIG_PACKAGE_luci-app-argon-config=y" >> $config_file
  echo "CONFIG_PACKAGE_luci-theme-argon=y" >> $config_file

  argon_css_file=$(find ./package/luci-theme-argon/ -type f -name "cascade.css")
  #修改字体
  sed -i "/^.main .main-left .nav li a {/,/^}/ { /font-weight: bolder/d }" $argon_css_file
  sed -i '/^\[data-page="admin-system-opkg"\] #maincontent>.container {/,/}/ s/font-weight: 600;/font-weight: normal;/' $argon_css_file

  if [ -d "package/luci-theme-argon" ]; then
     find "package/luci-theme-argon" -type f -name "cascade*" -exec sed -i 's/--bar-bg/--primary/g' {} \;
  fi

}

function add_nps() {
  remove_package nps npc luci-app-nps luci-app-npc
  git_sparse_clone main https://github.com/djylb/nps-openwrt \
      npc luci-app-npc
  
  echo "CONFIG_PACKAGE_luci-app-npc=y" >> $config_file
}

function add_watchdog() {
  # 添加额外插件
  git_sparse_clone main https://github.com/sirpdboy/luci-app-watchdog \
      watchdog luci-app-watchdog 
  echo "CONFIG_PACKAGE_luci-app-watchdog=y" >> $config_file
}

function add_netdata() {
  remove_package netdata luci-app-netdata
  git clone https://github.com/muink/openwrt-netdata-ssl package/netdata
  git clone https://github.com/muink/luci-app-netdata package/luci-app-netdata
  echo "CONFIG_PACKAGE_luci-app-netdata=y" >> $config_file
}

function add_other_package() {
  echo "添加其他通插件"
  # add other package
  #impitool
  echo "CONFIG_PACKAGE_ipmitool=y" >> $config_file
  # jq
  echo "CONFIG_PACKAGE_jq=y" >> $config_file
  # gdisk
  echo "CONFIG_PACKAGE_gdisk=y" >> $config_file
  # luci-app-mwan3
  echo "CONFIG_PACKAGE_luci-app-mwan3=y" >> $config_file

  # DNSMASQ DNSSERVER
  if [[ -f "package/network/services/dnsmasq/files/dnsmasq.init" ]]; then
      sed -i 's/DNS_SERVERS=\"\"/DNS_SERVERS=\"223.5.5.5 8.8.4.4\"/g' package/network/services/dnsmasq/files/dnsmasq.init
      echo "修改dnsmasq默认DNS服务器为223.5.5.5 8.8.4.4"
  fi
}

function add_adguardhome() {
  if [[ ! -d "files/usr/bin" ]]; then
    mkdir -p files/usr/bin
  fi
  # 复制AdGuardHome相关文件
  echo "添加AdGuardHome相关文件"
  cp $GITHUB_WORKSPACE/patches/custom/adguard_update_dhcp_leases.sh files/usr/bin/adguard_update_dhcp_leases.sh
}

function add_defaults_settings() {
  # 添加默认设置脚本
  if [[ ! -d "files/etc/uci-defaults" ]]; then
    mkdir -p files/etc/uci-defaults
  fi
  cp $GITHUB_WORKSPACE/patches/custom/init-settings.sh files/etc/uci-defaults/99-init-settings
}

function add_dae() {
  remove_package dae luci-app-dae
  cp -rv $GITHUB_WORKSPACE/patches/custom/package/dae ./package/
  cp -rv $GITHUB_WORKSPACE/patches/custom/package/luci-app-dae ./package/
  echo "CONFIG_PACKAGE_luci-app-dae=y" >> $config_file
}

function add_geodata() {
  remove_package v2ray-geodata
  cp -rv $GITHUB_WORKSPACE/patches/custom/package/v2ray-geodata ./package/
  echo "CONFIG_PACKAGE_v2ray-geodata-updater=y" >> $config_file
  echo "CONFIG_PACKAGE_v2ray-geodata=y" >> $config_file
}

function add_mosdns() {
  remove_package mosdns luci-app-mosdns v2dat
  git_sparse_clone v5 https://github.com/sbwml/luci-app-mosdns \
      mosdns luci-app-mosdns v2dat
  echo "CONFIG_PACKAGE_luci-app-mosdns=y" >> $config_file
}

function add_netspeedtest() {
  remove_package luci-app-netspeedtest
  git_sparse_clone js https://github.com/sirpdboy/luci-app-netspeedtest \
      luci-app-netspeedtest netspeedtest homebox speedtest-cli
  echo "CONFIG_PACKAGE_luci-app-netspeedtest=y" >> $config_file
}

function add_wechatpush(){
  remove_package luci-app-wechatpush
  git clone --depth=1 -b master https://github.com/tty228/luci-app-wechatpush package/luci-app-wechatpush
  # fix wechatpush build
  git_sparse_clone main https://github.com/kiddin9/kwrt-packages \
      wrtbwmon
  echo "CONFIG_PACKAGE_luci-app-wechatpush=y" >> $config_file
}

function add_taskplan() {
  remove_package luci-app-taskplan
  git_sparse_clone master https://github.com/sirpdboy/luci-app-taskplan \
      luci-app-taskplan
  echo "CONFIG_PACKAGE_luci-app-taskplan=y" >> $config_file
}

function add_msd_lite() { 
  remove_package msd_lite luci-app-msd_lite
  git_sparse_clone main https://github.com/kiddin9/kwrt-packages \
      msd_lite luci-app-msd_lite
  echo "CONFIG_PACKAGE_luci-app-msd-lite=y" >> $config_file

}

# 主要执行程序
# 解决配置文件未换行问题
echo "" >> $config_file
# add_dae
add_daed
set_theme
add_nps
add_watchdog
add_geodata
add_mosdns
add_netdata
add_adguardhome
add_netspeedtest
add_wechatpush
add_taskplan
add_msd_lite
add_other_package
add_defaults_settings
generate_config && cat $config_file