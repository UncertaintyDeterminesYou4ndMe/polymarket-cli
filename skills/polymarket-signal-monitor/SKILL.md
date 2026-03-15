# Polymarket Signal Monitor Skill

通过 Polymarket CLI 定时监控预测市场信号，发现高价值交易机会和市场情绪变化。

## 功能

- 监控高交易量市场的概率变化
- 发现热门 Tag 下的新机会
- 识别异常交易活动（内部人士信号）
- 定时推送通知

## 安装

1. 确保已安装 Polymarket CLI:
```bash
cd /path/to/polymarket-cli
cargo install --path .
```

2. 配置环境变量（可选）:
```bash
export POLYMARKET_MIN_VOLUME=100000  # 最小交易量阈值
export POLYMARKET_TAGS="politics,economics,crypto"  # 关注的标签
```

## 使用方法

### 1. 发现高价值 Tags

```bash
# 查看热门 Tags（按总交易量排序）
polymarket tags popular --limit 10

# 查看 Tags 统计详情
polymarket tags list --with-stats --limit 20
```

### 2. 监控热门市场

```bash
# 查看全站趋势市场（按24h交易量）
polymarket markets trending --limit 10

# 只看政治类趋势市场
polymarket markets trending --tag politics --limit 10

# 只看高交易量趋势市场
polymarket markets trending --min-volume-24h 50000 --limit 5
```

### 3. 筛选特定领域市场

```bash
# 政治 + 高交易量
polymarket markets list --tag politics --min-volume 100000 --active true --limit 10

# 经济 + 按交易量排序
polymarket markets list --tag economics --order volume_num --active true --limit 10

# 加密货币 + 活跃市场
polymarket markets list --tag crypto --active true --limit 10
```

### 4. 定时监控脚本

```bash
#!/bin/bash
# signal-monitor.sh - 每小时检查一次信号

OUTPUT_FILE="/tmp/polymarket_signals.json"
ALERT_THRESHOLD=0.1  # 价格变化超过10%时告警

# 获取趋势市场
polymarket -o json markets trending --tag politics --limit 5 > "$OUTPUT_FILE"

# 分析并推送通知（这里可以接入你的通知系统）
# 示例: 检查是否有市场24h交易量超过阈值
jq -r '.[] | select(.volume24hr | tonumber > 100000) | "\(.question): \(.outcomePrices[0])"' "$OUTPUT_FILE"
```

## Agent 集成示例

在你的 agent 配置中添加:

```yaml
# .agents/skills/polymarket-monitor/config.yaml
skills:
  polymarket-monitor:
    enabled: true
    schedule: "0 * * * *"  # 每小时执行
    commands:
      - name: "trending-politics"
        cmd: "polymarket markets trending --tag politics --limit 5 -o json"
        alert_condition: "volume_24hr > 50000"
      
      - name: "high-volume-markets"
        cmd: "polymarket markets list --tag politics --min-volume 100000 --active true -o json"
        alert_condition: "price_change_24h > 0.05"
      
      - name: "popular-tags"
        cmd: "polymarket tags popular --limit 5 -o json"
        notify: true
```

## 信号解读指南

### 高24h交易量 + 价格稳定
- 可能表示：市场已形成共识，多空双方都在积极参与
- 信号强度: ⭐⭐⭐

### 高24h交易量 + 价格剧烈波动
- 可能表示：新信息进入市场，内部人士可能提前获知消息
- 信号强度: ⭐⭐⭐⭐⭐

### 低交易量 + 价格异常
- 可能表示：流动性不足，价格可能不准确
- 信号强度: ⭐

### 新市场快速积累交易量
- 可能表示：高关注度事件即将发生
- 信号强度: ⭐⭐⭐⭐

## 推荐监控组合

| 用例 | 命令 |
|------|------|
| 宏观政治风险 | `markets trending --tag politics --limit 5` |
| 加密市场情绪 | `markets trending --tag crypto --limit 5` |
| 经济衰退指标 | `markets list --tag economics --min-volume 50000` |
| 发现新机会 | `tags popular --limit 5` |
| 内部人士活动 | `markets trending --min-volume-24h 100000` |

## 注意事项

1. **API 限制**: Polymarket API 可能有频率限制，建议合理设置监控间隔
2. **数据延迟**: 市场数据可能有分钟级延迟，不适用于高频交易
3. **概率≠事实**: 预测市场反映的是群体信念，不是确定性结果
4. **风险管理**: 任何信号都只是参考，不构成投资建议
