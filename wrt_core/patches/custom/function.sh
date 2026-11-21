#!/bin/bash
config_file=".config"
CUSTOM_PATCH_DIR="$GITHUB_WORKSPACE/wrt_core/patches/custom"
BASE_PATH=$1

CUSTOM_OP=https://github.com/caiwx86/small-packages
CUSTOM_OP_BRANCH=main

if [[ -d $BASE_PATH ]]; then
   BASE_PATH=$(cd $BASE_PATH && pwd)
   echo "BASE_PATH: $BASE_PATH"
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
CONFIG_CGROUP_BPF=y
CONFIG_NET_SCHED=y
CONFIG_NET_XGRESS=y
CONFIG_NET_NS=y
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

CONFIG_NET_SCH_BPF=y
CONFIG_SCHED_CLASS_EXT=y
CONFIG_PROBE_EVENTS_BTF_ARGS=y
CONFIG_IMX_SCMI_MISC_DRV=n
CONFIG_ARM64_CONTPTE=y

CONFIG_PERSISTENT_HUGE_ZERO_FOLIO=n
CONFIG_NO_PAGE_MAPCOUNT=n
CONFIG_ARM64_BRBE=y

# UDP
CONFIG_FUNCTION_TRACER=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_NF_TABLES=y
CONFIG_NF_TABLES_INET=y
CONFIG_NFT_CT=y
CONFIG_NFT_QUEUE=m
CONFIG_NETFILTER_NETLINK_QUEUE=m
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

CONFIG_KERNEL_TRANSPARENT_HUGEPAGE=y
# CONFIG_KERNEL_TRANSPARENT_HUGEPAGE_ALWAYS is not set
CONFIG_KERNEL_TRANSPARENT_HUGEPAGE_MADVISE=y
# CONFIG_KERNEL_TRANSPARENT_HUGEPAGE_NEVER is not set
EOF
}

kernel_version() { echo $(sed -n 's/^KERNEL_PATCHVER:=\(.*\)/\1/p' target/linux/qualcommax/Makefile); }

function set_kernel_size() {
  #修改jdc ax1800 pro 的内核大小为12M
  image_file='./target/linux/qualcommax/image/ipq60xx.mk'
  sed -i "/^define Device\/emmc-common/,/^endef/ s/KERNEL_SIZE := 6144k/KERNEL_SIZE := 12288k/" $image_file
  sed -i "/^define Device\/nand-common/,/^endef/ s/^endef/\tKERNEL_SIZE := 8192k\nendef/" $image_file
  sed -i "/^define Device\/jdcloud_re-ss-01/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" $image_file
  sed -i "/^define Device\/jdcloud_re-cs-02/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" $image_file
  sed -i "/^define Device\/jdcloud_re-cs-07/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" $image_file
#  sed -i "/^define Device\/redmi_ax5-jdcloud/,/^endef/ s/^endef/  KERNEL_SIZE := 12288k\nendef/" $image_file
  sed -i "/^define Device\/linksys_mr/,/^endef/ { /KERNEL_SIZE := 8192k/s//KERNEL_SIZE := 12288k/ }" $image_file
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
  mv -f $@ $BASE_PATH/package
  cd $BASE_PATH && rm -rf $repodir
}

