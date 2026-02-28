#!/bin/bash
#aminsire@qq.com
# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 标记文件路径（用于判断是否由本脚本安装）
INSTALL_FLAG="/etc/.smartctl_installed_by_script"
SELECTED_DISK=""
DISK_CANDIDATES=()
SPEED_TEST_FILE=""

# 检查权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}${BOLD}错误:${NC} 请使用 sudo 运行此脚本。"
  exit 1
fi

# ----------------- 基础命令检查 -----------------
check_basic_cmds() {
    local cmds=("lsblk" "df" "awk" "grep" "bc" "dd" "seq")
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}${BOLD}致命错误:${NC} 系统缺少基础命令: ${YELLOW}$cmd${NC}"
            echo -e "请确保系统已安装包含该命令的基础工具包 (如 coreutils, bc 等)。"
            exit 1
        fi
    done
}

# ----------------- 依赖管理 (环境检查 + 手动决策) -----------------
check_dependency_status() {
    if command -v smartctl &> /dev/null; then
        if [ -f "$INSTALL_FLAG" ]; then
            echo -e "${GREEN}依赖状态:${NC} smartmontools 已安装（由本脚本安装）"
        else
            echo -e "${GREEN}依赖状态:${NC} smartmontools 已安装（系统或手动安装）"
        fi
        return
    fi

    # smartctl 不存在但标记文件还在，说明可能是陈旧标记，启动时顺带清理。
    [ -f "$INSTALL_FLAG" ] && rm -f "$INSTALL_FLAG"
    echo -e "${YELLOW}依赖状态:${NC} 未安装 smartmontools（可在菜单 4 手动安装）"
}

install_deps() {
    if command -v smartctl &> /dev/null; then
        echo -e "${GREEN}smartmontools 已存在，无需安装。${NC}"
        return
    fi

    echo -e "${RED}${BOLD}警告:${NC} 即将执行系统级安装操作。"
    read -p "确认安装 smartmontools? (y/n): " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo -e "${YELLOW}已取消安装。${NC}"
        return
    fi

    echo -e "${BLUE}正在安装...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y smartmontools && touch "$INSTALL_FLAG"
    elif command -v yum &> /dev/null; then
        yum install -y smartmontools && touch "$INSTALL_FLAG"
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm smartmontools && touch "$INSTALL_FLAG"
    elif command -v apk &> /dev/null; then
        apk add smartmontools && touch "$INSTALL_FLAG"
    else
        echo -e "${RED}未支持的包管理器，请手动安装 smartmontools。${NC}"
        return
    fi

    if command -v smartctl &> /dev/null; then
        echo -e "${GREEN}安装成功并已记录标记。${NC}"
    else
        echo -e "${RED}安装失败，请检查包管理器输出。${NC}"
    fi
}

uninstall_deps() {
    if ! command -v smartctl &> /dev/null; then
        echo -e "${YELLOW}smartmontools 当前未安装，无需卸载。${NC}"
        [ -f "$INSTALL_FLAG" ] && rm -f "$INSTALL_FLAG"
        return
    fi

    if [ ! -f "$INSTALL_FLAG" ]; then
        echo -e "${RED}拒绝操作：检测到 smartmontools 是系统自带或手动安装的，脚本无权卸载。${NC}"
        return
    fi

    echo -e "${RED}${BOLD}警告：${NC}即将卸载由本脚本安装的 smartmontools。"
    read -p "确认卸载? (y/n): " confirm
    if [[ "$confirm" == [yY] ]]; then
        if command -v apt-get &> /dev/null; then
            apt-get remove -y smartmontools && rm -f "$INSTALL_FLAG"
        elif command -v yum &> /dev/null; then
            yum remove -y smartmontools && rm -f "$INSTALL_FLAG"
        elif command -v pacman &> /dev/null; then
            pacman -Rs --noconfirm smartmontools && rm -f "$INSTALL_FLAG"
        elif command -v apk &> /dev/null; then
            apk del smartmontools && rm -f "$INSTALL_FLAG"
        fi
        echo -e "${GREEN}卸载完成，标记已清除。${NC}"
    fi
}

dependency_menu() {
    while true; do
        echo -e "\n${CYAN}----------- 依赖管理 (高风险) -----------${NC}"
        if command -v smartctl &> /dev/null; then
            if [ -f "$INSTALL_FLAG" ]; then
                echo -e "  当前状态: ${GREEN}已安装${NC} (由脚本安装)"
            else
                echo -e "  当前状态: ${GREEN}已安装${NC} (系统/手动安装)"
            fi
        else
            echo -e "  当前状态: ${YELLOW}未安装${NC}"
        fi
        echo -e "  ${BLUE}1.${NC} 安装 smartmontools"
        echo -e "  ${BLUE}2.${NC} 卸载脚本安装的 smartmontools"
        echo -e "  ${BLUE}b.${NC} 返回主菜单"
        read -p "请输入选项: " dep_opt

        case $dep_opt in
            1) install_deps ;;
            2) uninstall_deps ;;
            b|B) break ;;
            *) echo -e "${RED}无效输入${NC}" ;;
        esac
    done
}

