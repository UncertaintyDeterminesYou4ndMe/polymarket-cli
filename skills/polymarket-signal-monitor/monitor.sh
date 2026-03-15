#!/bin/bash
# Polymarket Signal Monitor
# 定时监控预测市场信号

set -e

# 配置
CONFIG_DIR="${HOME}/.config/polymarket-signal-monitor"
DATA_DIR="${CONFIG_DIR}/data"
LOG_FILE="${CONFIG_DIR}/monitor.log"
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"  # 设置你的通知 webhook

# 默认参数
DEFAULT_TAGS="politics,economics,crypto"
DEFAULT_MIN_VOLUME="100000"
DEFAULT_LIMIT="10"

# 创建目录
mkdir -p "$DATA_DIR"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 发送通知
notify() {
    local message="$1"
    log "NOTIFY: $message"
    
    if [ -n "$ALERT_WEBHOOK" ]; then
        curl -s -X POST -H "Content-Type: application/json" \
            -d "{\"text\": \"$message\"}" \
            "$ALERT_WEBHOOK" || true
    fi
}

# 检查依赖
check_deps() {
    if ! command -v polymarket &> /dev/null; then
        log "ERROR: polymarket CLI not found. Please install first."
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log "ERROR: jq not found. Please install jq."
        exit 1
    fi
}

# 监控趋势市场
monitor_trending() {
    local tag="$1"
    local output_file="${DATA_DIR}/trending_${tag}.json"
    local prev_file="${DATA_DIR}/trending_${tag}_prev.json"
    
    log "Monitoring trending markets for tag: $tag"
    
    # 保存上一轮数据
    [ -f "$output_file" ] && cp "$output_file" "$prev_file"
    
    # 获取新数据
    polymarket -o json markets trending --tag "$tag" --limit "$DEFAULT_LIMIT" > "$output_file"
    
    # 分析变化
    if [ -f "$prev_file" ]; then
        local new_markets
        new_markets=$(jq -r '.[].slug' "$output_file" | sort)
        local old_markets
        old_markets=$(jq -r '.[].slug' "$prev_file" | sort)
        
        local entering
        entering=$(comm -23 <(echo "$new_markets") <(echo "$old_markets"))
        
        if [ -n "$entering" ]; then
            notify "🆕 New trending markets in $tag: $entering"
        fi
    fi
    
    # 检查高交易量市场
    local high_vol_markets
    high_vol_markets=$(jq -r --arg min_vol "$DEFAULT_MIN_VOLUME" \
        '.[] | select((.volume24hr // 0) | tonumber > ($min_vol | tonumber)) | 
        "📊 \(.question): Yes=\(.outcomePrices[0] // "N/A") Vol24h=\(.volume24hr // 0)"' \
        "$output_file")
    
    if [ -n "$high_vol_markets" ]; then
        notify "🔥 High volume markets in $tag:\n$high_vol_markets"
    fi
}

# 监控 Tag 统计
monitor_tags() {
    local output_file="${DATA_DIR}/popular_tags.json"
    
    log "Monitoring popular tags"
    
    polymarket -o json tags popular --limit 10 > "$output_file"
    
    # 显示前5个热门tag
    local top_tags
    top_tags=$(jq -r '.[:5] | .[] | "\(.label): \(.market_count) markets, $\(.total_volume | floor) volume"' "$output_file")
    
    log "Top tags:\n$top_tags"
}

# 监控特定高价值市场
monitor_high_value() {
    local output_file="${DATA_DIR}/high_value.json"
    
    log "Monitoring high value markets"
    
    polymarket -o json markets list \
        --tag politics \
        --min-volume 500000 \
        --active true \
        --order volume_num \
        --limit 5 > "$output_file"
    
    local markets
    markets=$(jq -r '.[] | "\(.question): Yes=\(.outcomePrices[0] // "N/A") Vol=\(.volumeNum // 0)"' "$output_file")
    
    log "High value markets:\n$markets"
}

# 主函数
main() {
    log "Starting Polymarket Signal Monitor"
    
    check_deps
    
    # 获取环境变量或使用默认值
    local tags="${POLYMARKET_TAGS:-$DEFAULT_TAGS}"
    
    # 监控 Tags
    monitor_tags
    
    # 监控每个 tag 的趋势市场
    IFS=',' read -ra TAG_ARRAY <<< "$tags"
    for tag in "${TAG_ARRAY[@]}"; do
        monitor_trending "$tag"
    done
    
    # 监控高价值市场
    monitor_high_value
    
    log "Monitor cycle completed"
}

# 运行
main "$@"
