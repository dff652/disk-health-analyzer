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

# 检查权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}${BOLD}错误:${NC} 请使用 sudo 运行此脚本。"
  exit 1
fi

# ----------------- 基础命令检查 -----------------
check_basic_cmds() {
    local cmds=("lsblk" "df" "awk" "grep" "bc" "dd")
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}${BOLD}致命错误:${NC} 系统缺少基础命令: ${YELLOW}$cmd${NC}"
            echo -e "请确保系统已安装包含该命令的基础工具包 (如 coreutils, bc 等)。"
            exit 1
        fi
    done
}

# ----------------- 依赖管理 (带保护逻辑) -----------------
check_and_install_deps() {
    if ! command -v smartctl &> /dev/null; then
        echo -e "${YELLOW}------------------------------------------${NC}"
        echo -e "${BOLD}检测到缺少关键依赖: ${CYAN}smartmontools${NC}"
        read -p "是否由本脚本代为安装? (y/n): " confirm
        if [[ "$confirm" == [yY] ]]; then
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
            fi
            [ -f "$INSTALL_FLAG" ] && echo -e "${GREEN}安装成功并已记录标记。${NC}"
        fi
    else
        # 如果系统自带，确保没有标记文件，防止误删
        [ -f "$INSTALL_FLAG" ] && rm -f "$INSTALL_FLAG"
    fi
}