# ----------------- 进度条绘制 -----------------
draw_progress() {
    local percent=$1
    local label=$2
    [ $percent -gt 100 ] && percent=100
    [ $percent -lt 0 ] && percent=0

    local filled=$((percent / 10))
    local empty=$((10 - filled))
    local color=$GREEN
    [ $percent -ge 70 ] && color=$YELLOW
    [ $percent -ge 90 ] && color=$RED

    # 将字符换为 # 和 - 以解决部分终端乱码问题
    local bar=$(printf "%${filled}s" | tr ' ' '#')$(printf "%${empty}s" | tr ' ' '-')
    printf "${BOLD}%-15s${NC}: ${color}[%s] %d%%${NC}\n" "$label" "$bar" "$percent"
}

health_color_for_status() {
    local status="$1"
    if echo "$status" | grep -qiE 'OK|PASSED|GOOD|HEALTHY'; then
        echo "$GREEN"
    elif echo "$status" | grep -qiE 'FAIL|FAILED|BAD|CRIT|ERROR|DEGRADED'; then
        echo "$RED"
    else
        echo "$YELLOW"
    fi
}

cleanup_speed_test_file() {
    [ -n "$SPEED_TEST_FILE" ] && rm -f "$SPEED_TEST_FILE" 2>/dev/null
}

clear_speed_test_cleanup() {
    trap - INT TERM EXIT
    SPEED_TEST_FILE=""
}

apply_cache_policy() {
    local mode="$1"
    sync
    if [ "$mode" = "drop" ]; then
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    fi
}

# ----------------- RAID 检测与提示 -----------------
is_raid_model() {
    local model="$1"
    echo "$model" | grep -qiE 'PERC|MegaRAID|RAID|Virtual Disk'
}

show_raid_notice() {
    local disk="$1"
    local model="$2"
    echo -e "${YELLOW}${BOLD}提示:${NC} 当前选择的是 RAID 控制器导出的逻辑盘。"
    echo -e "  设备: ${CYAN}${disk}${NC}  型号: ${CYAN}${model}${NC}"
    echo -e "  这不是单块物理硬盘，健康信息可能与实际物理盘不一一对应。"
    echo -e "  若需逐块物理盘诊断，请使用 ${BOLD}perccli/storcli${NC}，或 smartctl 的 ${BOLD}-d megaraid,N${NC}。"
}

show_raid_scope_notice() {
    if command -v perccli64 &> /dev/null || command -v perccli &> /dev/null || command -v storcli64 &> /dev/null || command -v storcli &> /dev/null; then
        echo -e "  ${YELLOW}提示:${NC} 当前为控制器级扫描结果。若需“逻辑盘->物理盘”精确映射，请结合 perccli/storcli。"
    else
        echo -e "  ${YELLOW}提示:${NC} 当前为控制器级扫描，可能包含其他逻辑盘成员；未安装 perccli/storcli 时无法精确映射。"
    fi
}

is_valid_raid_smart_output() {
    local raw="$1"
    echo "$raw" | grep -qiE "Device Id:|Serial Number:|Model Number:|Device Model:|Product:|SMART support is:|SMART Health Status:|Percentage Used:|Power_On_Hours|Rotation Rate:"
}

fetch_raid_smart() {
    local disk="$1"
    local idx="$2"
    local raw=""

    raw=$(smartctl -a -d "megaraid,$idx" "$disk" 2>/dev/null)
    if is_valid_raid_smart_output "$raw"; then
        echo "$raw"
        return 0
    fi

    raw=$(smartctl -a -d "sat+megaraid,$idx" "$disk" 2>/dev/null)
    if is_valid_raid_smart_output "$raw"; then
        echo "$raw"
        return 0
    fi

    return 1
}

