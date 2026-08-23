#!/bin/bash
set -euo pipefail  # 遇到错误立即退出

# 记录脚本开始时间
SCRIPT_START_TIME=$(date +%s)

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 解决Git中文文件名编码问题
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# 仅对本脚本内的 git 命令生效，不修改用户全局 git 配置
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.quotepath
export GIT_CONFIG_VALUE_0=off

# 默认配置变量
TARGET_DIR="/www/wwwroot/project"  # 生产目录（无.git）
GIT_REPO=".git"                           # 仓库地址
GIT_CLONE_METHOD=""                     # 克隆方式: https 或 ssh
GIT_BRANCH="master"                   # Git分支
DEPLOY_DIR=""                         # 部署工作目录
GIT_CACHE=""                          # Git缓存目录（基于部署工作目录）
BACKUP_DIR=""                         # 备份目录（基于部署工作目录）
MAX_BACKUPS=5                         # 保留的备份数量
STATUS_FILE=""                        # 状态标记文件（基于部署工作目录）
ERROR_DETAILS_FILE=""                 # 错误详情文件（基于部署工作目录）
IGNORE_FILE=""                        # 忽略文件路径
LOCK_FILE=""                          # 脚本锁文件路径
GIT_CREDENTIAL=""                     # HTTPS 凭据 (token 或 user:pass)
GIT_CREDENTIAL_USER="x-access-token"  # HTTPS token 认证用户名
SET_PERMISSIONS=true                  # 是否设置文件权限
FILE_MODE="644"                       # 文件权限模式
DIR_MODE="755"                        # 目录权限模式
CLONE_DEPTH=50                        # 浅克隆深度，0 表示完整克隆
RSYNC_MIN_FILES=5                     # 达到该文件数时使用 rsync 批量同步