# 删除指定软件包
remove_package() {
    cd $BASE_PATH
    local pkg dir r i any roots=${PKG_ROOTS:-package feeds custom_feed}
    local -a hits

    for pkg in "$@"; do
        case $pkg in
            ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._+-]*) printf '非法包名: %q\n' "$pkg" >&2; continue ;;
        esac

        any=0; for r in $roots; do [ -d "$r" ] && any=1; done
        [ "$any" = 1 ] || { printf '没有 %s, 请 cd 到 OpenWrt 顶层或设 PKG_ROOTS\n' "$roots" >&2; return 1; }

        hits=()
        for r in $roots; do
            [ -d "$r" ] || continue
            while IFS= read -r -d '' dir; do
                [ -f "$dir/Makefile" ] && hits+=("$dir")
            done < <(find "$r/" -type d -name "$pkg" -print0 2>/dev/null)
        done

        [ ${#hits[@]} -gt 0 ] || { printf '  - %s 未找到\n' "$pkg"; continue; }

        for ((i = ${#hits[@]} - 1; i >= 0; i--)); do        # 深 → 浅
            dir=${hits[i]}; [ -d "$dir" ] || continue
            printf '删除: %s\n' "$dir"; rm -rf -- "$dir"
        done
    done
}

# 查找软件包中文件并替换
# $1: 文件夹路径
# $2: 文件匹配字符串
function find_replace() {
    cd $BASE_PATH
    file_path=$1
    package=$2
    pkg_path=$(find package feeds custom_feed -type d | grep "$package$")
    if [[ ! "$pkg_path" == "" ]]; then
        for dir_path in $pkg_path; do 
          cp -rv $file_path $pkg_path
          echo "$file_path 文件复制到 $pkg_path 成功"
        done
    fi 
}

_la_log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# 内部: 一次克隆 + 逐包写配置; 参数是最终要装的包名(已去重)
_la_install() {
	local pkg d ver cfg rm_yes="" nfound=0
	local t0=$SECONDS
	local -a pkgs=("$@")

	[ $# -gt 0 ] || return 0
	if [ -z "${CUSTOM_OP:-}" ] || [ -z "${CUSTOM_OP_BRANCH:-}" ]; then
		_la_log "CUSTOM_OP / CUSTOM_OP_BRANCH 未设置" >&2
		return 2
	fi
	cfg=${config_file:-.config}
	cd "${BASE_PATH:-}" 2>/dev/null || { _la_log "进不去 BASE_PATH=${BASE_PATH:-<空>}" >&2; return 2; }	
	
	remove_package ${pkgs[@]}
	
	_la_log "==> ${pkgs[*]}  源: $CUSTOM_OP  分支: $CUSTOM_OP_BRANCH"
	[ "${LOG_LEVEL:-info}" = debug ] && _la_log "[debug] git_sparse_clone $CUSTOM_OP_BRANCH $CUSTOM_OP ${pkgs[*]}"

	# 一次克隆所有包(批量比逐个快); 失败就整批不写配置
	if ! git_sparse_clone "$CUSTOM_OP_BRANCH" "$CUSTOM_OP" "${pkgs[@]}"; then
		_la_log "!! 拉取失败, 未写配置" >&2
		return 1
	fi

	for pkg in "${pkgs[@]}"; do
		d=$(find package -maxdepth 3 -type d -name "$pkg" -print -quit 2>/dev/null)
		ver=""
		if [ -n "$d" ]; then
			nfound=$((nfound + 1))
			ver=$(sed -nE 's/^[[:space:]]*PKG_VERSION[[:space:]]*[:+]?=[[:space:]]*//p' "$d/Makefile" 2>/dev/null | head -n 1)
			_la_log "✔ $d  (v${ver:-?})"
		else
			_la_log "! 没找到 package/**/$pkg (仍写入配置)" >&2
		fi

		# 去重: 已有 =y 就不再追加
		if grep -qxF "CONFIG_PACKAGE_$pkg=y" "$cfg" 2>/dev/null; then
			_la_log "= CONFIG_PACKAGE_$pkg=y 已存在"
		else
			printf 'CONFIG_PACKAGE_%s=y\n' "$pkg" >>"$cfg" || { _la_log "!! 写入 $cfg 失败" >&2; return 1; }
			_la_log "+ CONFIG_PACKAGE_$pkg=y"
		fi
	done

	[ "$nfound" -gt 0 ] || { _la_log "!! ${#pkgs[@]} 个包都没落地, 检查源/分支" >&2; return 1; }
	_la_log "完成 ${#pkgs[@]} 个, 用时 $((SECONDS - t0))s"
}

# 按原样安装: 传什么装什么; 传 luci-app-x 时顺带装 x
add_apps() {
	local p q seen=" "
	local -a want=()

	[ $# -gt 0 ] || { _la_log "add_apps: 缺少包名" >&2; return 2; }
	for p in "$@"; do
		[ -n "$p" ] || { _la_log "add_apps: 有空包名" >&2; return 2; }
		case $seen in *" $p "*) continue ;; esac
		seen="$seen$p "
		want+=("$p")
		case $p in
			luci-app-*)
				q="${p#luci-app-}"
				case $seen in *" $q "*) ;; *) seen="$seen$q "; want+=("$q") ;; esac
				;;
		esac
	done
	_la_install "${want[@]}"
}

# 添加 luci 应用: 短名/全名都算, 统一装 luci-app-x 和 x
add_luci_app() {
	local p
	local -a want=()

	[ $# -gt 0 ] || { _la_log "add_luci_app: 缺少包名" >&2; return 2; }
	for p in "$@"; do
		[ -n "$p" ] || { _la_log "add_luci_app: 有空包名" >&2; return 2; }
		want+=("luci-app-${p#luci-app-}")
	done
	add_apps "${want[@]}"
}

function add_other_package() {
  echo "添加其他通插件"
  # add other package
  #impitool
  echo "CONFIG_PACKAGE_ipmitool=y" >> $config_file
  # jq
  echo "CONFIG_PACKAGE_jq=y" >> $config_file
  # gdisk
  # echo "CONFIG_PACKAGE_gdisk=y" >> $config_file
  # luci-app-mwan3
  # echo "CONFIG_PACKAGE_luci-app-mwan3=y" >> $config_file
  
  ########################### 修改 DNSMASQ 配置 ###########################
  dnsmasq_config=package/network/services/dnsmasq/files/
  # 修改 DNSMASQ 53 端口为 253
  perl -i -pe 's/option port.*/option port 53/ if /config dnsmasq/../^config/; $_ .= "        option port             1253\n" if /option filter_aaaa\t0/ && !/option port/' $dnsmasq_config/dhcp.conf
  # DNSMASQ DNSSERVER
  if [[ -f "$dnsmasq_config/dnsmasq.init" ]]; then
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
  cp $CUSTOM_PATCH_DIR/adguard_update_dhcp_leases.sh files/usr/bin/adguard_update_dhcp_leases.sh

  add_luci_app adguardhome
  # add_apps adguardhome luci-app-adguardhome-tk && remove_package luci-app-adguardhome
}

function add_defaults_settings() {
  # 添加默认设置脚本
  if [[ ! -d "files/etc/uci-defaults" ]]; then
    mkdir -p files/etc/uci-defaults
  fi
  cp $CUSTOM_PATCH_DIR/init-settings.sh files/etc/uci-defaults/99-init-settings

  # 配置AdGuardHome相关文件
  find_replace $CUSTOM_PATCH_DIR/etc/AdGuardHome.yaml               luci-app-adguardhome/root/etc
   
  # 配置smartdns相关文件
  find_replace $CUSTOM_PATCH_DIR/etc/config/smartdns                smartdns/conf/smartdns.conf 

}

function add_geodata() {
  remove_package v2ray-geodata
  cp -rv $CUSTOM_PATCH_DIR/package/v2ray-geodata ./package/
  echo "CONFIG_PACKAGE_v2ray-geodata-updater=y" >> $config_file
  echo "CONFIG_PACKAGE_v2ray-geodata=y" >> $config_file
}

function add_netspeedtest() {
  remove_package luci-app-netspeedtest
  git clone https://github.com/muink/luci-app-netspeedtest ./package/luci-app-netspeedtest 
  echo "CONFIG_PACKAGE_luci-app-netspeedtest=y" >> $config_file
}

function add_wechatpush(){
  remove_package luci-app-wechatpush
  git_sparse_clone $CUSTOM_OP_BRANCH $CUSTOM_OP \
      luci-app-wechatpush
  # fix wechatpush build
  git_sparse_clone $CUSTOM_OP_BRANCH $CUSTOM_OP \
      wrtbwmon
  echo "CONFIG_PACKAGE_luci-app-wechatpush=y" >> $config_file
}

function add_ghfu() {
  remove_package luci-app-ghfu
  git_sparse_clone $CUSTOM_OP_BRANCH $CUSTOM_OP \
      luci-app-ghfu
  sed -i 's|smallprogram/OpenWrtAction|caiwx86/wrt_release|g' $BASE_PATH/package/luci-app-ghfu/root/etc/config/ghfu
  sed -i "s|set ghfu.main.github_repo='smallprogram/OpenWrtAction'|set ghfu.main.github_repo='caiwx86/wrt_release'|g" $PATH/package/luci-app-ghfu/root/etc/uci-defaults/99-ghfu-defaults
  echo "CONFIG_PACKAGE_luci-app-ghfu=y" >> $config_file
}

# 主要执行程序
# 解决配置文件未换行问题
echo "" >> $config_file
add_adguardhome
add_geodata
add_netspeedtest
add_wechatpush
add_ghfu
# add_daede() { add_apps dae daed luci-app-daede; }; add_daede
add_honk() { add_luci_app honk; }; add_honk
add_nps() { add_luci_app npc; remove_package nps; echo "CONFIG_PACKAGE_npc=y" >> $config_file; }; add_nps
add_watchdog() { add_luci_app watchdog; }; add_watchdog
# add_mosdns() { add_luci_app mosdns; add_apps geo2txt; }; add_mosdns
add_netdata() { add_luci_app netdata; }; add_netdata
add_taskplan() { add_apps luci-app-taskplan; }; add_taskplan
add_uugamebooster() { add_luci_app uugamebooster; }; add_uugamebooster
add_oxidns() { add_luci_app oxidns; echo "CONFIG_PACKAGE_oxidns-webui=y" >> $config_file; }; add_oxidns
# add_nikki() { add_luci_app nikki; }; add_nikki
# add_clashoo() { add_luci_app clashoo; }; add_clashoo
# add_msd_lite() { add_luci_app msd_lite;  }; add_msd_lite
# add_homeproxy() { add_luci_app homeproxy;  }; add_homeproxy
# add_openlist() { add_luci_app openlist2;  }; add_openlist
# add_turboacc() { add_apps luci-app-turboacc;  }; add_turboacc
# add_qbittorrent() { add_apps luci-app-qbittorrent;  }; add_qbittorrent
# add_transmission() { add_luci_app transmission; }; add_transmission
# add_smartdns() { add_luci_app smartdns; }; add_smartdns
# theme_shadcn()  { add_luci_app shadcn-theme; }; theme_shadcn
# theme_aurora() { add_apps luci-theme-aurora luci-app-aurora-config; }; theme_aurora
# theme_footstrap() { add_apps luci-theme-footstrap; }; theme_footstrap
remove_package luci-app-argon-config luci-app-oaf luci-app-pbr luci-app-vlmcsd luci-app-mosdns mosdns
remove_package cups luci-app-cupsd
add_other_package
set_menu() { bash $CUSTOM_PATCH_DIR/menu-reorg.sh;}; set_menu
add_defaults_settings
generate_config && cat $config_file