check_raid_physical_health() {
    local disk="$1"
    local found=0
    local miss_after_found=0
    local idx raw_smart

    if ! command -v smartctl &> /dev/null; then
        echo -e "  ${RED}错误: 未安装 smartmontools${NC}"
        echo -e "  ${YELLOW}请在主菜单 4 手动安装，或通过包管理器安装${NC}"
        return
    fi

    echo -e "  磁盘类型: ${CYAN}RAID 逻辑盘（尝试枚举物理盘 SMART）${NC}"
    echo -e "  ${YELLOW}扫描范围: megaraid,0..31 (只读)${NC}"
    show_raid_scope_notice
    echo -e "------------------------------------------"

    for idx in $(seq 0 31); do
        raw_smart=$(fetch_raid_smart "$disk" "$idx")
        if [ -z "$raw_smart" ]; then
            if [ "$found" -eq 1 ]; then
                miss_after_found=$((miss_after_found + 1))
                [ "$miss_after_found" -ge 8 ] && break
            fi
            continue
        fi

        found=1
        miss_after_found=0

        local device_id model vendor serial rotation media health power_hours pct_used temperature
        device_id=$(echo "$raw_smart" | grep -m1 -i "^Device Id:" | awk -F: '{print $2}' | xargs)
        [ -z "$device_id" ] && device_id="$idx"

        model=$(echo "$raw_smart" | grep -m1 -iE "^(Model Number|Device Model|Product):" | awk -F: '{print $2}' | xargs)
        vendor=$(echo "$raw_smart" | grep -m1 -i "^Vendor:" | awk -F: '{print $2}' | xargs)
        [ -z "$model" ] && model="$vendor"
        [ -z "$model" ] && model="未知"

        serial=$(echo "$raw_smart" | grep -m1 -i "^Serial Number:" | awk -F: '{print $2}' | xargs)
        [ -z "$serial" ] && serial="未知"

        rotation=$(echo "$raw_smart" | grep -m1 -i "^Rotation Rate:" | awk -F: '{print $2}' | xargs)
        pct_used=$(echo "$raw_smart" | grep -m1 -i "Percentage Used" | awk -F: '{print $2}' | tr -d '% ' | tr -cd '0-9')
        power_hours=$(echo "$raw_smart" | grep -m1 -i "Power_On_Hours" | awk '{print $NF}' | tr -cd '0-9')
        [ -z "$power_hours" ] && power_hours=$(echo "$raw_smart" | grep -m1 -i "Power on Hours" | awk -F: '{print $2}' | tr -cd '0-9')

        health=$(echo "$raw_smart" | grep -m1 -iE "SMART overall-health self-assessment test result|SMART Health Status" | awk -F: '{print $2}' | xargs)
        [ -z "$health" ] && health="未知"

        temperature=$(echo "$raw_smart" | grep -m1 -i "Current Drive Temperature" | awk -F: '{print $2}' | tr -cd '0-9')
        [ -z "$temperature" ] && temperature=$(echo "$raw_smart" | grep -m1 -i "Temperature_Celsius" | awk '{print $10}' | tr -cd '0-9')
        [ -z "$temperature" ] && temperature=$(echo "$raw_smart" | grep -m1 -i "^Temperature:" | awk -F: '{print $2}' | tr -cd '0-9')

        media="未知"
        if echo "$rotation" | grep -qi "Solid State"; then
            media="SSD"
        elif echo "$rotation" | grep -qi "rpm"; then
            media="HDD (${rotation})"
        elif [ -n "$pct_used" ]; then
            media="SSD (推断)"
        fi

        local health_color
        health_color=$(health_color_for_status "$health")

        echo -e "  ${BOLD}物理盘槽位 megaraid,${device_id}${NC}"
        echo -e "    型号: ${PURPLE}${model}${NC}"
        echo -e "    序列号: ${CYAN}${serial}${NC}"
        echo -e "    介质类型: ${YELLOW}${media}${NC}"
        echo -e "    健康状态: ${health_color}${health}${NC}"
        [ -n "$power_hours" ] && echo -e "    通电时间: ${YELLOW}${power_hours} 小时${NC}"
        [ -n "$temperature" ] && echo -e "    温度: ${YELLOW}${temperature}°C${NC}"

        if [ -n "$pct_used" ]; then
            local remaining=$((100 - pct_used))
            [ "$remaining" -lt 0 ] && remaining=0
            [ "$remaining" -gt 100 ] && remaining=100
            draw_progress "$pct_used" "寿命已用"
            echo -e "    剩余健康度: ${GREEN}${remaining}%${NC}"
        fi
        echo -e "------------------------------------------"
    done

    if [ "$found" -eq 0 ]; then
        echo -e "  ${RED}未扫描到可解析的 RAID 物理盘 SMART 信息。${NC}"
        echo -e "  ${YELLOW}可手动尝试: smartctl -a -d megaraid,0 ${disk}${NC}"
        echo -e "  ${YELLOW}若仍失败，建议安装 perccli/storcli 查看控制器物理盘信息。${NC}"
    fi
}

