#!/bin/bash

# 前端部署脚本
# 功能:
# 1. 监控指定文件变更
# 2. 防止并发执行
# 3. 备份后再执行构建

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 默认配置
PROJECT_DIR=""              # 项目目录
BUILD_COMMAND="npm run build"  # 构建命令
WATCH_FILE=""               # 监控文件
BACKUP_DIR=""              # 备份目录
LOCK_FILE=""               # 锁文件
MAX_BACKUPS=5              # 最大备份数量

# 解析命令行参数
VERBOSE=false
SHOW_HELP=false
while getopts "hvt:c:w:b:l:n:" opt; do
  case $opt in
    h)
      SHOW_HELP=true
      ;;
    v)
      VERBOSE=true
      ;;
    t)
      PROJECT_DIR="$OPTARG"
      ;;
    c)
      BUILD_COMMAND="$OPTARG"
      ;;
    w)
      WATCH_FILE="$OPTARG"
      ;;
    b)
      BACKUP_DIR="$OPTARG"
      ;;
    l)
      LOCK_FILE="$OPTARG"
      ;;
    n)
      MAX_BACKUPS="$OPTARG"
      ;;
    \?)
      echo "无效选项: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

# 显示帮助信息
if [ "$SHOW_HELP" = true ]; then
    echo "===================================================="
    echo "前端部署脚本"
    echo "===================================================="
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h                  显示此帮助信息"
    echo "  -v                  详细模式，显示更多信息"
    echo "  -t <project_dir>    项目目录 (必须)"
    echo "  -c <build_command>  构建命令 (默认: npm run build)"
    echo "  -w <watch_file>     监控文件 (必须)"
    echo "  -b <backup_dir>     备份目录 (默认: <project_dir>/backups)"
    echo "  -l <lock_file>      锁文件 (默认: <project_dir>/deploy.lock)"
    echo "  -n <max_backups>    最大备份数量 (默认: 5)"
    echo ""
    echo "示例:"
    echo "  $0 -t /path/to/project -w package.json"
    echo "  $0 -t /path/to/project -w src/config.js -c \"npm run build:h5\""
    exit 0
fi

# 验证必要参数
if [ -z "$PROJECT_DIR" ]; then
    echo -e "${RED}❌ 错误: 项目目录 (-t) 不能为空${NC}" >&2
    exit 1
fi

if [ -z "$WATCH_FILE" ]; then
    echo -e "${RED}❌ 错误: 监控文件 (-w) 不能为空${NC}" >&2
    exit 1
fi

# 设置默认值
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_DIR/backups}"
LOCK_FILE="${LOCK_FILE:-$PROJECT_DIR/deploy.lock}"

# 验证项目目录
if [ ! -d "$PROJECT_DIR" ]; then
    echo -e "${RED}❌ 错误: 项目目录不存在: $PROJECT_DIR${NC}" >&2
    exit 1
fi

# 验证监控文件
if [ ! -f "$PROJECT_DIR/$WATCH_FILE" ]; then
    echo -e "${RED}❌ 错误: 监控文件不存在: $PROJECT_DIR/$WATCH_FILE${NC}" >&2
    exit 1
fi

# 确保备份目录存在
mkdir -p "$BACKUP_DIR"

# 日志函数
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

verbose_log() {
    if [ "$VERBOSE" = true ]; then
        log "$1"
    fi
}

# 检查锁文件
check_lock() {
    if [ -f "$LOCK_FILE" ]; then
        LOCK_PID=$(cat "$LOCK_FILE")
        if ps -p "$LOCK_PID" > /dev/null 2>&1; then
            log "${YELLOW}⚠️  检测到部署进程已在运行中 (PID: $LOCK_PID)${NC}"
            return 1
        else
            # 清理无效的锁文件
            rm -f "$LOCK_FILE"
        fi
    fi
    return 0
}

# 创建锁文件
create_lock() {
    echo $$ > "$LOCK_FILE"
}

# 清理锁文件
remove_lock() {
    rm -f "$LOCK_FILE"
}

# 获取文件哈希值
get_file_hash() {
    local file="$1"
    if [ -f "$file" ]; then
        md5sum "$file" | cut -d' ' -f1
    else
        echo ""
    fi
}

# 创建备份
create_backup() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="backup_$timestamp"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    log "${BLUE}📋 创建备份: $backup_name${NC}"
    
    # 创建备份目录
    mkdir -p "$backup_path"
    
    # 复制项目文件
    if ! cp -r "$PROJECT_DIR"/* "$backup_path"/ 2>/dev/null; then
        log "${RED}❌ 备份创建失败${NC}"
        return 1
    fi
    
    # 记录备份信息
    echo "$timestamp" > "$backup_path/.backup_time"
    echo "$BUILD_COMMAND" > "$backup_path/.build_command"
    
    # 清理旧备份
    local backup_count=$(ls -dt "$BACKUP_DIR"/backup_* 2>/dev/null | wc -l)
    if [ "$backup_count" -gt "$MAX_BACKUPS" ]; then
        ls -dt "$BACKUP_DIR"/backup_* | tail -n +$((MAX_BACKUPS+1)) | xargs rm -rf 2>/dev/null || true
    fi
    
    log "${GREEN}✅ 备份完成${NC}"
    return 0
}

# 检查文件变更
check_file_change() {
    local watch_file_path="$PROJECT_DIR/$WATCH_FILE"
    local hash_file="$BACKUP_DIR/.last_hash"
    local current_hash=$(get_file_hash "$watch_file_path")
    
    if [ ! -f "$hash_file" ]; then
        # 第一次运行，记录哈希值
        echo "$current_hash" > "$hash_file"
        return 0
    fi
    
    local last_hash=$(cat "$hash_file")
    
    if [ "$current_hash" != "$last_hash" ]; then
        # 文件已变更
        echo "$current_hash" > "$hash_file"
        return 0
    fi
    
    # 文件未变更
    return 1
}

# 执行构建
run_build() {
    log "${BLUE}🔨 执行构建命令: $BUILD_COMMAND${NC}"
    
    # 切换到项目目录
    cd "$PROJECT_DIR"
    
    # 执行构建命令
    if eval "$BUILD_COMMAND"; then
        log "${GREEN}✅ 构建成功${NC}"
        return 0
    else
        log "${RED}❌ 构建失败${NC}"
        return 1
    fi
}

# 主函数
main() {
    log "${GREEN}🚀 开始前端部署流程${NC}"
    verbose_log "项目目录: $PROJECT_DIR"
    verbose_log "构建命令: $BUILD_COMMAND"
    verbose_log "监控文件: $WATCH_FILE"
    verbose_log "备份目录: $BACKUP_DIR"
    verbose_log "锁文件: $LOCK_FILE"
    
    # 检查锁文件
    if ! check_lock; then
        exit 1
    fi
    
    # 检查文件变更
    if ! check_file_change; then
        log "${GREEN}✅ 监控文件无变更，跳过构建${NC}"
        exit 0
    fi
    
    log "${YELLOW}🔄 检测到监控文件变更${NC}"
    
    # 创建锁文件
    create_lock
    
    # 确保在退出时清理锁文件
    trap remove_lock EXIT
    
    # 创建备份
    if ! create_backup; then
        log "${RED}❌ 备份失败，终止部署${NC}"
        exit 1
    fi
    
    # 执行构建
    if ! run_build; then
        log "${RED}❌ 构建失败，部署终止${NC}"
        exit 1
    fi
    
    log "${GREEN}🎉 前端部署完成${NC}"
}

# 执行主函数
main