# 解析命令行参数
VERBOSE=false
SHOW_HELP=false
GIT_CREDENTIAL="${GIT_DEPLOY_CREDENTIAL:-}"
GIT_CREDENTIAL_USER="${GIT_DEPLOY_CREDENTIAL_USER:-x-access-token}"
while getopts "hvt:r:w:b:d:n:s:e:c:i:l:u:U:F:D:PR:m:" opt; do
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
    u)
      GIT_CREDENTIAL="$OPTARG"
      ;;
    U)
      GIT_CREDENTIAL_USER="$OPTARG"
      ;;
    F)
      FILE_MODE="$OPTARG"
      ;;
    D)
      DIR_MODE="$OPTARG"
      ;;
    P)
      SET_PERMISSIONS=false
      ;;
    R)
      CLONE_DEPTH="$OPTARG"
      ;;
    m)
      RSYNC_MIN_FILES="$OPTARG"
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
TMP_DIR="${BRANCH_DEPLOY_DIR}/tmp"
CHANGED_FILES="${TMP_DIR}/changed_files.txt"
DELETED_FILES="${TMP_DIR}/deleted_files.txt"
ALL_REPO_FILES="${TMP_DIR}/all_repo_files.txt"
# 确保部署目录存在
mkdir -p "$BRANCH_DEPLOY_DIR" "$TMP_DIR"
# 基于部署工作目录和分支名设置其他路径的默认值
GIT_CACHE="${GIT_CACHE:-${BRANCH_DEPLOY_DIR}/cache}"
BACKUP_DIR="${BACKUP_DIR:-${BRANCH_DEPLOY_DIR}/backups}"
STATUS_FILE="${STATUS_FILE:-${BRANCH_DEPLOY_DIR}/deploy_status}"
ERROR_DETAILS_FILE="${ERROR_DETAILS_FILE:-${BRANCH_DEPLOY_DIR}/error_details}"
IGNORE_FILE="${IGNORE_FILE:-${BRANCH_DEPLOY_DIR}/.deploy-ignore}"
LOCK_FILE="${LOCK_FILE:-${BRANCH_DEPLOY_DIR}/deploy.lock}"
LAST_HASH_FILE="${BRANCH_DEPLOY_DIR}/.last_commit"
LEGACY_LAST_HASH_FILE="${TARGET_DIR}/.last_commit"
IGNORE_EXACT_FILE="${TMP_DIR}/ignore_exact.txt"
IGNORE_DIR_FILE="${TMP_DIR}/ignore_dir.txt"
IGNORE_GLOB_REGEX_FILE="${TMP_DIR}/ignore_glob_regex.txt"

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
    
    if [ -z "$GIT_REPO" ] || [ "$GIT_REPO" = ".git" ]; then
        echo -e "${RED}❌ 错误: Git仓库地址 (-r) 不能为空或使用默认值 '.git'${NC}" >&2
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

    if ! [[ "$CLONE_DEPTH" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}❌ 错误: 克隆深度 (-R) 必须是数字，当前值为 '$CLONE_DEPTH'${NC}" >&2
        return 1
    fi

    if ! [[ "$RSYNC_MIN_FILES" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}❌ 错误: rsync 阈值 (-m) 必须是数字，当前值为 '$RSYNC_MIN_FILES'${NC}" >&2
        return 1
    fi

    if ! [[ "$FILE_MODE" =~ ^[0-7]{3,4}$ ]]; then
        echo -e "${RED}❌ 错误: 文件权限 (-F) 格式无效，当前值为 '$FILE_MODE'${NC}" >&2
        return 1
    fi

    if ! [[ "$DIR_MODE" =~ ^[0-7]{3,4}$ ]]; then
        echo -e "${RED}❌ 错误: 目录权限 (-D) 格式无效，当前值为 '$DIR_MODE'${NC}" >&2
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

# 根据仓库地址判断克隆方式（HTTPS / SSH）并规范化地址
resolve_git_repo_url() {
    local url="$GIT_REPO"

    if [[ "$url" =~ ^https?:// ]]; then
        GIT_CLONE_METHOD="https"
        return 0
    fi

    if [[ "$url" =~ ^git@ ]] || [[ "$url" =~ ^ssh:// ]]; then
        GIT_CLONE_METHOD="ssh"
        return 0
    fi

    # 无协议前缀: host:path → SSH（自动补全 git@ 前缀）
    if [[ "$url" =~ : ]] && [[ "$url" != *"://"* ]]; then
        GIT_CLONE_METHOD="ssh"
        GIT_REPO="git@${url}"
        return 0
    fi

    # 无协议前缀: host/path → HTTPS
    if [[ "$url" =~ / ]] && [[ "$url" != *"://"* ]]; then
        GIT_CLONE_METHOD="https"
        GIT_REPO="https://${url}"
        if [[ "$GIT_REPO" != *.git ]]; then
            GIT_REPO="${GIT_REPO}.git"
        fi
        return 0
    fi

    echo -e "${RED}❌ 错误: 无法识别的 Git 仓库地址格式 '${url}'${NC}" >&2
    echo -e "${YELLOW}请使用 HTTPS (https://host/user/repo) 或 SSH (git@host:user/repo) 格式${NC}" >&2
    return 1
}

# 为 HTTPS 仓库注入凭据（token 或 user:pass）
apply_https_credential() {
    if [ "$GIT_CLONE_METHOD" != "https" ] || [ -z "$GIT_CREDENTIAL" ]; then
        return 0
    fi

    local credential="$GIT_CREDENTIAL"
    if [[ "$credential" != *:* ]]; then
        credential="${GIT_CREDENTIAL_USER}:${credential}"
    fi

    if [[ "$GIT_REPO" =~ ^https://([^/]+)(/.*)$ ]]; then
        local host="${BASH_REMATCH[1]}"
        local path="${BASH_REMATCH[2]}"
        if [[ "$host" != *@* ]]; then
            GIT_REPO="https://${credential}@${host}${path}"
            verbose_echo "${YELLOW}🔑 已注入 HTTPS 凭据${NC}"
        fi
    fi
    return 0
}

# 将 glob 模式转换为正则表达式
glob_to_regex() {
    local pattern="$1"
    local regex="" char i
    for ((i=0; i<${#pattern}; i++)); do
        char="${pattern:$i:1}"
        case "$char" in
            .) regex+="\\." ;;
            '*') regex+=".*" ;;
            '?') regex+="." ;;
            '[') regex+="\\[" ;;
            ']') regex+="\\]" ;;
            *) regex+="$char" ;;
        esac
    done
    echo "^${regex}$"
}

# 预加载忽略规则（避免每次过滤重复解析）
load_ignore_cache() {
    if [ "${IGNORE_CACHE_LOADED:-false}" = true ]; then
        return 0
    fi

  : > "$IGNORE_EXACT_FILE"
  : > "$IGNORE_DIR_FILE"
  : > "$IGNORE_GLOB_REGEX_FILE"

    local patterns=()
    if [ -f "$IGNORE_FILE" ]; then
        while IFS= read -r line; do
            patterns+=("$line")
        done < <(grep -E -v '^\s*(#|$)' "$IGNORE_FILE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^\///')
    fi
    patterns+=(".git")
    patterns+=(".git/")

    local pattern regex_parts=() regex
    for pattern in "${patterns[@]}"; do
        if [[ "$pattern" == */ ]]; then
            echo "$pattern" >> "$IGNORE_DIR_FILE"
        elif [[ "$pattern" == *[\*\?]* ]] || [[ "$pattern" == *"["* ]]; then
            regex_parts+=("$(glob_to_regex "$pattern")")
        else
            echo "$pattern" >> "$IGNORE_EXACT_FILE"
        fi
    done

    if [ "${#regex_parts[@]}" -gt 0 ]; then
        regex=$(IFS='|'; echo "${regex_parts[*]}")
        echo "$regex" > "$IGNORE_GLOB_REGEX_FILE"
    fi

    IGNORE_CACHE_LOADED=true
    return 0
}

# 过滤文件函数（grep 批量过滤，大仓库性能更好）
filter_files() {
    local file_list="$1"
    local filtered_list="${TMP_DIR}/filtered_$$_$(basename "$file_list")"

    load_ignore_cache
    cp "$file_list" "$filtered_list"

    if [ -s "$IGNORE_EXACT_FILE" ]; then
        local tmp_filtered="${filtered_list}.tmp"
        if grep -Fxvf "$IGNORE_EXACT_FILE" "$filtered_list" > "$tmp_filtered" 2>/dev/null; then
            mv "$tmp_filtered" "$filtered_list"
        else
            : > "$filtered_list"
        fi
    fi

    if [ -s "$IGNORE_DIR_FILE" ]; then
        local tmp_filtered="${filtered_list}.tmp"
        local prefix
        cp "$filtered_list" "$tmp_filtered"
        while IFS= read -r prefix; do
            if [ -n "$prefix" ]; then
                awk -v p="$prefix" 'substr($0, 1, length(p)) != p' "$tmp_filtered" > "${tmp_filtered}.pass"
                mv "${tmp_filtered}.pass" "$tmp_filtered"
            fi
        done < "$IGNORE_DIR_FILE"
        mv "$tmp_filtered" "$filtered_list"
    fi

    if [ -s "$IGNORE_GLOB_REGEX_FILE" ]; then
        local tmp_filtered="${filtered_list}.tmp"
        local regex
        regex=$(tr -d '\n' < "$IGNORE_GLOB_REGEX_FILE")
        if grep -Ev "$regex" "$filtered_list" > "$tmp_filtered" 2>/dev/null; then
            mv "$tmp_filtered" "$filtered_list"
        else
            : > "$filtered_list"
        fi
    fi

    echo "$filtered_list"
    return 0
}

# 进度条配置
TOTAL_STEPS=10
CURRENT_STEP=0
PROGRESS_LINE=""  # 存储当前进度条内容
PROGRESS_INITIALIZED=false
IS_TTY=false
[ -t 1 ] && IS_TTY=true

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

    if [ "$IS_TTY" = true ] && [ "$PROGRESS_INITIALIZED" = true ]; then
        echo -e "\033[1A\033[2K${PROGRESS_LINE}"
    else
        echo -e "${PROGRESS_LINE}"
        PROGRESS_INITIALIZED=true
    fi
}

# 条件输出函数，仅在VERBOSE为true时输出
verbose_echo() {
    if [ "$VERBOSE" = true ]; then
        echo -e "$1"
    fi
}

# 统计非空行数
count_file_lines() {
    local file="$1"
    if [ ! -s "$file" ]; then
        echo 0
        return 0
    fi
    wc -l < "$file" | tr -d ' '
}

# 确保 commit 在浅克隆缓存中可用
ensure_commit_fetched() {
    local hash="$1"
    if [ -z "$hash" ]; then
        return 0
    fi
    if (cd "$GIT_CACHE" && git cat-file -e "${hash}^{commit}" 2>/dev/null); then
        return 0
    fi
    verbose_echo "${YELLOW}📥 拉取历史 commit ${hash}...${NC}"
  if ! (cd "$GIT_CACHE" && git fetch --depth 1 origin "$hash") 2>"$ERROR_DETAILS_FILE"; then
        return 1
    fi
    return 0
}

# 批量同步文件到目标目录（大文件量时优先 rsync）
sync_files_to_target() {
    local file_list="$1"
    local src_dir="$2"
    local dest_dir="$3"
    local status_on_fail="$4"

    if [ ! -s "$file_list" ]; then
        return 0
    fi

    local file_count
    file_count=$(count_file_lines "$file_list")

    if command -v rsync >/dev/null 2>&1 && [ "$file_count" -ge "$RSYNC_MIN_FILES" ]; then
        verbose_echo "${YELLOW}📦 使用 rsync 批量同步 ${file_count} 个文件...${NC}"
        local rsync_args=(-a --files-from="$file_list")
        if [ "$SET_PERMISSIONS" = true ]; then
            rsync_args+=(--chmod="D${DIR_MODE},F${FILE_MODE}")
        fi
        if ! rsync "${rsync_args[@]}" "${src_dir}/" "${dest_dir}/" 2>"$ERROR_DETAILS_FILE"; then
            echo "$status_on_fail" > "$STATUS_FILE"
            echo -e "${RED}❌ rsync 批量同步失败:${NC}" >&2
            cat "$ERROR_DETAILS_FILE" >&2
            return 1
        fi
        return 0
    fi

    local file
    while IFS= read -r file; do
        if [ -n "$file" ]; then
            mkdir -p "${dest_dir}/$(dirname "$file")" 2>/dev/null || true
            if ! cp "${src_dir}/${file}" "${dest_dir}/${file}" 2>"$ERROR_DETAILS_FILE"; then
                echo "$status_on_fail" > "$STATUS_FILE"
                echo -e "${RED}❌ 文件同步失败 ($file):${NC}" >&2
                cat "$ERROR_DETAILS_FILE" >&2
                return 1
            fi
        fi
    done < "$file_list"
    return 0
}

# 批量备份文件
backup_files_from_list() {
    local file_list="$1"
    local backup_root="$2"
    local status_on_fail="$3"

    if [ ! -s "$file_list" ]; then
        return 0
    fi

    local file_count
    file_count=$(count_file_lines "$file_list")

    if command -v rsync >/dev/null 2>&1 && [ "$file_count" -ge "$RSYNC_MIN_FILES" ]; then
        if ! rsync -a --files-from="$file_list" "${TARGET_DIR}/" "${backup_root}/" 2>"$ERROR_DETAILS_FILE"; then
            echo "$status_on_fail" > "$STATUS_FILE"
            echo -e "${RED}❌ rsync 批量备份失败:${NC}" >&2
            cat "$ERROR_DETAILS_FILE" >&2
            return 1
        fi
        return 0
    fi

    local file
    while IFS= read -r file; do
        if [ -n "$file" ] && [ -f "${TARGET_DIR}/${file}" ]; then
            mkdir -p "${backup_root}/$(dirname "$file")" 2>/dev/null || true
            if ! cp "${TARGET_DIR}/${file}" "${backup_root}/${file}" 2>"$ERROR_DETAILS_FILE"; then
                echo "$status_on_fail" > "$STATUS_FILE"
                echo -e "${RED}❌ 备份文件失败 ($file):${NC}" >&2
                cat "$ERROR_DETAILS_FILE" >&2
                return 1
            fi
        fi
    done < "$file_list"
    return 0
}

# 设置目标目录权限
apply_permissions() {
    if [ "$SET_PERMISSIONS" != true ]; then
        verbose_echo "${YELLOW}⏭️ 跳过权限设置 (-P)${NC}"
        return 0
    fi

    verbose_echo "${YELLOW}🔒 设置目录权限 ${DIR_MODE}、文件权限 ${FILE_MODE}...${NC}"
    if ! find "$TARGET_DIR" -type d -exec chmod "$DIR_MODE" {} + 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:chmod_dir" > "$STATUS_FILE"
        echo -e "${RED}❌ 设置目录权限失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi
    if ! find "$TARGET_DIR" -type f -exec chmod "$FILE_MODE" {} + 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:chmod_file" > "$STATUS_FILE"
        echo -e "${RED}❌ 设置文件权限失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi
    return 0
}

# 迁移旧版 .last_commit 位置
migrate_last_commit_file() {
    if [ -f "$LAST_HASH_FILE" ]; then
        return 0
    fi
    if [ -f "$LEGACY_LAST_HASH_FILE" ]; then
        if cp "$LEGACY_LAST_HASH_FILE" "$LAST_HASH_FILE" 2>"$ERROR_DETAILS_FILE"; then
            verbose_echo "${YELLOW}📋 已从目标目录迁移 .last_commit 到分支部署目录${NC}"
        fi
    fi
    return 0
}

# 同步缺失的文件
sync_missing_files() {
    verbose_echo "${YELLOW}🔍 检查缺失的文件...${NC}"
    
    # 获取仓库跟踪文件列表（与 diff 逻辑一致，排除 .gitignore 项）
    if ! (cd "$GIT_CACHE" && git ls-files) > "$ALL_REPO_FILES" 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:list_repo_files" > "$STATUS_FILE"
        echo -e "${RED}❌ 获取仓库文件列表失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi
    
    # 过滤掉忽略的文件
    FILTERED_ALL_FILES=$(filter_files "$ALL_REPO_FILES")
    mv "$FILTERED_ALL_FILES" "$ALL_REPO_FILES"

    local missing_list="${TMP_DIR}/missing_files.txt"
    : > "$missing_list"
    while IFS= read -r file; do
        if [ -n "$file" ] && [ ! -f "$TARGET_DIR/$file" ]; then
            echo "$file" >> "$missing_list"
            verbose_echo "${GREEN}  ➕ 补充缺失文件: $file${NC}"
        fi
    done < "$ALL_REPO_FILES"

    local missing_files_count
    missing_files_count=$(count_file_lines "$missing_list")
    if [ "$missing_files_count" -gt 0 ]; then
        if ! sync_files_to_target "$missing_list" "$GIT_CACHE" "$TARGET_DIR" "failed:missing_file_copy"; then
            return 1
        fi
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
            verbose_echo "${YELLOW}  🗑️ 删除空目录: $dir${NC}"
            rmdir "$dir" || break
            dir=$(dirname "$dir")
        else
            break
        fi
    done
}

# 同步远程仓库地址（仓库 URL 变更时无需重建缓存）
sync_git_remote_url() {
    if [ ! -d "$GIT_CACHE/.git" ]; then
        return 0
    fi
    local current_url
    current_url=$(cd "$GIT_CACHE" && git remote get-url origin 2>/dev/null || true)
    if [ -n "$current_url" ] && [ "$current_url" != "$GIT_REPO" ]; then
        verbose_echo "${YELLOW}🔗 更新远程仓库地址: ${current_url} → ${GIT_REPO}${NC}"
        if ! (cd "$GIT_CACHE" && git remote set-url origin "$GIT_REPO") 2>"$ERROR_DETAILS_FILE"; then
            echo "failed:git_remote_url" > "$STATUS_FILE"
            echo -e "${RED}❌ 更新远程仓库地址失败:${NC}" >&2
            cat "$ERROR_DETAILS_FILE" >&2
            return 1
        fi
    fi
    return 0
}

# 初始化缓存仓库
init_git_cache() {
    show_progress "初始化Git缓存仓库"
    verbose_echo "${YELLOW}🔄 使用 ${GIT_CLONE_METHOD} 方式初始化 Git 缓存仓库...${NC}"
    verbose_echo "${YELLOW}   仓库地址: ${GIT_REPO}${NC}"
    rm -rf "$GIT_CACHE"
    local clone_args=()
    if [ "$CLONE_DEPTH" -gt 0 ]; then
        clone_args+=(--depth "$CLONE_DEPTH" --single-branch)
        verbose_echo "${YELLOW}   浅克隆深度: ${CLONE_DEPTH}${NC}"
    fi
    if ! git clone "${clone_args[@]}" -b "$GIT_BRANCH" "$GIT_REPO" "$GIT_CACHE" 2>"$ERROR_DETAILS_FILE"; then
        # 指定分支克隆失败时回退为默认分支克隆
        rm -rf "$GIT_CACHE"
        if ! git clone "${clone_args[@]}" "$GIT_REPO" "$GIT_CACHE" 2>"$ERROR_DETAILS_FILE"; then
            echo "failed:git_init" > "$STATUS_FILE"
            echo -e "${RED}❌ Git缓存仓库初始化失败${NC}" >&2
            cat "$ERROR_DETAILS_FILE" >&2
            return 1
        fi
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
        echo "远程${GIT_BRANCH}分支不存在" > "$ERROR_DETAILS_FILE"
        echo "failed:git_update" > "$STATUS_FILE"
        echo -e "${RED}❌ 远程${GIT_BRANCH}分支不存在${NC}" >&2
        return 1
    fi
    
    # 强制重置仓库
    local fetch_cmd=(git fetch origin --prune)
    if [ "$CLONE_DEPTH" -gt 0 ]; then
        fetch_cmd=(git fetch --depth "$CLONE_DEPTH" origin "$GIT_BRANCH" --prune)
    fi
    if ! (cd "$GIT_CACHE" && git clean -fd && "${fetch_cmd[@]}" && git reset --hard "origin/$GIT_BRANCH" && git checkout -f "$GIT_BRANCH") 2>"$ERROR_DETAILS_FILE"; then
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
    if ! backup_files_from_list "$CHANGED_FILES" "$BACKUP_DIR/$backup_name" "failed:backup_copy_changed"; then
        return 1
    fi

    # 备份将被删除的文件
    if ! backup_files_from_list "$DELETED_FILES" "$BACKUP_DIR/$backup_name" "failed:backup_copy_deleted"; then
        return 1
    fi
    if [ -s "$DELETED_FILES" ] && [ "$VERBOSE" = true ]; then
        while IFS= read -r file; do
            [ -n "$file" ] && verbose_echo "${YELLOW}  💾 备份将被删除的文件: $file${NC}"
        done < "$DELETED_FILES"
    fi
    
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
    if ! cp "$CHANGED_FILES" "$DELETED_FILES" "$BACKUP_DIR/$backup_name/" 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:backup_metadata" > "$STATUS_FILE"
        echo -e "${RED}❌ 复制元数据失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi
    
    # 清理旧备份
    ls -dt "$BACKUP_DIR"/backup_* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | while IFS= read -r old_backup; do
        [ -n "$old_backup" ] && rm -rf "$old_backup"
    done
    verbose_echo "${GREEN}✅ 备份完成 (位置: $BACKUP_DIR/$backup_name)${NC}"
}

# 恢复备份
restore_backup() {
    local latest_backup
    latest_backup=$(ls -dt "$BACKUP_DIR"/backup_* 2>/dev/null | head -n 1)
    if [ -z "$latest_backup" ]; then
        echo -e "${RED}⚠️ 没有找到可用的备份${NC}"
        echo "没有找到可用的备份" > "$ERROR_DETAILS_FILE"
        echo "failed:no_backup" > "$STATUS_FILE"
        echo -e "${RED}❌ 没有找到可用的备份${NC}" >&2
        return 1
    fi

    show_progress "恢复备份"
    verbose_echo "${YELLOW}🔄 正在从备份恢复: $(basename "$latest_backup")${NC}"

    # 删除新增的文件
    if [ -f "$latest_backup/added_files.txt" ]; then
        verbose_echo "${YELLOW}🗑️ 清理新增文件:${NC}"
        while IFS= read -r file; do
            if [ -n "$file" ] && [ -f "$TARGET_DIR/$file" ]; then
                verbose_echo "${RED}  ❌ 删除新增文件: $file${NC}"
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

    # 恢复被修改/删除的文件（避免管道子 shell 导致 return 失效）
    verbose_echo "${YELLOW}🔄 恢复被修改的文件...${NC}"
    local backup_file relative_path restore_failed=false
    while IFS= read -r backup_file; do
        case $(basename "$backup_file") in
            .backup_hash|.backup_time|changed_files.txt|deleted_files.txt|added_files.txt)
                continue
        esac
        relative_path=${backup_file#"$latest_backup"/}
        mkdir -p "$(dirname "$TARGET_DIR/$relative_path")" 2>/dev/null || true
        if ! cp "$backup_file" "$TARGET_DIR/$relative_path" 2>"$ERROR_DETAILS_FILE"; then
            echo "failed:restore_copy" > "$STATUS_FILE"
            echo -e "${RED}❌ 恢复文件失败 ($relative_path):${NC}" >&2
            cat "$ERROR_DETAILS_FILE" >&2
            restore_failed=true
            break
        fi
    done < <(find "$latest_backup" -type f)

    if [ "$restore_failed" = true ]; then
        return 1
    fi

    verbose_echo "${GREEN}✅ 恢复完成${NC}"
    return 0
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
        else
            sync_git_remote_url || return 1
        fi
    fi

    # 强制更新代码（关键修改）
    if ! update_git_cache; then
        return 1
    fi

    # 获取当前版本
    CURRENT_HASH=$(cd "$GIT_CACHE" && git rev-parse HEAD)
    migrate_last_commit_file

    # 获取上次部署版本
    if [ -f "$LAST_HASH_FILE" ]; then
        LAST_HASH=$(cat "$LAST_HASH_FILE")
        if ! ensure_commit_fetched "$LAST_HASH"; then
            echo -e "${RED}⚠️ 无法获取 last_commit ${LAST_HASH}，使用初始 commit${NC}"
            LAST_HASH=$(cd "$GIT_CACHE" && git rev-list --max-parents=0 HEAD)
        elif ! (cd "$GIT_CACHE" && git rev-parse --verify -q "$LAST_HASH" >/dev/null); then
            echo -e "${RED}⚠️ 检测到无效的 last_commit，使用初始 commit${NC}"
            LAST_HASH=$(cd "$GIT_CACHE" && git rev-list --max-parents=0 HEAD)
        fi
    else
        LAST_HASH=$(cd "$GIT_CACHE" && git rev-list --max-parents=0 HEAD)
    fi

    # 生成变更文件列表（使用更可靠的diff-index）
    show_progress "检查变更文件"
    if ! (cd "$GIT_CACHE" && git diff-index --name-only --diff-filter=ACMRT "$LAST_HASH") > "$CHANGED_FILES" 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:diff_changed_files" > "$STATUS_FILE"
        echo -e "${RED}❌ 生成变更文件列表失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi
    
    if ! (cd "$GIT_CACHE" && git diff-index --name-only --diff-filter=D "$LAST_HASH") > "$DELETED_FILES" 2>"$ERROR_DETAILS_FILE"; then
        echo "failed:diff_deleted_files" > "$STATUS_FILE"
        echo -e "${RED}❌ 生成删除文件列表失败:${NC}" >&2
        cat "$ERROR_DETAILS_FILE" >&2
        return 1
    fi

    # 应用过滤器过滤文件
    FILTERED_CHANGED_FILES=$(filter_files "$CHANGED_FILES")
    FILTERED_DELETED_FILES=$(filter_files "$DELETED_FILES")
    
    # 将过滤后的文件列表替换原始文件列表
    mv "$FILTERED_CHANGED_FILES" "$CHANGED_FILES"
    mv "$FILTERED_DELETED_FILES" "$DELETED_FILES"

    # 检查是否有变更
    if [ -s "$CHANGED_FILES" ] || [ -s "$DELETED_FILES" ]; then
        if [ "$VERBOSE" = true ]; then
            echo -e "${YELLOW}🔄 检测到变更:${NC}"
            echo -e "  旧版本: $(cd "$GIT_CACHE" && git log -1 --format="%h (%s)" $LAST_HASH)"
            echo -e "  新版本: $(cd "$GIT_CACHE" && git log -1 --format="%h (%s)" $CURRENT_HASH)"
            echo -e "${PROGRESS_LINE}"
            
            # 显示变更摘要
            echo -e "${YELLOW}变更摘要:${NC}"
            [ -s "$CHANGED_FILES" ] && echo -e "${GREEN}修改/新增文件:${NC}\n$(cat "$CHANGED_FILES")"
            [ -s "$DELETED_FILES" ] && echo -e "${RED}删除文件:${NC}\n$(cat "$DELETED_FILES")"
            echo -e "${PROGRESS_LINE}"
        fi
        
        # 创建备份
        create_backup || return 1
        DEPLOY_STATS_DELETED=$(count_file_lines "$DELETED_FILES")
        
        # 同步变更文件
        show_progress "同步变更文件"
        verbose_echo "${YELLOW}📂 同步变更文件:${NC}"
        if [ "$VERBOSE" = true ]; then
            while IFS= read -r file; do
                if [ -n "$file" ]; then
                    if [ -f "$TARGET_DIR/$file" ]; then
                        verbose_echo "${GREEN}  📝 $file (修改)${NC}"
                    else
                        verbose_echo "${GREEN}  ➕ $file (新增)${NC}"
                    fi
                fi
            done < "$CHANGED_FILES"
        fi
        DEPLOY_STATS_ADDED=0
        DEPLOY_STATS_MODIFIED=0
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                if [ -f "$TARGET_DIR/$file" ]; then
                    DEPLOY_STATS_MODIFIED=$((DEPLOY_STATS_MODIFIED + 1))
                else
                    DEPLOY_STATS_ADDED=$((DEPLOY_STATS_ADDED + 1))
                fi
            fi
        done < "$CHANGED_FILES"
        if ! sync_files_to_target "$CHANGED_FILES" "$GIT_CACHE" "$TARGET_DIR" "failed:file_copy"; then
            restore_backup
            return 1
        fi
        
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
        done < "$DELETED_FILES"

        # 同步缺失的文件
        show_progress "同步缺失文件"
        if ! sync_missing_files; then
            return 1
        fi

        # 记录新版本
        echo "$CURRENT_HASH" > "$LAST_HASH_FILE"
        
        # 设置权限
        show_progress "设置文件权限"
        if ! apply_permissions; then
            restore_backup
            return 1
        fi
        
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

        if ! apply_permissions; then
            return 1
        fi
        
        echo "no_change" > "$STATUS_FILE"
        show_progress "无变更完成"
        verbose_echo "${GREEN}✅ 无新变更${NC}"
    fi

    DEPLOY_END_TIME=$(date +%s)
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
    echo "                      支持 HTTPS / SSH 及无协议格式 (host/path 或 host:path)"
    echo "  -w <deploy_dir>     设置部署工作目录，基于此目录和分支名自动设置缓存、备份等路径"
    echo "  -c <git_cache>      设置Git缓存目录 (默认: 基于部署工作目录或 $GIT_CACHE)"
    echo "  -b <git_branch>     设置Git分支 (默认: $GIT_BRANCH)"
    echo "  -d <backup_dir>     设置备份目录 (默认: 基于部署工作目录或 $BACKUP_DIR)"
    echo "  -n <max_backups>    设置最大备份数量 (默认: $MAX_BACKUPS)"
    echo "  -s <status_file>    设置状态文件路径 (默认: 基于部署工作目录或 $STATUS_FILE)"
    echo "  -e <error_file>     设置错误详情文件路径 (默认: 基于部署工作目录或 $ERROR_DETAILS_FILE)"
    echo "  -i <ignore_file>    设置忽略文件路径 (默认: 基于部署工作目录或 $IGNORE_FILE)"
    echo "  -l <lock_file>      设置锁文件路径 (默认: 基于部署工作目录或 $LOCK_FILE)"
    echo "  -u <credential>     HTTPS 凭据 (token 或 user:pass)，也可用环境变量 GIT_DEPLOY_CREDENTIAL"
    echo "  -U <user>           HTTPS token 认证用户名 (默认: x-access-token)"
    echo "  -F <mode>           文件权限模式 (默认: $FILE_MODE)"
    echo "  -D <mode>           目录权限模式 (默认: $DIR_MODE)"
    echo "  -P                  跳过权限设置"
    echo "  -R <depth>          浅克隆深度，0 为完整克隆 (默认: $CLONE_DEPTH)"
    echo "  -m <count>          达到该文件数时使用 rsync 批量同步 (默认: $RSYNC_MIN_FILES)"
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
    echo "    last_commit:     <分支部署目录>/.last_commit"
    echo ""
    echo "HTTPS 凭据:"
    echo "  使用 -u <token> 或 -u user:pass，或设置环境变量 GIT_DEPLOY_CREDENTIAL"
    echo "  token 模式默认用户名可通过 -U 或 GIT_DEPLOY_CREDENTIAL_USER 指定"
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

# 解析仓库地址并判断克隆方式
if ! resolve_git_repo_url; then
    exit 1
fi
apply_https_credential

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
echo -e "Git仓库: ${GIT_REPO} (克隆方式: ${GIT_CLONE_METHOD})"

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
echo -e "last_commit: ${LAST_HASH_FILE}"
echo -e "克隆深度: ${CLONE_DEPTH} ($([ "$CLONE_DEPTH" -gt 0 ] && echo '浅克隆' || echo '完整克隆'))"
echo -e "rsync 阈值: ${RSYNC_MIN_FILES} 个文件"
echo -e "文件权限: ${FILE_MODE} / 目录权限: ${DIR_MODE} ($([ "$SET_PERMISSIONS" = true ] && echo '启用' || echo '已禁用 -P'))"
if [ -n "$GIT_CREDENTIAL" ]; then
    echo -e "HTTPS 凭据: 已配置"
fi
if [ "$IS_TTY" = true ]; then
    echo ""
fi

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

cleanup_on_exit() {
    rm -f "$LOCK_FILE"
}

on_unexpected_error() {
    echo "failed:unexpected_error" > "$STATUS_FILE"
    echo "捕获到未预期的错误" > "$ERROR_DETAILS_FILE"
    echo -e "${RED}❌ 捕获到未预期的错误:${NC}" >&2
    cat "$ERROR_DETAILS_FILE" >&2
}

trap cleanup_on_exit EXIT
trap on_unexpected_error ERR

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
if [ "$DEPLOY_END_TIME" -eq 0 ]; then
    DEPLOY_END_TIME=$SCRIPT_END_TIME
fi
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