uninstall_deps() {
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

# ----------------- 健康度解析 -----------------
check_health() {
    [ -z "$SELECTED_DISK" ] && { echo -e "${RED}请先选择磁盘！${NC}"; return; }
    
    # 获取容量信息
    local total_size=$(lsblk -d -n -o SIZE "$SELECTED_DISK")
    # 获取挂载点的使用情况 (如果是多分区，取根目录或主要分区)
    local usage_info=$(df -h | grep "$SELECTED_DISK" | head -n 1)
    local used_size=$(echo $usage_info | awk '{print $3}')
    local free_size=$(echo $usage_info | awk '{print $4}')
    [ -z "$used_size" ] && used_size="未知"
    [ -z "$free_size" ] && free_size="未知"

    echo -e "\n${BLUE}${BOLD}┏━━━━ 磁盘详细健康档案 ━━━━┓${NC}"
    echo -e "  设备路径: ${YELLOW}$SELECTED_DISK${NC}"
    echo -e "  总 容 量: ${CYAN}$total_size${NC}"
    echo -e "------------------------------------------"

    if [[ "$SELECTED_DISK" == *"/mmcblk"* ]]; then
        # ===================== eMMC 逻辑 =====================
        local sys_path lifetime val_a val_b max_val
        echo -e "  磁盘类型: ${CYAN}eMMC 存储${NC}"
        sys_path=$(find /sys/bus/mmc/devices/ -name "*:*" 2>/dev/null | head -n 1)
        if [ -n "$sys_path" ] && [ -f "$sys_path/life_time" ]; then
            lifetime=$(cat "$sys_path/life_time")
            val_a=$(( $(echo $lifetime | awk '{print $1}') ))
            val_b=$(( $(echo $lifetime | awk '{print $2}') ))
            draw_progress "$((val_a * 10))" "SLC 区域消耗"
            draw_progress "$((val_b * 10))" "MLC 区域消耗"
            max_val=$((val_b > val_a ? val_b : val_a))
            echo -e "  ${BOLD}估算剩余寿命: ${GREEN}$((100 - max_val * 10))%${NC}"
        else
            echo -e "  ${RED}错误: 无法读取 eMMC 寿命节点${NC}"
        fi
        
    elif [[ "$SELECTED_DISK" == *"nvme"* ]]; then
        # ===================== NVMe 逻辑 =====================
        echo -e "  磁盘类型: ${CYAN}NVMe SSD${NC}"
        
        if ! command -v smartctl &> /dev/null; then
            echo -e "  ${RED}错误: 未安装 smartmontools${NC}"
            echo -e "  ${YELLOW}请运行自动安装或通过包管理器安装${NC}"
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
        
        # 显示温度 (使用 sensors 获取完整温度信息)
        # 先获取 NVMe 的 PCI 地址，用于匹配 sensors 输出
        local nvme_name=$(basename "$SELECTED_DISK" | sed 's/n1$//')  # nvme0 或 nvme1
        local pci_slot=$(readlink -f /sys/class/nvme/$nvme_name 2>/dev/null | grep -oE 'pci[0-9]+:[0-9]+' | tail -1 | sed 's/pci//')
        
        # 尝试从 sensors 获取详细温度
        local sensors_output=""
        if command -v sensors &> /dev/null; then
            # 查找对应的 hwmon 设备
            sensors_output=$(sensors 2>/dev/null | grep -A10 "nvme-pci-0${pci_slot}00\|nvme-pci-${pci_slot}")
            if [ -z "$sensors_output" ]; then
                # 备用方案：按顺序匹配
                local nvme_idx=$(echo "$nvme_name" | grep -oE '[0-9]+')
                sensors_output=$(sensors 2>/dev/null | grep -A10 "nvme-pci" | head -$((11 * (nvme_idx + 1))) | tail -11)
            fi
        fi
        
        if [ -n "$sensors_output" ]; then
            # 从 sensors 输出解析温度
            local composite=$(echo "$sensors_output" | grep -i "Composite" | awk '{print $2}' | tr -cd '0-9.')
            local sensor1=$(echo "$sensors_output" | grep -i "Sensor 1" | awk '{print $3}' | tr -cd '0-9.')
            local sensor2=$(echo "$sensors_output" | grep -i "Sensor 2" | awk '{print $3}' | tr -cd '0-9.')
            
            # 显示综合温度
            if [ -n "$composite" ]; then
                local comp_int=${composite%.*}
                local comp_color=$GREEN
                [ "$comp_int" -ge 50 ] && comp_color=$YELLOW
                [ "$comp_int" -ge 70 ] && comp_color=$RED
                echo -e "  综合温度: ${comp_color}${composite}°C${NC}"
            fi
            
            # 显示 Sensor 1 (通常是 NAND 闪存温度)
            if [ -n "$sensor1" ]; then
                local s1_int=${sensor1%.*}
                local s1_color=$GREEN
                [ "$s1_int" -ge 60 ] && s1_color=$YELLOW
                [ "$s1_int" -ge 70 ] && s1_color=$RED
                echo -e "  NAND温度: ${s1_color}${sensor1}°C${NC} (Sensor 1)"
            fi
            
            # 显示 Sensor 2 (通常是主控温度)
            if [ -n "$sensor2" ]; then
                local s2_int=${sensor2%.*}
                local s2_color=$GREEN
                [ "$s2_int" -ge 60 ] && s2_color=$YELLOW
                [ "$s2_int" -ge 70 ] && s2_color=$RED
                echo -e "  主控温度: ${s2_color}${sensor2}°C${NC} (Sensor 2)"
            fi
        elif [ -n "$temperature" ]; then
            # 回退到 smartctl 的单一温度
            local temp_num=$(echo "$temperature" | tr -cd '0-9')
            local temp_color=$GREEN
            [ "$temp_num" -ge 50 ] && temp_color=$YELLOW
            [ "$temp_num" -ge 70 ] && temp_color=$RED
            echo -e "  当前温度: ${temp_color}${temp_num}°C${NC}"
        fi
        
        echo -e "------------------------------------------"
        
        # 显示寿命百分比 (核心指标)
        if [ -n "$pct_used" ]; then
            local pct_num=$(echo "$pct_used" | tr -cd '0-9')
            if [ -n "$pct_num" ]; then
                draw_progress "$pct_num" "寿命已用"
                local remaining=$((100 - pct_num))
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
            echo -e "  ${YELLOW}请运行自动安装或通过包管理器安装${NC}"
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
    
    # 查找磁盘或其分区的挂载点
    local mount_point=""
    # 先检查磁盘本身是否挂载
    mount_point=$(lsblk -n -o MOUNTPOINT "$SELECTED_DISK" 2>/dev/null | grep -v "^$" | head -n 1)
    # 如果磁盘本身未挂载，检查其分区
    if [ -z "$mount_point" ]; then
        mount_point=$(lsblk -n -o MOUNTPOINT "$SELECTED_DISK"* 2>/dev/null | grep -v "^$" | grep -v "\[SWAP\]" | head -n 1)
    fi
    
    if [ -z "$mount_point" ]; then
        echo -e "${RED}错误: 磁盘 $SELECTED_DISK 及其分区均未挂载！${NC}"
        echo -e "${YELLOW}提示: 请先挂载磁盘分区，或选择一个已挂载的磁盘。${NC}"
        echo -e "可用挂载点参考:"
        df -h | grep -E "^/dev" | awk '{print "  "$1" -> "$6}'
        return
    fi
    
    local test_file="$mount_point/.speed_test_tmp_$$"
    echo -e "  测试路径: ${CYAN}$test_file${NC}"
    echo -e "------------------------------------------"
    
    # 清除缓存
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    
    # 尝试使用 fio 测试（如果存在）以获取更精确的数据，回退到 dd
    if command -v fio &> /dev/null; then
        echo -n "  写入速度(fio): "
        local fio_write=$(fio --name=write_test --filename="$test_file" --size=100M --rw=write --bs=1M --direct=1 --numjobs=1 --ioengine=libaio --iodepth=1 2>&1 | grep -o 'BW=[0-9.]*[A-Za-z]B/s' | grep -o '[0-9.]*[A-Za-z]B/s')
        echo -e "${GREEN}${fio_write:-测试失败}${NC}"
        
        sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        
        echo -n "  读取速度(fio): "
        local fio_read=$(fio --name=read_test --filename="$test_file" --size=100M --rw=read --bs=1M --direct=1 --numjobs=1 --ioengine=libaio --iodepth=1 2>&1 | grep -o 'BW=[0-9.]*[A-Za-z]B/s' | grep -o '[0-9.]*[A-Za-z]B/s')
        echo -e "${GREEN}${fio_read:-测试失败}${NC}"
        
        rm -f "$test_file" 2>/dev/null
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
    
    # 清除缓存后进行读取测试
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    
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
    rm -f "$test_file" 2>/dev/null
    echo -e "------------------------------------------"
    echo -e "${GREEN}测试完成！${NC}"
}

# ----------------- 主程序入口 -----------------
check_basic_cmds
check_and_install_deps

while true; do
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}磁盘管理专家${NC} (当前: ${YELLOW}${SELECTED_DISK:-未选择}${NC})"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BLUE}1.${NC} 选择磁盘"
    echo -e "  ${BLUE}2.${NC} 查看寿命与健康度"
    echo -e "  ${BLUE}3.${NC} 读写性能测试"
    
    # 核心逻辑：只有存在标记文件时，才显示“卸载”选项
    if [ -f "$INSTALL_FLAG" ]; then
        echo -e "  ${BLUE}4.${NC} ${RED}卸载脚本安装的依赖${NC}"
    fi
    
    echo -e "  ${RED}q.${NC} 退出脚本"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "请输入选项: " opt
    
    case $opt in
        1) 
            lsblk -d -n -o NAME,SIZE,MODEL | awk '{print NR") /dev/"$1 " ["$2"] " $3}'
            read -p "选择编号: " choice
            line=$(lsblk -d -n -o NAME | sed -n "${choice}p")
            [ ! -z "$line" ] && SELECTED_DISK="/dev/$line"
            ;;
        2) check_health ;;
        3) test_speed ;;
        4) [ -f "$INSTALL_FLAG" ] && uninstall_deps || echo "无效选项" ;;
        q|Q) exit 0 ;;
        *) echo "无效输入" ;;
    esac
done