is_risky_speed_mount() {
    local mp="$1"
    case "$mp" in
        /boot|/boot/*|/efi|/efi/*) return 0 ;;
        *) return 1 ;;
    esac
}

choose_speed_test_mountpoint() {
    local disk="$1"
    local min_free_mb=200
    local mp avail
    local best_mp=""
    local best_avail=0

    while IFS= read -r mp; do
        [ -z "$mp" ] && continue
        [ "$mp" = "[SWAP]" ] && continue
        [ ! -d "$mp" ] && continue
        [ ! -w "$mp" ] && continue
        is_risky_speed_mount "$mp" && continue

        avail=$(df -Pm "$mp" 2>/dev/null | awk 'NR==2 {print $4}')
        [[ "$avail" =~ ^[0-9]+$ ]] || continue

        if [ "$avail" -ge "$min_free_mb" ] && [ "$avail" -gt "$best_avail" ]; then
            best_avail="$avail"
            best_mp="$mp"
        fi
    done < <(lsblk -n -o MOUNTPOINT "$disk" "$disk"* 2>/dev/null | awk 'NF' | sort -u)

    [ -n "$best_mp" ] && { echo "$best_mp"; return 0; }
    return 1
}

# ----------------- 磁盘列表（过滤虚拟设备） -----------------
list_selectable_disks() {
    DISK_CANDIDATES=()
    local name size type model

    while read -r name size type model; do
        [ -z "$name" ] && continue
        [ "$type" != "disk" ] && continue
        case "$name" in
            loop*|ram*|zram*) continue ;;
        esac

        DISK_CANDIDATES+=("$name")
        if is_raid_model "$model"; then
            printf "%d) /dev/%s [%s] %s [RAID逻辑盘]\n" "${#DISK_CANDIDATES[@]}" "$name" "$size" "$model"
        else
            printf "%d) /dev/%s [%s] %s\n" "${#DISK_CANDIDATES[@]}" "$name" "$size" "$model"
        fi
    done < <(lsblk -d -n -o NAME,SIZE,TYPE,MODEL 2>/dev/null)

    if [ "${#DISK_CANDIDATES[@]}" -eq 0 ]; then
        echo -e "${RED}未发现可用的物理磁盘设备。${NC}"
    fi
}

# ----------------- 健康度解析 -----------------
check_health() {
    [ -z "$SELECTED_DISK" ] && { echo -e "${RED}请先选择磁盘！${NC}"; return; }
    
    # 获取容量信息
    local total_size=$(lsblk -d -n -o SIZE "$SELECTED_DISK")

    echo -e "\n${BLUE}${BOLD}┏━━━━ 磁盘详细健康档案 ━━━━┓${NC}"
    echo -e "  设备路径: ${YELLOW}$SELECTED_DISK${NC}"
    echo -e "  总 容 量: ${CYAN}$total_size${NC}"
    echo -e "------------------------------------------"

    local selected_model=$(lsblk -d -n -o MODEL "$SELECTED_DISK" 2>/dev/null | xargs)
    if is_raid_model "$selected_model"; then
        show_raid_notice "$SELECTED_DISK" "${selected_model:-未知}"
        echo -e "------------------------------------------"
        check_raid_physical_health "$SELECTED_DISK"
        echo -e "${BLUE}${BOLD}┗━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
        return
    fi

    if [[ "$SELECTED_DISK" == *"/mmcblk"* ]]; then
        # ===================== eMMC 逻辑 =====================
        local sys_path lifetime val_a val_b max_val
        echo -e "  磁盘类型: ${CYAN}eMMC 存储${NC}"
        local disk_base=$(basename "$SELECTED_DISK")
        sys_path="/sys/block/$disk_base/device"

        if [ ! -f "$sys_path/life_time" ]; then
            # 回退方案：按 mmc 主机号在 /sys/bus/mmc/devices 下查找
            local mmc_host=$(readlink -f "/sys/block/$disk_base/device" 2>/dev/null | grep -oE 'mmc[0-9]+' | head -n 1)
            if [ -n "$mmc_host" ]; then
                sys_path=$(find /sys/bus/mmc/devices/ -maxdepth 1 -type d -name "${mmc_host}:*" 2>/dev/null | head -n 1)
            fi
        fi

        if [ -n "$sys_path" ] && [ -f "$sys_path/life_time" ]; then
            lifetime=$(cat "$sys_path/life_time")
            val_a=$(( $(echo $lifetime | awk '{print $1}') ))
            val_b=$(( $(echo $lifetime | awk '{print $2}') ))
            draw_progress "$((val_a * 10))" "SLC 区域消耗"
            draw_progress "$((val_b * 10))" "MLC 区域消耗"
            max_val=$((val_b > val_a ? val_b : val_a))
            local emmc_remaining=$((100 - max_val * 10))
            [ "$emmc_remaining" -lt 0 ] && emmc_remaining=0
            [ "$emmc_remaining" -gt 100 ] && emmc_remaining=100
            echo -e "  ${BOLD}估算剩余寿命: ${GREEN}${emmc_remaining}%${NC}"
        else
            echo -e "  ${RED}错误: 无法读取 eMMC 寿命节点${NC}"
        fi
        
    elif [[ "$SELECTED_DISK" == *"nvme"* ]]; then
        # ===================== NVMe 逻辑 =====================
        echo -e "  磁盘类型: ${CYAN}NVMe SSD${NC}"
        
        if ! command -v smartctl &> /dev/null; then
            echo -e "  ${RED}错误: 未安装 smartmontools${NC}"
            echo -e "  ${YELLOW}请在主菜单 4 手动安装，或通过包管理器安装${NC}"
            echo -e "${BLUE}${BOLD}┗━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
            return
        fi
        
        # 获取 NVMe SMART 信息
        local raw_smart=$(smartctl -a "$SELECTED_DISK" 2>/dev/null)
        
        # 检查是否成功获取
        if [ -z "$raw_smart" ]; then
            echo -e "  ${RED}错误: 无法读取 SMART 信息${NC}"
            echo -e "${BLUE}${BOLD}┗━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
            return
        fi
        
        # 局部变量化以防污染全局
        local hours=$(echo "$raw_smart" | grep -i "Power On Hours" | awk -F: '{print $2}' | tr -d ', ')
        local pct_used=$(echo "$raw_smart" | grep -i "Percentage Used" | awk -F: '{print $2}' | tr -d '% ')
        local temperature=$(echo "$raw_smart" | grep -i "Temperature:" | head -1 | awk -F: '{print $2}' | awk '{print $1}')
        local avail_spare=$(echo "$raw_smart" | grep -i "Available Spare:" | awk -F: '{print $2}' | tr -d '% ')
        local power_cycles=$(echo "$raw_smart" | grep -i "Power Cycles" | awk -F: '{print $2}' | tr -d ', ')
        local data_written=$(echo "$raw_smart" | grep -i "Data Units Written" | awk -F: '{print $2}' | sed 's/\[.*\]//' | tr -d ', ')
        local data_read=$(echo "$raw_smart" | grep -i "Data Units Read" | awk -F: '{print $2}' | sed 's/\[.*\]//' | tr -d ', ')
        local model=$(echo "$raw_smart" | grep -i "Model Number" | awk -F: '{print $2}' | xargs)
        local firmware=$(echo "$raw_smart" | grep -i "Firmware Version" | awk -F: '{print $2}' | xargs)
        
        # 显示型号和固件
        [ -n "$model" ] && echo -e "  型    号: ${PURPLE}$model${NC}"
        [ -n "$firmware" ] && echo -e "  固件版本: ${PURPLE}$firmware${NC}"
        echo -e "------------------------------------------"
        
        # 显示通电时间
        if [ -n "$hours" ]; then
            local hours_num=$(echo "$hours" | tr -cd '0-9')
            if [ -n "$hours_num" ]; then
                local days=$((hours_num / 24))
                echo -e "  通电时间: ${YELLOW}$hours_num 小时${NC} (约 $days 天)"
            else
                echo -e "  通电时间: ${YELLOW}$hours${NC}"
            fi
        else
            echo -e "  通电时间: ${YELLOW}未知${NC}"
        fi
        
        # 显示电源周期
        [ -n "$power_cycles" ] && echo -e "  开关次数: ${YELLOW}$(echo $power_cycles | tr -cd '0-9') 次${NC}"
        
        # 显示温度：优先使用当前 NVMe 设备的 hwmon，回退到 smartctl
        local nvme_name=$(basename "$SELECTED_DISK" | sed -E 's/n[0-9]+$//')  # nvme0 / nvme1 / ...
        local composite="" sensor1="" sensor2=""
        local temp_input raw_temp temp_val idx label_file label

        for temp_input in /sys/class/nvme/"$nvme_name"/device/hwmon/hwmon*/temp*_input; do
            [ -f "$temp_input" ] || continue

            raw_temp=$(cat "$temp_input" 2>/dev/null)
            [[ "$raw_temp" =~ ^[0-9]+$ ]] || continue
            temp_val=$(awk "BEGIN{printf \"%.1f\", $raw_temp/1000}")

            idx=$(basename "$temp_input" | sed -E 's/temp([0-9]+)_input/\1/')
            label_file="${temp_input%_input}_label"
            label=""
            [ -f "$label_file" ] && label=$(cat "$label_file" 2>/dev/null)

            case "$(echo "$label" | tr '[:upper:]' '[:lower:]')" in
                composite) composite="$temp_val" ;;
                "sensor 1") sensor1="$temp_val" ;;
                "sensor 2") sensor2="$temp_val" ;;
                *)
                    # 无 label 时，temp1 通常是 Composite
                    [ "$idx" = "1" ] && [ -z "$composite" ] && composite="$temp_val"
                    ;;
            esac
        done

        # hwmon 不完整时，回退到 smartctl 同设备字段
        [ -z "$composite" ] && composite=$(echo "$temperature" | tr -cd '0-9.')
        [ -z "$sensor1" ] && sensor1=$(echo "$raw_smart" | grep -m1 -i "Temperature Sensor 1" | awk -F: '{print $2}' | tr -cd '0-9.')
        [ -z "$sensor2" ] && sensor2=$(echo "$raw_smart" | grep -m1 -i "Temperature Sensor 2" | awk -F: '{print $2}' | tr -cd '0-9.')

        if [ -n "$composite" ]; then
            local comp_int=${composite%.*}
            local comp_color=$GREEN
            [ "$comp_int" -ge 50 ] && comp_color=$YELLOW
            [ "$comp_int" -ge 70 ] && comp_color=$RED
            echo -e "  综合温度: ${comp_color}${composite}°C${NC}"
        fi

        # Sensor 1 / 2 为设备厂商定义，常见含义分别为 NAND/主控
        if [ -n "$sensor1" ]; then
            local s1_int=${sensor1%.*}
            local s1_color=$GREEN
            [ "$s1_int" -ge 60 ] && s1_color=$YELLOW
            [ "$s1_int" -ge 70 ] && s1_color=$RED
            echo -e "  NAND温度: ${s1_color}${sensor1}°C${NC} (Sensor 1)"
        fi

        if [ -n "$sensor2" ]; then
            local s2_int=${sensor2%.*}
            local s2_color=$GREEN
            [ "$s2_int" -ge 60 ] && s2_color=$YELLOW
            [ "$s2_int" -ge 70 ] && s2_color=$RED
            echo -e "  主控温度: ${s2_color}${sensor2}°C${NC} (Sensor 2)"
        fi
        
        echo -e "------------------------------------------"
        
        # 显示寿命百分比 (核心指标)
        if [ -n "$pct_used" ]; then
            local pct_num=$(echo "$pct_used" | tr -cd '0-9')
            if [ -n "$pct_num" ]; then
                draw_progress "$pct_num" "寿命已用"
                local remaining=$((100 - pct_num))
                [ "$remaining" -lt 0 ] && remaining=0
                [ "$remaining" -gt 100 ] && remaining=100
                local health_color=$GREEN
                [ "$remaining" -le 30 ] && health_color=$YELLOW
                [ "$remaining" -le 10 ] && health_color=$RED
                echo -e "  ${BOLD}剩余健康度: ${health_color}${remaining}%${NC}"
            fi
        else
            echo -e "  ${YELLOW}寿命信息: 此 NVMe 未提供 Percentage Used 字段${NC}"
        fi
        
        # 显示备用空间
        if [ -n "$avail_spare" ]; then
            local spare_num=$(echo "$avail_spare" | tr -cd '0-9')
            [ -n "$spare_num" ] && echo -e "  备用空间: ${GREEN}${spare_num}%${NC}"
        fi
        
        # 显示读写量 (如果有)
        if [ -n "$data_written" ]; then
            local written_num=$(echo "$data_written" | tr -cd '0-9')
            if [ -n "$written_num" ] && [ "$written_num" -gt 0 ]; then
                # 每个 Data Unit = 512KB = 0.5MB
                local written_tb=$(echo "scale=2; $written_num * 512 / 1024 / 1024 / 1024" | bc 2>/dev/null)
                [ -n "$written_tb" ] && echo -e "  总写入量: ${PURPLE}${written_tb} TB${NC}"
            fi
        fi
        
    else
        # ===================== SATA/USB 逻辑 =====================
        echo -e "  磁盘类型: ${CYAN}SATA HDD/SSD 或 USB${NC}"
        
        if ! command -v smartctl &> /dev/null; then
            echo -e "  ${RED}错误: 未安装 smartmontools${NC}"
            echo -e "  ${YELLOW}请在主菜单 4 手动安装，或通过包管理器安装${NC}"
            echo -e "${BLUE}${BOLD}┗━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
            return
        fi
        
        local raw_smart=$(smartctl -a "$SELECTED_DISK" 2>/dev/null)
        
        # SATA 格式解析 (属性表格式)
        local hours=$(echo "$raw_smart" | grep -i "Power_On_Hours" | awk '{print $NF}')
        local rem_pct=$(echo "$raw_smart" | grep -i "Wear_Leveling_Count" | awk '{print $4}')
        local temperature=$(echo "$raw_smart" | grep -i "Temperature_Celsius" | awk '{print $10}')
        local reallocated=$(echo "$raw_smart" | grep -i "Reallocated_Sector" | awk '{print $NF}')
        local pending=$(echo "$raw_smart" | grep -i "Current_Pending_Sector" | awk '{print $NF}')
        local model=$(echo "$raw_smart" | grep -i "Device Model" | awk -F: '{print $2}' | xargs)
        
        [ -n "$model" ] && echo -e "  型    号: ${PURPLE}$model${NC}"
        echo -e "------------------------------------------"
        
        # 通电时间
        if [ -n "$hours" ] && [[ "$hours" =~ ^[0-9]+$ ]]; then
            local days=$((hours / 24))
            echo -e "  通电时间: ${YELLOW}$hours 小时${NC} (约 $days 天)"
        else
            echo -e "  通电时间: ${YELLOW}未知${NC}"
        fi
        
        # 温度
        if [ -n "$temperature" ] && [[ "$temperature" =~ ^[0-9]+$ ]]; then
            local temp_color=$GREEN
            [ "$temperature" -ge 45 ] && temp_color=$YELLOW
            [ "$temperature" -ge 55 ] && temp_color=$RED
            echo -e "  当前温度: ${temp_color}${temperature}°C${NC}"
        fi
        
        # 重映射扇区 (硬盘健康关键指标)
        if [ -n "$reallocated" ] && [[ "$reallocated" =~ ^[0-9]+$ ]]; then
            local realloc_color=$GREEN
            [ "$reallocated" -gt 0 ] && realloc_color=$YELLOW
            [ "$reallocated" -gt 100 ] && realloc_color=$RED
            echo -e "  重映射扇区: ${realloc_color}$reallocated${NC}"
        fi
        
        # 待处理扇区
        if [ -n "$pending" ] && [[ "$pending" =~ ^[0-9]+$ ]] && [ "$pending" -gt 0 ]; then
            echo -e "  ${RED}待处理扇区: $pending (警告！)${NC}"
        fi
        
        echo -e "------------------------------------------"
        
        # SSD 寿命 (如果有 Wear_Leveling_Count)
        if [ -n "$rem_pct" ] && [[ "$rem_pct" =~ ^[0-9]+$ ]]; then
            draw_progress "$((100 - rem_pct))" "寿命已用"
            echo -e "  ${BOLD}剩余健康度: ${GREEN}${rem_pct}%${NC}"
        else
            # 检查是否是 HDD
            local rotation=$(echo "$raw_smart" | grep -i "Rotation Rate" | awk -F: '{print $2}')
            if [[ "$rotation" == *"rpm"* ]]; then
                echo -e "  ${CYAN}机械硬盘无寿命百分比指标${NC}"
            else
                echo -e "  ${YELLOW}未能获取寿命百分比信息${NC}"
            fi
        fi
    fi
    
    echo -e "${BLUE}${BOLD}┗━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
}

