# 磁盘清理记录 — 2026-04-19

## 背景

根分区 `/dev/nvme1n1p2` 告警：容量 916G，已用 844G（**98%**），仅剩 25G 可用。

```
文件系统        大小  已用  可用 已用% 挂载点
/dev/nvme1n1p2  916G  844G   25G   98% /
/dev/nvme0n1    1.8T  1.1T  588G   65% /home/data1
/dev/sda        938G   86G  805G   10% /mnt/data1
```

## 占用分析

`/home/dff652/` 占据根分区 **681G**，主要分布：

| 目录 | 大小 | 类型 |
|---|---|---|
| `hfd/` | 197G | 业务数据 |
| `miniconda3/` | 123G | Conda 环境 |
| `_old_conda_backup/` | 91G | **旧备份（可删）** |
| `dff_project/` | 65G | 项目 |
| `tzzy_project/` | 62G | 项目 |
| `.cache/` | 56G | 缓存 |
| `TS-anomaly-detection/` | 34G | 项目 |
| `benchmarks/` | 21G | 数据 |

Conda 环境细分（18 个环境，共 120G），发现异常：
- `miniconda3/envs/envs/` — 嵌套目录，内含 15 个空壳子目录（chat/dspy/glm/metagpt/xiaomi/yi-play 等），`bin/` 为空，是历史误操作残留。

## 清理操作

### Step 1 — 删除旧 Conda 备份

```bash
rm -rf /home/dff652/_old_conda_backup
```

2024 年 2 月的 miniconda 备份，已被当前 `miniconda3/` 完全替代。**释放 91G**。

### Step 2 — 删除异常嵌套环境目录

```bash
rm -rf /home/dff652/miniconda3/envs/envs
```

非正常 conda env 结构（嵌套目录 + 空 bin/），历史误操作残留。**释放 8G**。

## 清理结果

| 指标 | 清理前 | 清理后 | 变化 |
|---|---|---|---|
| 已用 | 844G | 746G | **−98G** |
| 可用 | 25G | 124G | **+99G** |
| 使用率 | 98% | 86% | −12pp |

```
/dev/nvme1n1p2  916G  746G  124G   86% /
```

## 保留未清理项（已评估，暂不处理）

### 低版本 Python 环境（按用户意愿保留）

| 环境 | 大小 | Python | 最后修改 |
|---|---|---|---|
| `torch` | 7.4G | 3.8 | 2024-10-17 |
| `ts` | 5.9G | 3.8 | 2024-10-16 |
| `d2l` | 2.2G | 3.9 | 2024-09-09 |
| `dbgpt` | 7.9G | 3.10 | 2024-09-10 |

### 可选后续清理项（未执行）

| 项 | 大小 | 命令 |
|---|---|---|
| pip 下载缓存 | 44G | `pip cache purge` |
| uv 缓存 | 9.5G | `uv cache clean` |
| conda pkgs 缓存 | 3.6G | `conda clean -a -y` |
| systemd journal | 2.4G | `sudo journalctl --vacuum-size=200M` |

### 长期建议

大型项目/数据目录（`hfd/` 197G、`dff_project/` 65G、`tzzy_project/` 62G、`TS-anomaly-detection/` 34G）建议迁移至 `/home/data1`（可用 588G）或 `/mnt/data1`（可用 805G），以避免根分区再次告警。

## 活跃 Conda 环境清单（保留）

| 环境 | 大小 | Python | 最后修改 |
|---|---|---|---|
| chatts-vllm011 | 12G | 3.12 | 2026-03-16 |
| qwen-vllm011-clean | 9.8G | 3.12 | 2026-03-16 |
| inference-platform | 839M | 3.11 | 2026-03-15 |
| chatts_8b_train_env | 6.7G | 3.12 | 2025-12-26 |
| chatts_train_env | 6.7G | 3.12 | 2025-12-25 |
| deepanalyze | 11G | 3.12 | 2025-11-26 |
| uni2ts | 6.1G | 3.10 | 2025-11-20 |
| ltm | 6.4G | 3.10 | 2025-11-12 |
| chatts | 12G | 3.12 | 2025-11-03 |
| test | 7.8G | 3.10 | 2025-10-30 |
| orion | 8.4G | 3.10 | 2025-10-16 |
| orion-tf | 5.2G | 3.10 | 2025-10-16 |
| rs | 703M | 3.10 | 2025-08-21 |
