#!/bin/bash
set -euo pipefail  # 遇到错误立即退出

# 记录脚本开始时间
SCRIPT_START_TIME=$(date +%s)

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 解决Git中文文件名编码问题
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# 配置Git处理中文文件名
git config --global core.quotepath off

# 默认配置变量
TARGET_DIR="/www/wwwroot/project"  # 生产目录（无.git）
GIT_REPO=".git"                           # 仓库地址
GIT_BRANCH="master"                   # Git分支
DEPLOY_DIR=""                         # 部署工作目录
GIT_CACHE=""                          # Git缓存目录（基于部署工作目录）
BACKUP_DIR=""                         # 备份目录（基于部署工作目录）
MAX_BACKUPS=5                         # 保留的备份数量
STATUS_FILE=""                        # 状态标记文件（基于部署工作目录）
ERROR_DETAILS_FILE=""                 # 错误详情文件（基于部署工作目录）
IGNORE_FILE=""                        # 忽略文件路径
LOCK_FILE=""                          # 脚本锁文件路径

# 解析命令行参数
VERBOSE=false
SHOW_HELP=false
while getopts "hvt:r:w:b:d:n:s:e:c:i:l:" opt; do
  case $opt in
    h)
      SHOW_HELP=true
      ;;
    v)
      VERBOSE=true
      ;;
    t)
      TARGET_DIR="$OPTARG"
      ;;
    r)
      GIT_REPO="$OPTARG"
      ;;
    w)
      DEPLOY_DIR="$OPTARG"
      ;;
    b)
      GIT_BRANCH="$OPTARG"
      ;;
    d)
      BACKUP_DIR="$OPTARG"
      ;;
    n)
      MAX_BACKUPS="$OPTARG"
      ;;
    s)
      STATUS_FILE="$OPTARG"
      ;;
    e)
      ERROR_DETAILS_FILE="$OPTARG"
      ;;
    c)
      GIT_CACHE="$OPTARG"
      ;;
    i)
      IGNORE_FILE="$OPTARG"
      ;;
    l)
      LOCK_FILE="$OPTARG"
      ;;
    \?)
      echo "无效选项: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

# 如果没有设置部署工作目录，使用脚本所在目录下的deploy子目录作为默认值
if [ -z "$DEPLOY_DIR" ]; then
    DEPLOY_DIR="${SCRIPT_DIR}/deploy"
fi

# 基于部署工作目录和分支名创建子目录
BRANCH_DEPLOY_DIR="${DEPLOY_DIR}/${GIT_BRANCH}"
# 确保 DEPLOY_DIR 目录存在
if [ ! -d "$BRANCH_DEPLOY_DIR" ]; then
    mkdir -p "$BRANCH_DEPLOY_DIR"
