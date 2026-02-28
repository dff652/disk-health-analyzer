# NVMe 温度数据异常排查与交叉验证记录

## 1. 背景现象

在同一台服务器上，脚本输出了以下温度信息：

- `/dev/nvme1n1`：`综合温度 47.9C`、`NAND温度 69.8C (Sensor 1)`、`主控温度 54.9C (Sensor 2)`
- `/dev/nvme0n1`：`综合温度 41.9C`（未显示 Sensor 1/2）

用户质疑 `nvme1n1` 的 `NAND 69.8C` 是否真实。

## 2. 交叉验证实验设计

目标：确认 69.8C 的真实来源设备，并判断脚本是否存在温度串盘问题。

采用三路独立数据源做交叉验证：

1. `smartctl`（设备级 SMART）
2. `nvme-cli smart-log`（NVMe 原生命令）
3. `sysfs hwmon`（内核硬件监控节点）

判定标准：

- 同一设备的 `smartctl Temperature`、`nvme smart-log temperature`、`hwmon Composite` 应基本一致（允许小幅波动）。
- 如果 `Sensor 1/2` 仅出现在某设备的 SMART 中，则该温度只归属于该设备。

## 3. 实验命令

```bash
sudo smartctl -a /dev/nvme1n1 | egrep -i "Temperature:|Temperature Sensor [0-9]|Critical Warning|Warning Comp|Critical Comp"
sudo nvme smart-log /dev/nvme1n1

for h in /sys/class/hwmon/hwmon*; do
  dev=$(readlink -f "$h/device" 2>/dev/null)
  if echo "$dev" | grep -q "/nvme/nvme1"; then
    echo "=== $h ($dev) ==="
    for l in "$h"/temp*_label; do [ -f "$l" ] && echo "$(basename "$l"): $(cat "$l")"; done
    for t in "$h"/temp*_input; do [ -f "$t" ] && echo "$(basename "$t"): $(awk "BEGIN{printf \"%.1f\", $(cat "$t")/1000}")C"; done
  fi
done

sudo smartctl -a /dev/nvme0n1 | egrep -i "Temperature:|Temperature Sensor [0-9]|Warning Comp|Critical Comp"
```

## 4. 关键实验结果

### 4.1 /dev/nvme1n1

- `smartctl`：`Temperature: 43 Celsius`
- `nvme smart-log`：`temperature: 43 C`
- `hwmon`：仅有 `Composite`，约 `42.9C`

结论：`nvme1n1` 温度正常，且未证明存在 `Sensor 1=69.8C`。

### 4.2 /dev/nvme0n1

- `smartctl` 显示：
  - `Temperature: 48 Celsius`
  - `Temperature Sensor 1: 70 Celsius`
  - `Temperature Sensor 2: 55 Celsius`
  - `Critical Comp. Temp. Threshold: 75 Celsius`

结论：`69.8C~70C` 来源于 `nvme0n1` 的 `Sensor 1`，不是 `nvme1n1`。

## 5. 根因分析

原脚本在 NVMe 温度解析中使用 `sensors` 输出，并在精确匹配失败后按 `nvme` 序号做回退切片，存在跨设备误匹配风险，导致把其他盘的 `Sensor 1/2` 显示到当前盘。

## 6. 修复措施

已修复为：

1. 优先读取当前设备专属路径：`/sys/class/nvme/<nvmeX>/device/hwmon/...`
2. `hwmon` 不完整时仅回退到当前设备 `smartctl` 的 `Temperature Sensor 1/2`
3. 移除基于 `sensors` 的顺序切片回退逻辑，避免串盘

## 7. 最终结论

1. `69.8C` 不是 `nvme1n1` 的温度，也不是阈值。
2. `69.8C~70C` 是 `nvme0n1` 的 `Temperature Sensor 1` 数据。
3. `nvme1n1` 的可信温度约为 `43C`（三路一致）。
4. 现已通过代码修复消除跨盘温度误报问题。