# ----------------- 测速功能 -----------------
test_speed() {
    [ -z "$SELECTED_DISK" ] && { echo -e "${RED}请先选择磁盘！${NC}"; return; }
    
    echo -e "\n${PURPLE}--- 性能测试 (100MB) ---${NC}"
    echo -e "  选中磁盘: ${YELLOW}$SELECTED_DISK${NC}"
    local selected_model=$(lsblk -d -n -o MODEL "$SELECTED_DISK" 2>/dev/null | xargs)
    local speed_mode="rw"
    local cache_mode="safe"
    local is_raid=0

    if is_raid_model "$selected_model"; then
        is_raid=1
        echo -e "${YELLOW}${BOLD}RAID 风险提示:${NC} 当前是 RAID 逻辑盘，测速会对阵列产生 I/O 压力。"
        read -p "是否继续测速? (y/n): " confirm_raid
        if [[ "$confirm_raid" != [yY] ]]; then
            echo -e "${YELLOW}已取消测速。${NC}"
            return
        fi

        echo -e "  请选择 RAID 测速模式:"
        echo -e "    1) 只读测速 ${GREEN}[推荐: 不写入文件，不清缓存]${NC}"
        echo -e "    2) 读写测速 ${YELLOW}[会写入临时文件并清缓存]${NC}"
        read -p "请输入模式编号 [1/2, 默认1]: " mode_opt
        case "$mode_opt" in
            2) speed_mode="rw" ;;
            *) speed_mode="ro" ;;
        esac

        if [ "$speed_mode" = "rw" ]; then
            read -p "确认执行 RAID 读写测速? (y/n): " confirm_rw
            if [[ "$confirm_rw" != [yY] ]]; then
                echo -e "${YELLOW}已取消测速。${NC}"
                return
            fi

            echo -e "  请选择缓存策略:"
            echo -e "    1) 不清缓存 ${GREEN}[推荐: 在线业务更稳]${NC}"
            echo -e "    2) 清缓存 ${YELLOW}[更接近裸盘, 但会影响整机缓存]${NC}"
            read -p "请输入策略编号 [1/2, 默认1]: " cache_opt
            case "$cache_opt" in
                2) cache_mode="drop" ;;
                *) cache_mode="safe" ;;
            esac
        fi
    fi

    # 非 RAID：读写测速前增加确认和缓存策略选择
    if [ "$is_raid" -eq 0 ]; then
        echo -e "${YELLOW}${BOLD}风险提示:${NC} 即将执行读写测速，会在挂载点写入 100MB 临时文件。"
        read -p "确认继续? (y/n): " confirm_nonraid_rw
        if [[ "$confirm_nonraid_rw" != [yY] ]]; then
            echo -e "${YELLOW}已取消测速。${NC}"
            return
        fi

        echo -e "  请选择缓存策略:"
        echo -e "    1) 不清缓存 ${GREEN}[推荐: 在线业务更稳]${NC}"
        echo -e "    2) 清缓存 ${YELLOW}[更接近裸盘, 但会影响整机缓存]${NC}"
        read -p "请输入策略编号 [1/2, 默认1]: " cache_opt
        case "$cache_opt" in
            2) cache_mode="drop" ;;
            *) cache_mode="safe" ;;
        esac
    fi

    if [ "$speed_mode" = "ro" ]; then
        echo -e "  测速模式: ${GREEN}只读测速${NC}"
        echo -e "  读取目标: ${CYAN}$SELECTED_DISK${NC} (原始块设备)"
        echo -e "------------------------------------------"

        sync
        echo -n "  读取速度(只读): "
        local read_result
        read_result=$(dd if="$SELECTED_DISK" of=/dev/null bs=1M count=100 iflag=direct 2>&1)
        if [ $? -ne 0 ]; then
            echo -e "\n  ${YELLOW}direct 读取失败，回退标准读取模式...${NC}"
            read_result=$(dd if="$SELECTED_DISK" of=/dev/null bs=1M count=100 2>&1)
        fi
        local read_speed=$(echo "$read_result" | grep -oE '[0-9.]+ [MG]B/s' | tail -1)
        if [ -n "$read_speed" ]; then
            echo -e "${GREEN}$read_speed${NC}"
        else
            local read_time=$(echo "$read_result" | grep -oE '[0-9.]+ s,' | head -1 | tr -d ' s,')
            if [ -n "$read_time" ] && [ "$read_time" != "0" ]; then
                local calc_speed=$(echo "scale=2; 100 / $read_time" | bc 2>/dev/null)
                echo -e "${GREEN}${calc_speed:-未知} MB/s${NC}"
            else
                echo -e "${RED}测试失败${NC}"
            fi
        fi

        echo -e "------------------------------------------"
        echo -e "${GREEN}只读测速完成！${NC}"
        return
    fi
    
    # 选择安全的测速挂载点（避免 /boot/efi 等引导分区）
    local mount_point=""
    mount_point=$(choose_speed_test_mountpoint "$SELECTED_DISK")
    
    if [ -z "$mount_point" ]; then
        echo -e "${RED}错误: 未找到适合写入测速的安全挂载点。${NC}"
        echo -e "${YELLOW}已自动排除引导分区（如 /boot/efi），并要求挂载点可写且剩余空间 >= 200MB。${NC}"
        echo -e "可见挂载点参考:"
        lsblk -n -o MOUNTPOINT "$SELECTED_DISK" "$SELECTED_DISK"* 2>/dev/null | awk 'NF {print "  "$1}'
        return
    fi
    
    local test_file="$mount_point/.speed_test_tmp_$$"
    SPEED_TEST_FILE="$test_file"
    trap cleanup_speed_test_file INT TERM EXIT
    echo -e "  测试路径: ${CYAN}$test_file${NC}"
    if [ "$cache_mode" = "drop" ]; then
        echo -e "  缓存策略: ${YELLOW}清缓存${NC}"
    else
        echo -e "  缓存策略: ${GREEN}不清缓存${NC}"
    fi
    echo -e "------------------------------------------"
    
    # 按策略处理缓存
    apply_cache_policy "$cache_mode"
    
    # 尝试使用 fio 测试（如果存在）以获取更精确的数据，回退到 dd
    if command -v fio &> /dev/null; then
        echo -n "  写入速度(fio): "
        local fio_write=$(fio --name=write_test --filename="$test_file" --size=100M --rw=write --bs=1M --direct=1 --numjobs=1 --ioengine=libaio --iodepth=1 2>&1 | grep -o 'BW=[0-9.]*[A-Za-z]B/s' | grep -o '[0-9.]*[A-Za-z]B/s')
        echo -e "${GREEN}${fio_write:-测试失败}${NC}"
        
        apply_cache_policy "$cache_mode"
        
        echo -n "  读取速度(fio): "
        local fio_read=$(fio --name=read_test --filename="$test_file" --size=100M --rw=read --bs=1M --direct=1 --numjobs=1 --ioengine=libaio --iodepth=1 2>&1 | grep -o 'BW=[0-9.]*[A-Za-z]B/s' | grep -o '[0-9.]*[A-Za-z]B/s')
        echo -e "${GREEN}${fio_read:-测试失败}${NC}"
        
        cleanup_speed_test_file
        clear_speed_test_cleanup
        echo -e "------------------------------------------"
        echo -e "${GREEN}完成！${NC}"
        return
    fi

    # 写入测试 (不使用 oflag=direct 以提高兼容性)
    echo -n "  写入速度: "
    local write_result=$(dd if=/dev/zero of="$test_file" bs=1M count=100 conv=fsync 2>&1)
    local write_speed=$(echo "$write_result" | grep -oE '[0-9.]+ [MG]B/s' | tail -1)
    if [ -n "$write_speed" ]; then
        echo -e "${GREEN}$write_speed${NC}"
    else
        # 尝试手动计算速度
        local write_time=$(echo "$write_result" | grep -oE '[0-9.]+ s,' | head -1 | tr -d ' s,')
        if [ -n "$write_time" ] && [ "$write_time" != "0" ]; then
            local calc_speed=$(echo "scale=2; 100 / $write_time" | bc 2>/dev/null)
            echo -e "${GREEN}${calc_speed:-未知} MB/s${NC}"
        else
            echo -e "${RED}测试失败${NC}"
        fi
    fi
    
    # 按策略处理缓存后进行读取测试
    apply_cache_policy "$cache_mode"
    
    # 读取测试
    echo -n "  读取速度: "
    if [ -f "$test_file" ]; then
        local read_result=$(dd if="$test_file" of=/dev/null bs=1M 2>&1)
        local read_speed=$(echo "$read_result" | grep -oE '[0-9.]+ [MG]B/s' | tail -1)
        if [ -n "$read_speed" ]; then
            echo -e "${GREEN}$read_speed${NC}"
        else
            local read_time=$(echo "$read_result" | grep -oE '[0-9.]+ s,' | head -1 | tr -d ' s,')
            if [ -n "$read_time" ] && [ "$read_time" != "0" ]; then
                local calc_speed=$(echo "scale=2; 100 / $read_time" | bc 2>/dev/null)
                echo -e "${GREEN}${calc_speed:-未知} MB/s${NC}"
            else
                echo -e "${RED}测试失败${NC}"
            fi
        fi
    else
        echo -e "${RED}测试文件不存在${NC}"
    fi
    
    # 清理测试文件
    cleanup_speed_test_file
    clear_speed_test_cleanup
    echo -e "------------------------------------------"
    echo -e "${GREEN}测试完成！${NC}"
}