fi
# 基于部署工作目录和分支名设置其他路径的默认值
GIT_CACHE="${GIT_CACHE:-${BRANCH_DEPLOY_DIR}/cache}"
BACKUP_DIR="${BACKUP_DIR:-${BRANCH_DEPLOY_DIR}/backups}"
STATUS_FILE="${STATUS_FILE:-${BRANCH_DEPLOY_DIR}/deploy_status}"
ERROR_DETAILS_FILE="${ERROR_DETAILS_FILE:-${BRANCH_DEPLOY_DIR}/error_details}"
IGNORE_FILE="${IGNORE_FILE:-${BRANCH_DEPLOY_DIR}/.deploy-ignore}"
LOCK_FILE="${LOCK_FILE:-${BRANCH_DEPLOY_DIR}/deploy.lock}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 参数验证函数
validate_params() {
    # 检查必需参数是否为空
    if [ -z "$TARGET_DIR" ]; then
        echo -e "${RED}❌ 错误: 目标目录 (-t) 不能为空${NC}" >&2
        return 1
    fi
    
    if [ -z "$GIT_REPO" ]; then
        echo -e "${RED}❌ 错误: Git仓库地址 (-r) 不能为空${NC}" >&2
        return 1
    fi
    
    if [ -z "$GIT_CACHE" ]; then
        echo -e "${RED}❌ 错误: Git缓存目录 (-c) 不能为空${NC}" >&2
        return 1
    fi
    
    if [ -z "$BACKUP_DIR" ]; then
        echo -e "${RED}❌ 错误: 备份目录 (-d) 不能为空${NC}" >&2
        return 1
    fi
    
    if [ -z "$STATUS_FILE" ]; then
        echo -e "${RED}❌ 错误: 状态文件路径 (-s) 不能为空${NC}" >&2
        return 1
    fi
    
    if [ -z "$ERROR_DETAILS_FILE" ]; then
        echo -e "${RED}❌ 错误: 错误详情文件路径 (-e) 不能为空${NC}" >&2
        return 1
    fi
    
    if [ -z "$GIT_BRANCH" ]; then
        echo -e "${RED}❌ 错误: Git分支 (-b) 不能为空${NC}" >&2
        return 1
    fi
    
    # 验证数字类型参数
    if ! [[ "$MAX_BACKUPS" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}❌ 错误: 最大备份数量 (-n) 必须是数字，当前值为 '$MAX_BACKUPS'${NC}" >&2
        return 1
    fi
    
    # 验证目录路径格式（简单验证）
    if [[ "$TARGET_DIR" != /* ]]; then
        echo -e "${RED}❌ 错误: 目标目录 (-t) 必须是绝对路径，当前值为 '$TARGET_DIR'${NC}" >&2
        return 1
    fi
    
    if [[ "$GIT_CACHE" != /* ]]; then
        echo -e "${RED}❌ 错误: Git缓存目录 (-c) 必须是绝对路径，当前值为 '$GIT_CACHE'${NC}" >&2
        return 1
    fi
    
    if [[ "$BACKUP_DIR" != /* ]]; then
        echo -e "${RED}❌ 错误: 备份目录 (-d) 必须是绝对路径，当前值为 '$BACKUP_DIR'${NC}" >&2
        return 1
    fi
    
    # 验证文件路径格式（简单验证）
    if [[ "$STATUS_FILE" != /* ]]; then
        echo -e "${RED}❌ 错误: 状态文件路径 (-s) 必须是绝对路径，当前值为 '$STATUS_FILE'${NC}" >&2
        return 1
    fi
    
    if [[ "$ERROR_DETAILS_FILE" != /* ]]; then
        echo -e "${RED}❌ 错误: 错误详情文件路径 (-e) 必须是绝对路径，当前值为 '$ERROR_DETAILS_FILE'${NC}" >&2
        return 1
    fi
    
    return 0
}

# 过滤文件函数
filter_files() {
    local file_list="$1"
    local filtered_list="/tmp/filtered_$$_$(basename "$file_list")"

    # 如果忽略文件不存在，则直接返回原文件列表
    if [ ! -f "$IGNORE_FILE" ]; then
        cp "$file_list" "$filtered_list"
        echo "$filtered_list"
        return 0
    fi

    # 预处理忽略规则：去注释、去空行、去除首尾空格、去除开头的 /
    local patterns=()
    while IFS= read -r line; do
        patterns+=("$line")
    done < <(grep -E -v '^\s*(#|$)' "$IGNORE_FILE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^\///')

    # 添加默认忽略规则：.git 目录
    patterns+=(".git")

    # 创建临时文件用于存储结果
    touch "$filtered_list"

    # 逐行读取文件列表
    while IFS= read -r file; do
        if [ -n "$file" ]; then
            # 解码可能存在的 Git 转义文件名
            local decoded_file
            decoded_file=$(decode_git_filename "$file")

            local should_ignore=false
            for pattern in "${patterns[@]}"; do
                # 精确匹配
                if [ "$decoded_file" = "$pattern" ]; then
                    should_ignore=true
                    break
                fi

                # 处理目录匹配（模式以 / 结尾）
                if [[ "$pattern" == */ ]] && [[ "$decoded_file" == "$pattern"* ]]; then
                    should_ignore=true
                    break
                fi

                # 处理 .git 目录及其子文件
                if [[ "$decoded_file" == .git/* ]]; then
                    should_ignore=true
                    break
                fi

                # 处理通配符模式（使用 bash 模式匹配）
                case "$decoded_file" in
                    $pattern)
                        should_ignore=true
                        break
                        ;;
                esac
            done

            # 如果不应该忽略该文件，则添加到过滤后的列表中
            if [ "$should_ignore" = false ]; then
                echo "$file" >> "$filtered_list"
            fi
        fi
    done < "$file_list"

    echo "$filtered_list"
}

# 进度条配置
TOTAL_STEPS=10
CURRENT_STEP=0
PROGRESS_LINE=""  # 存储当前进度条内容

# 部署统计信息
DEPLOY_STATS_ADDED=0
DEPLOY_STATS_MODIFIED=0
DEPLOY_STATS_DELETED=0
DEPLOY_START_TIME=0
DEPLOY_END_TIME=0

# 解码Git中文文件名函数
decode_git_filename() {
    local encoded_name="$1"
    # 使用printf解码八进制序列
    printf "%b" "$encoded_name" 2>/dev/null || echo "$encoded_name"
}

# 格式化秒数为可读的时间格式
format_duration() {
    local seconds=$1
    local days=$((seconds / 86400))
    local hours=$(( (seconds % 86400) / 3600 ))
    local minutes=$(( (seconds % 3600) / 60 ))
    local secs=$((seconds % 60))
    
    local result=""
    if [ $days -gt 0 ]; then
        result="${days}天 "
    fi
    if [ $hours -gt 0 ]; then
        result="${result}${hours}小时 "
    fi
    if [ $minutes -gt 0 ]; then
        result="${result}${minutes}分钟 "
    fi
    result="${result}${secs}秒"
    
    echo "$result"
}

# 显示进度条函数
show_progress() {
    local step_msg="$1"
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local progress=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    
    # 显示进度条
    local bar_size=50
    local filled_size=$((progress * bar_size / 100))
    local empty_size=$((bar_size - filled_size))
    
    local bar=""
    local i
    for ((i=0; i<filled_size; i++)); do
        bar="${bar}█"
    done
    for ((i=0; i<empty_size; i++)); do
        bar="${bar}░"
    done
    
    # 保存进度条内容
    PROGRESS_LINE="${CYAN}进度: [${bar}] ${progress}% - ${step_msg}${NC}"
    
    # 使用ANSI转义序列覆盖上一行并显示新的进度条
    echo -e "\033[1A\033[2K${PROGRESS_LINE}"
}

# 条件输出函数，仅在VERBOSE为true时输出
verbose_echo() {
    if [ "$VERBOSE" = true ]; then
        echo -e "$1"
    fi
}

# 同步缺失的文件
sync_missing_files() {
    local missing_files_count=0
    
    verbose_echo "${YELLOW}🔍 检查缺失的文件...${NC}"
    
    # 获取仓库中的所有文件列表
    if ! (cd "$GIT_CACHE" && find . -type f | sed 's|^./||') > /tmp/all_repo_files.txt 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:list_repo_files" > "$STATUS_FILE"
        echo -e "${RED}❌ 获取仓库文件列表失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi
    
    # 过滤掉忽略的文件
    FILTERED_ALL_FILES=$(filter_files "/tmp/all_repo_files.txt")
    mv "$FILTERED_ALL_FILES" /tmp/all_repo_files.txt
    
    # 检查每个文件是否在生产环境中存在
    while IFS= read -r file; do
        if [ -n "$file" ]; then
            # 如果文件在仓库中存在但在生产环境中不存在，则需要同步
            if [ ! -f "$TARGET_DIR/$file" ]; then
                verbose_echo "${GREEN}  ➕ 补充缺失文件: $file${NC}"
                
                mkdir -p "$TARGET_DIR/$(dirname "$file")" 2>/dev/null || true
                if ! cp "$GIT_CACHE/$file" "$TARGET_DIR/$file" 2>"$ERROR_DETAILS_FILE"; then
                    echo "failed:missing_file_copy" > "$STATUS_FILE"
                    echo -e "${RED}❌ 同步缺失文件失败 ($file):${NC}" >&2
                    cat "$ERROR_DETAILS_FILE" >&2
                    return 1
                fi
                
                missing_files_count=$((missing_files_count + 1))
            fi
        fi
    done < /tmp/all_repo_files.txt
    
    if [ "$missing_files_count" -gt 0 ]; then
        verbose_echo "${GREEN}✅ 同步了 $missing_files_count 个缺失的文件${NC}"
    else
        verbose_echo "${GREEN}✅ 没有发现缺失的文件${NC}"
    fi
    
    return 0
}

# 递归删除空目录
clean_empty_dirs() {
    local dir="$1"
    while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "$TARGET_DIR" ]; do
        if [ -d "$dir" ] && [ -z "$(ls -A "$dir")" ]; then
            if [ "$VERBOSE" = true ]; then
                echo -e "${YELLOW}  🗑️ 删除空目录: $dir ${NC}"
                rmdir "$dir" || break
            else
                rmdir "$dir" || break
            fi
            dir=$(dirname "$dir")
        else
            break
        fi
    done
}

# 初始化缓存仓库
init_git_cache() {
    show_progress "初始化Git缓存仓库"
    verbose_echo "${YELLOW}🔄 初始化Git缓存仓库...${NC}"
    rm -rf "$GIT_CACHE"
    if ! git clone "$GIT_REPO" "$GIT_CACHE" 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:git_init" > "$STATUS_FILE"
        echo -e "${RED}❌ Git缓存仓库初始化失败${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi
    (cd "$GIT_CACHE" && git config --local core.bare false)
    verbose_echo "${GREEN}✅ 缓存仓库初始化完成${NC}"
}

# 强制更新缓存仓库（关键修复）
update_git_cache() {
    show_progress "更新代码仓库"
    verbose_echo "${YELLOW}⬇️ 强制更新仓库代码...${NC}"
    
    # 检查远程分支是否存在
    if ! (cd "$GIT_CACHE" && git ls-remote --exit-code origin "$GIT_BRANCH" >/dev/null 2>&1); then
        echo -e "${RED}❌ 远程${GIT_BRANCH}分支不存在${NC}"
        echo "远程${GIT_BRANCH}分支不存在" > "$ERROR_DETAILS_FILE"
        echo "failed:git_update" > "$STATUS_FILE"
        echo -e "${RED}❌ 远程${GIT_BRANCH}分支不存在${NC}" >&2
        return 1
    fi
    
    # 强制重置仓库
    if ! (cd "$GIT_CACHE" && git clean -fd && git fetch origin --prune && git reset --hard "origin/$GIT_BRANCH" && git checkout -f "$GIT_BRANCH") 2>"$ERROR_DETAILS_FILE"; then
        echo -e "${RED}❌ 代码更新失败${NC}"
        echo "failed:git_update" > "$STATUS_FILE"
        echo -e "${RED}❌ 代码更新失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi
    
    verbose_echo "${GREEN}✅ 代码更新完成${NC}"
}

# 创建备份
create_backup() {
    show_progress "创建备份"
    local backup_name="backup_$(date +%Y%m%d_%H%M%S)"
    verbose_echo "${YELLOW}📦 创建备份: $backup_name${NC}"
    
    if ! mkdir -p "$BACKUP_DIR/$backup_name" 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:backup_create_dir" > "$STATUS_FILE"
        echo -e "${RED}❌ 备份目录创建失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi
    
    # 备份将被修改的文件
    while IFS= read -r file; do
        if [ -n "$file" ] && [ -f "$TARGET_DIR/$file" ]; then
            mkdir -p "$BACKUP_DIR/$backup_name/$(dirname "$file")" 2>/dev/null || true
            # 移除-v参数以避免中文文件名问题
            if ! cp "$TARGET_DIR/$file" "$BACKUP_DIR/$backup_name/$file" 2>"$ERROR_DETAILS_FILE"; then
                echo "failed:backup_copy_changed" > "$STATUS_FILE"
                echo -e "${RED}❌ 备份修改文件失败 ($file):${NC}" >&2
                cat "$ERROR_DETAILS_FILE" >&2
                return 1
            fi
        fi
    done < /tmp/changed_files.txt
    
    # 备份将被删除的文件
    while IFS= read -r file; do
        if [ -n "$file" ] && [ -f "$TARGET_DIR/$file" ]; then
            mkdir -p "$BACKUP_DIR/$backup_name/$(dirname "$file")" 2>/dev/null || true
            # 移除-v参数以避免中文文件名问题
            if ! cp "$TARGET_DIR/$file" "$BACKUP_DIR/$backup_name/$file" 2>"$ERROR_DETAILS_FILE"; then
                echo "failed:backup_copy_deleted" > "$STATUS_FILE"
                echo -e "${RED}❌ 备份删除文件失败 ($file):${NC}" >&2
                cat "$ERROR_DETAILS_FILE" >&2
                return 1
            fi
            verbose_echo "${YELLOW}  💾 备份将被删除的文件: $file ${NC}"
        fi
    done < /tmp/deleted_files.txt
    
    # 记录新增文件列表
    if ! (cd "$GIT_CACHE" && git diff --name-only --diff-filter=A "$LAST_HASH" HEAD) > "$BACKUP_DIR/$backup_name/added_files.txt" 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:backup_added_files_list" > "$STATUS_FILE"
        echo -e "${RED}❌ 记录新增文件列表失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi
    
    # 记录备份元数据
    if ! (cd "$GIT_CACHE" && git rev-parse HEAD) > "$BACKUP_DIR/$backup_name/.backup_hash" 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:backup_hash" > "$STATUS_FILE"
        echo -e "${RED}❌ 记录备份哈希失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi
    
    date > "$BACKUP_DIR/$backup_name/.backup_time"
    if ! cp /tmp/changed_files.txt /tmp/deleted_files.txt "$BACKUP_DIR/$backup_name/" 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:backup_metadata" > "$STATUS_FILE"
        echo -e "${RED}❌ 复制元数据失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi
    
    # 清理旧备份
    ls -dt "$BACKUP_DIR"/backup_* | tail -n +$((MAX_BACKUPS+1)) | xargs rm -rf 2>/dev/null || true
    verbose_echo "${GREEN}✅ 备份完成 (位置: $BACKUP_DIR/$backup_name)${NC}"
}

# 恢复备份
restore_backup() {
    local latest_backup=$(ls -dt "$BACKUP_DIR"/backup_* | head -n 1)
    if [ -n "$latest_backup" ]; then
        show_progress "恢复备份"
        verbose_echo "${YELLOW}🔄 正在从备份恢复: $(basename $latest_backup)${NC}"
        
        # 删除新增的文件
        if [ -f "$latest_backup/added_files.txt" ]; then
            verbose_echo "${YELLOW}🗑️ 清理新增文件:${NC}"
            while IFS= read -r file; do
                if [ -n "$file" ] && [ -f "$TARGET_DIR/$file" ]; then
                    verbose_echo "${RED}  ❌ 删除新增文件: $file ${NC}"
                    if ! rm -f "$TARGET_DIR/$file" 2>"$ERROR_DETAILS_FILE"; then
                        echo "failed:restore_delete_added" > "$STATUS_FILE"
                        echo -e "${RED}❌ 删除新增文件失败 ($file):${NC}" >&2
                        cat "$ERROR_DETAILS_FILE" >&2
                        return 1
                    fi
                    clean_empty_dirs "$(dirname "$TARGET_DIR/$file")"
                fi
            done < "$latest_backup/added_files.txt"
        fi
        
        # 恢复被修改的文件
        verbose_echo "${YELLOW}🔄 恢复被修改的文件...${NC}"
        find "$latest_backup" -type f | while read -r backup_file; do
            case $(basename "$backup_file") in
                .backup_hash|.backup_time|changed_files.txt|deleted_files.txt|added_files.txt)
                    continue ;;
                *)
                    relative_path=${backup_file#$latest_backup/}
                    mkdir -p "$(dirname "$TARGET_DIR/$relative_path")" 2>/dev/null || true
                    if ! cp -v "$backup_file" "$TARGET_DIR/$relative_path" 2>"$ERROR_DETAILS_FILE"; then
                        echo "failed:restore_copy" > "$STATUS_FILE"
                        echo -e "${RED}❌ 恢复文件失败 ($relative_path):${NC}" >&2
                        cat "$ERROR_DETAILS_FILE" >&2
                        return 1
                    fi
                    ;;
            esac
        done
        
        verbose_echo "${GREEN}✅ 恢复完成${NC}"
    else
        echo -e "${RED}⚠️ 没有找到可用的备份${NC}"
        echo "没有找到可用的备份" > "$ERROR_DETAILS_FILE"
        echo "failed:no_backup" > "$STATUS_FILE"
        echo -e "${RED}❌ 没有找到可用的备份${NC}" >&2
    fi
}

# 主部署流程
deploy() {
    # 记录部署开始时间
    DEPLOY_START_TIME=$(date +%s)
    
    # 确保缓存目录有效
    if [ ! -d "$GIT_CACHE/.git" ]; then
        init_git_cache || return 1
    else
        if ! (cd "$GIT_CACHE" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
            echo -e "${RED}⚠️ 检测到无效缓存仓库，重新初始化...${NC}"
            init_git_cache || return 1
        fi
    fi

    # 强制更新代码（关键修改）
    if ! update_git_cache; then
        return 1
    fi

    # 获取当前版本
    CURRENT_HASH=$(cd "$GIT_CACHE" && git rev-parse HEAD)
    LAST_HASH_FILE="$TARGET_DIR/.last_commit"

    # 获取上次部署版本
    if [ -f "$LAST_HASH_FILE" ]; then
        LAST_HASH=$(cat "$LAST_HASH_FILE")
        if ! (cd "$GIT_CACHE" && git rev-parse --verify -q "$LAST_HASH" >/dev/null); then
            echo -e "${RED}⚠️ 检测到无效的last_commit，使用初始commit${NC}"
            LAST_HASH=$(cd "$GIT_CACHE" && git rev-list --max-parents=0 HEAD)
        fi
    else
        LAST_HASH=$(cd "$GIT_CACHE" && git rev-list --max-parents=0 HEAD)
    fi

    # 生成变更文件列表（使用更可靠的diff-index）
    show_progress "检查变更文件"
    if ! (cd "$GIT_CACHE" && git diff-index --name-only --diff-filter=ACMRT "$LAST_HASH") > /tmp/changed_files.txt 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:diff_changed_files" > "$STATUS_FILE"
        echo -e "${RED}❌ 生成变更文件列表失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi
    
    if ! (cd "$GIT_CACHE" && git diff-index --name-only --diff-filter=D "$LAST_HASH") > /tmp/deleted_files.txt 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:diff_deleted_files" > "$STATUS_FILE"
        echo -e "${RED}❌ 生成删除文件列表失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi

    # 应用过滤器过滤文件
    FILTERED_CHANGED_FILES=$(filter_files "/tmp/changed_files.txt")
    FILTERED_DELETED_FILES=$(filter_files "/tmp/deleted_files.txt")
    
    # 将过滤后的文件列表替换原始文件列表
    mv "$FILTERED_CHANGED_FILES" /tmp/changed_files.txt
    mv "$FILTERED_DELETED_FILES" /tmp/deleted_files.txt

    # 检查是否有变更
    if [ -s /tmp/changed_files.txt ] || [ -s /tmp/deleted_files.txt ]; then
        if [ "$VERBOSE" = true ]; then
            echo -e "${YELLOW}🔄 检测到变更:${NC}"
            echo -e "  旧版本: $(cd "$GIT_CACHE" && git log -1 --format="%h (%s)" $LAST_HASH)"
            echo -e "  新版本: $(cd "$GIT_CACHE" && git log -1 --format="%h (%s)" $CURRENT_HASH)"
            echo -e "${PROGRESS_LINE}"
            
            # 显示变更摘要
            echo -e "${YELLOW}变更摘要:${NC}"
            [ -s /tmp/changed_files.txt ] && echo -e "${GREEN}修改/新增文件:${NC}\n$(cat /tmp/changed_files.txt)"
            [ -s /tmp/deleted_files.txt ] && echo -e "${RED}删除文件:${NC}\n$(cat /tmp/deleted_files.txt)"
            echo -e "${PROGRESS_LINE}"
        fi
        
        # 创建备份
        create_backup || return 1
        
        # 统计文件数量
        DEPLOY_STATS_ADDED=0
        DEPLOY_STATS_MODIFIED=0
        DEPLOY_STATS_DELETED=$(wc -l < /tmp/deleted_files.txt | tr -d ' ')
        
        # 同步变更文件
        show_progress "同步变更文件"
        verbose_echo "${YELLOW}📂 同步变更文件:${NC}"
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                # 统计新增和修改的文件
                if [ -f "$TARGET_DIR/$file" ]; then
                    DEPLOY_STATS_MODIFIED=$((DEPLOY_STATS_MODIFIED + 1))
                    verbose_echo "${GREEN}  📝 $file (修改)${NC}"
                else
                    DEPLOY_STATS_ADDED=$((DEPLOY_STATS_ADDED + 1))
                    verbose_echo "${GREEN}  ➕ $file (新增)${NC}"
                fi
                
                mkdir -p "$TARGET_DIR/$(dirname "$file")" 2>/dev/null || true
                # 移除-v参数以避免中文文件名问题
                if ! cp "$GIT_CACHE/$file" "$TARGET_DIR/$file" 2>"$ERROR_DETAILS_FILE"; then
                    echo -e "${RED}❌ 文件同步失败${NC}";
                    echo "failed:file_copy" > "$STATUS_FILE"
                    echo -e "${RED}❌ 文件同步失败 ($file):${NC}" >&2
                    cat "$ERROR_DETAILS_FILE" >&2
                    restore_backup;
                    return 1;
                fi
            fi
        done < /tmp/changed_files.txt
        
        # 处理删除的文件
        show_progress "删除过期文件"
        verbose_echo "${YELLOW}🗑️ 删除文件:${NC}"
        while IFS= read -r file; do
            if [ -n "$file" ] && [ -f "$TARGET_DIR/$file" ]; then
                verbose_echo "${RED}  ❌ $file ${NC}"
                file_dir=$(dirname "$TARGET_DIR/$file")
                # 移除-v参数以避免中文文件名问题
                if ! rm -f "$TARGET_DIR/$file" 2>"$ERROR_DETAILS_FILE"; then
                    echo -e "${RED}❌ 文件删除失败${NC}";
                    echo "failed:file_remove" > "$STATUS_FILE"
                    echo -e "${RED}❌ 文件删除失败 ($file):${NC}" >&2
                    cat "$ERROR_DETAILS_FILE" >&2
                    restore_backup;
                    return 1;
                fi
                # 递归清理空目录
                clean_empty_dirs "$file_dir"
            fi
        done < /tmp/deleted_files.txt

        # 同步缺失的文件
        show_progress "同步缺失文件"
        if ! sync_missing_files; then
            return 1
        fi

        # 记录新版本
        echo "$CURRENT_HASH" > "$LAST_HASH_FILE"
        
        # 设置权限
        show_progress "设置文件权限"
        verbose_echo "${YELLOW}🔒 设置文件权限...${NC}"
        # find "$TARGET_DIR" -type d -exec chmod 755 {} \;
        # find "$TARGET_DIR" -type f -exec chmod 644 {} \;
        
        # 记录部署结束时间
        DEPLOY_END_TIME=$(date +%s)
        
        echo "success" > "$STATUS_FILE"
        show_progress "部署完成"
        verbose_echo "${GREEN}🎉 部署成功 $(date '+%Y-%m-%d %H:%M:%S')${NC}"

    else
        # 记录部署开始时间（如果尚未记录）
        if [ -z "$DEPLOY_START_TIME" ]; then
            DEPLOY_START_TIME=$(date +%s)
        fi
        
        # 记录部署结束时间
        DEPLOY_END_TIME=$(date +%s)
        
        # 即使没有变更，也要检查是否有缺失的文件需要同步
        show_progress "同步缺失文件"
        if ! sync_missing_files; then
            return 1
        fi
        
        echo "no_change" > "$STATUS_FILE"
        show_progress "无变更完成"
        verbose_echo "${GREEN}✅ 无新变更${NC}"
    fi
}

# ====================== 脚本入口 ======================
# 显示帮助信息
if [ "$SHOW_HELP" = true ]; then
    echo "===================================================="
     echo "
   ____ _ _        _____ _ _            ____             _
  / ___(_) |_     |  ___(_) | ___      |  _ \  ___ _ __ | | ___  _   _  ___ _ __
 | |  _| | __|____| |_  | | |/ _ \_____| | | |/ _ \ '_ \| |/ _ \| | | |/ _ \ '__|
 | |_| | | ||_____|  _| | | |  __/_____| |_| |  __/ |_) | | (_) | |_| |  __/ |
  \____|_|\__|    |_|   |_|_|\___|     |____/ \___| .__/|_|\___/ \__, |\___|_|
                                                  |_|            |___/
    "
    echo "===================================================="
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h                  显示此帮助信息"
    echo "  -v                  详细模式，显示更多部署过程信息"
    echo "  -t <target_dir>     设置目标部署目录 (默认: $TARGET_DIR)"
    echo "  -r <git_repo>       设置Git仓库地址 (默认: $GIT_REPO)"
    echo "  -w <deploy_dir>     设置部署工作目录，基于此目录和分支名自动设置缓存、备份等路径"
    echo "  -c <git_cache>      设置Git缓存目录 (默认: 基于部署工作目录或 $GIT_CACHE)"
    echo "  -b <git_branch>     设置Git分支 (默认: $GIT_BRANCH)"
    echo "  -d <backup_dir>     设置备份目录 (默认: 基于部署工作目录或 $BACKUP_DIR)"
    echo "  -n <max_backups>    设置最大备份数量 (默认: $MAX_BACKUPS)"
    echo "  -s <status_file>    设置状态文件路径 (默认: 基于部署工作目录或 $STATUS_FILE)"
    echo "  -e <error_file>     设置错误详情文件路径 (默认: 基于部署工作目录或 $ERROR_DETAILS_FILE)"
    echo "  -i <ignore_file>    设置忽略文件路径 (默认: 基于部署工作目录或 $IGNORE_FILE)"
    echo "  -l <lock_file>      设置锁文件路径 (默认: 基于部署工作目录或 $LOCK_FILE)"
    echo ""
    echo "说明:"
    echo "  如果未设置部署工作目录(-w)，则默认使用脚本所在目录下的deploy目录（脚本默认路径为/www/wwwroot/gysx-server-deploy）"
    echo "  基于部署工作目录和分支名自动设置以下路径:"
    echo "    分支部署目录:    <deploy_dir>/<branch_name>"
    echo "    Git缓存目录:     <分支部署目录>/cache"
    echo "    备份目录:        <分支部署目录>/backups"
    echo "    状态文件:        <分支部署目录>/deploy_status"
    echo "    错误详情文件:    <分支部署目录>/error_details"
    echo "    忽略文件:        <分支部署目录>/.deploy-ignore"
    echo "    锁文件:          <分支部署目录>/deploy.lock"
    echo ""
    echo "忽略文件(.deploy-ignore)格式:"
    echo "  每一行代表一个过滤规则，支持以下格式:"
    echo "  1. 完整路径: /path/to/file.txt"
    echo "  2. 相对路径: path/to/dir/"
    echo "  3. 通配符模式: *.zip, *.log"
    echo "  4. 注释: 以 # 开头的行将被忽略"
    echo "  5. 空行: 空行将被忽略"
    echo ""
    echo "示例:"
    echo "  $0                  # 使用默认配置进行部署"
    echo "  $0 -v               # 使用默认配置并开启详细模式进行部署"
    echo "  $0 -b develop       # 部署develop分支"
    echo "  $0 -w /path/to/deploy -b feature/new-ui  # 指定工作目录和分支"
    echo "  $0 -t /path/to/target -b feature/new-ui  # 指定目标目录和分支"
    echo "  $0 -h               # 显示此帮助信息"
    echo ""
    exit 0
fi

# 验证参数完整性
if ! validate_params; then
    echo -e "${RED}参数验证失败，请检查参数配置${NC}" >&2
    exit 1
fi

# 初始化状态标记
echo "running" > "$STATUS_FILE"
echo "" > "$ERROR_DETAILS_FILE"

echo -e "\n${GREEN}===== 开始部署 =====${NC}"
echo -e "${GREEN}开始时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
if [ "$VERBOSE" = true ]; then
    echo "详细模式: 开启"
else
    echo "详细模式: 关闭 (使用 -v 参数开启详细输出)"
fi
echo -e "目标目录: ${TARGET_DIR}"
echo -e "Git仓库: ${GIT_REPO}"

# 显示部署目录信息
if [ "$DEPLOY_DIR" != "${SCRIPT_DIR}/deploy" ]; then
    echo -e "部署工作目录: ${DEPLOY_DIR}"
    echo -e "分支部署目录: ${DEPLOY_DIR}/${GIT_BRANCH}"
else
    echo -e "部署工作目录: ${SCRIPT_DIR}/deploy (默认)"
    echo -e "分支部署目录: ${SCRIPT_DIR}/deploy/${GIT_BRANCH}"
fi

echo -e "Git缓存: ${GIT_CACHE}"
echo -e "备份目录: ${BACKUP_DIR}"
echo -e "最大备份数: ${MAX_BACKUPS}"
echo -e "状态文件: ${STATUS_FILE}"
echo -e "错误详情文件: ${ERROR_DETAILS_FILE}"
echo -e "Git分支: ${GIT_BRANCH}"
echo -e "忽略文件: ${IGNORE_FILE}"
echo -e "锁文件: ${LOCK_FILE}"
echo ""  # 空行，为进度条显示预留位置

# 检查是否已有实例在运行
if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE")
    if ps -p "$LOCK_PID" > /dev/null 2>&1; then
        echo -e "${RED}❌ 检测到部署脚本已在运行中 (PID: $LOCK_PID)${NC}" >&2
        exit 1
    else
        # 清理无效的锁文件
        rm -f "$LOCK_FILE"
    fi
fi

# 创建锁文件
echo $$ > "$LOCK_FILE"
# 确保脚本退出时清理锁文件
trap 'rm -f "$LOCK_FILE"' EXIT

trap 'echo "failed:unexpected_error" > "$STATUS_FILE"; echo "捕获到未预期的错误" > "$ERROR_DETAILS_FILE"; echo -e "${RED}❌ 捕获到未预期的错误:${NC}" >&2; cat "$ERROR_DETAILS_FILE" >&2' ERR

# 重置进度
CURRENT_STEP=0
# 显示初始进度条
show_progress "开始部署"
deploy

# 读取状态供后续脚本使用
DEPLOY_STATUS=$(cat "$STATUS_FILE")
echo -e "\n${BLUE}部署状态: $DEPLOY_STATUS${NC}"

# 计算总耗时
SCRIPT_END_TIME=$(date +%s)
SCRIPT_DURATION=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
DEPLOY_DURATION=$((DEPLOY_END_TIME - DEPLOY_START_TIME))

# 如果部署失败，输出错误详情
if [[ "$DEPLOY_STATUS" == failed:* ]]; then
    ERROR_DETAILS=$(cat "$ERROR_DETAILS_FILE")
    if [ -n "$ERROR_DETAILS" ]; then
        echo -e "${RED}错误详情: $ERROR_DETAILS${NC}"
    fi
else
    # 显示部署统计信息
    echo -e "\n${GREEN}===== 部署统计 =====${NC}"
    echo -e "${GREEN}新增文件数: ${DEPLOY_STATS_ADDED}${NC}"
    echo -e "${GREEN}修改文件数: ${DEPLOY_STATS_MODIFIED}${NC}"
    echo -e "${GREEN}删除文件数: ${DEPLOY_STATS_DELETED}${NC}"
    echo -e "${GREEN}部署耗时: $(format_duration $DEPLOY_DURATION)${NC}"
    echo -e "${GREEN}总耗时: $(format_duration $SCRIPT_DURATION)${NC}"
fi

echo -e "${GREEN}===== 执行完成 =====${NC}\n"
echo -e "${GREEN}结束时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"

# 返回状态码
case "$DEPLOY_STATUS" in
    success|no_change) exit 0 ;;
    failed:*) exit 1 ;;
    *) exit 2 ;;
esac