# ----------------- 主程序入口 -----------------
check_basic_cmds
check_dependency_status

while true; do
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}磁盘管理专家${NC} (当前: ${YELLOW}${SELECTED_DISK:-未选择}${NC})"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BLUE}1.${NC} 选择磁盘 ${GREEN}[低风险: 仅枚举设备]${NC}"
    echo -e "  ${BLUE}2.${NC} 查看寿命与健康度 ${GREEN}[低风险: 只读查询]${NC}"
    echo -e "  ${BLUE}3.${NC} 读写性能测试 ${YELLOW}[中风险: 写入临时文件, 默认不清缓存, RAID可选只读]${NC}"
    
    echo -e "  ${BLUE}4.${NC} ${RED}依赖管理(安装/卸载 smartmontools) [高风险: 系统配置变更]${NC}"
    
    echo -e "  ${RED}q.${NC} 退出脚本"
    echo -e "  ${CYAN}风险说明: 低=只读查询 | 中=有写入与缓存影响 | 高=系统级改动${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "请输入选项: " opt
    
    case $opt in
        1) 
            list_selectable_disks
            [ "${#DISK_CANDIDATES[@]}" -eq 0 ] && continue
            read -p "选择编号: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DISK_CANDIDATES[@]}" ]; then
                SELECTED_DISK="/dev/${DISK_CANDIDATES[$((choice - 1))]}"
                selected_model=$(lsblk -d -n -o MODEL "$SELECTED_DISK" 2>/dev/null | xargs)
                if is_raid_model "$selected_model"; then
                    show_raid_notice "$SELECTED_DISK" "${selected_model:-未知}"
                fi
            else
                echo -e "${RED}无效编号${NC}"
            fi
            ;;
        2) check_health ;;
        3) test_speed ;;
        4) dependency_menu ;;
        q|Q) exit 0 ;;
        *) echo "无效输入" ;;
    esac
done
