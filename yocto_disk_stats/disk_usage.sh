#!/bin/sh

# 磁盘空间统计脚本 for Yocto Linux
# 支持统计 /bmhmi 和 /var/bmhmi 目录

# 默认设置
DEFAULT_MAX_DEPTH=3
DEFAULT_MIN_SIZE_MB=1
CSV_FILE_PREFIX="disk_usage"
VISITED_PATHS_FILE=""

# 显示用法信息
show_usage() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -d, --dir DIR      要统计的目录 (/bmhmi 或 /var/bmhmi)"
    echo "  -m, --max-depth N  最大显示深度 (默认: $DEFAULT_MAX_DEPTH)"
    echo "  -s, --min-size MB  最小显示大小MB (默认: $DEFAULT_MIN_SIZE_MB)"
    echo "  -o, --output FILE  输出CSV文件名前缀 (默认: $CSV_FILE_PREFIX)"
    echo "  -h, --help         显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 -d /bmhmi -m 3 -s 1"
    echo "  $0 -d /var/bmhmi -m 7 -s 1"
}

# 解析命令行参数
parse_arguments() {
    TARGET_DIR=""
    MAX_DEPTH=$DEFAULT_MAX_DEPTH
    MIN_SIZE_MB=$DEFAULT_MIN_SIZE_MB
    CSV_PREFIX=$CSV_FILE_PREFIX

    while [ $# -gt 0 ]; do
        case $1 in
            -d|--dir)
                TARGET_DIR="$2"
                shift 2
                ;;
            -m|--max-depth)
                MAX_DEPTH="$2"
                shift 2
                ;;
            -s|--min-size)
                MIN_SIZE_MB="$2"
                shift 2
                ;;
            -o|--output)
                CSV_PREFIX="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                echo "错误: 未知参数 $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # 验证必需参数
    if [ -z "$TARGET_DIR" ]; then
        echo "错误: 必须指定目标目录"
        show_usage
        exit 1
    fi

    if [ ! -d "$TARGET_DIR" ]; then
        echo "错误: 目录 '$TARGET_DIR' 不存在"
        exit 1
    fi
}

# 获取目录的规范化路径
get_normalized_path() {
    local dir="$1"
    local normalized=""

    if [ -z "$dir" ]; then
        echo ""
        return
    fi

    if [ -d "$dir" ]; then
        normalized=$(cd "$dir" 2>/dev/null && { pwd -P 2>/dev/null || pwd 2>/dev/null; })
        if [ -n "$normalized" ]; then
            echo "$normalized"
            return
        fi
    fi

    # 移除结尾的斜杠，确保根目录仍然为 /
    dir=$(echo "$dir" | sed 's:/*$::')
    if [ -z "$dir" ]; then
        echo "/"
    else
        echo "$dir"
    fi
}

# 检查目录是否已经处理过（用于去重）
has_directory_been_visited() {
    local dir="$1"

    if [ -z "$dir" ] || [ -z "$VISITED_PATHS_FILE" ] || [ ! -f "$VISITED_PATHS_FILE" ]; then
        return 1
    fi

    if grep -Fxq "$dir" "$VISITED_PATHS_FILE" 2>/dev/null; then
        return 0
    fi

    return 1
}

# 标记目录为已处理
remember_directory() {
    local dir="$1"

    if [ -n "$dir" ] && [ -n "$VISITED_PATHS_FILE" ]; then
        echo "$dir" >> "$VISITED_PATHS_FILE"
    fi
}

# 将字节转换为人类可读格式
format_size() {
    local bytes="$1"
    # 确保bytes是数字
    if [ -z "$bytes" ] || ! echo "$bytes" | grep -qE '^[0-9]+$'; then
        echo "0 bytes"
        return
    fi

    if [ "$bytes" -ge 1048576 ]; then
        echo "$(($bytes / 1048576)) MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(($bytes / 1024)) KB"
    else
        echo "$bytes bytes"
    fi
}

# 获取目录大小（包括所有子目录）
get_directory_size() {
    local dir="$1"
    local size=""

    # 尝试使用 GNU du 的 -sb（字节精度）
    size=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
    if [ -n "$size" ]; then
        echo "$size"
        return
    fi

    # 兼容 BSD du：使用 -sk 并转换为字节
    size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
    if [ -n "$size" ]; then
        echo "$((size * 1024))"
        return
    fi

    echo "0"
}

# 递归收集目录信息，保持目录树结构
collect_directory_tree() {
    local current_dir="$1"
    local base_path="$2"
    local current_depth="$3"
    local max_depth="$4"
    local min_size_bytes="$5"
    local normalized_dir=$(get_normalized_path "$current_dir")

    # 确保目录有效且未被处理过
    if [ -z "$normalized_dir" ] || has_directory_been_visited "$normalized_dir"; then
        return
    fi

    remember_directory "$normalized_dir"
    current_dir="$normalized_dir"

    # 获取当前目录大小
    local size_bytes=$(get_directory_size "$current_dir")
    local size_num=$((size_bytes + 0))  # 确保是数字

    # 如果目录大小小于最小阈值，则不继续统计子目录（除非是第一层）
    if [ "$size_num" -lt "$min_size_bytes" ] && [ "$current_depth" -gt 1 ]; then
        return
    fi

    # 输出当前目录信息
    echo "$current_depth|$current_dir|$size_bytes"

    # 如果未达到最大深度且目录大小满足要求，继续递归子目录
    if [ "$current_depth" -lt "$max_depth" ] && [ "$size_num" -ge "$min_size_bytes" ]; then
        # 创建临时文件来存储子目录信息
        local subdir_temp_file="/tmp/subdirs_$$_$RANDOM.tmp"

        # 查找直接子目录并收集大小信息
        find "$current_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r subdir; do
            if [ -d "$subdir" ]; then
                local subdir_normalized=$(get_normalized_path "$subdir")
                if [ -z "$subdir_normalized" ] || [ "$subdir_normalized" = "$current_dir" ]; then
                    continue
                fi
                if has_directory_been_visited "$subdir_normalized"; then
                    continue
                fi

                local sub_size=$(get_directory_size "$subdir_normalized")
                local sub_size_num=$((sub_size + 0))
                # 只有当子目录大小超过阈值时才处理，或者如果是第一层则强制处理
                if [ "$sub_size_num" -ge "$min_size_bytes" ] || [ "$current_depth" -eq 1 ]; then
                    echo "$sub_size|$subdir_normalized" >> "$subdir_temp_file"
                fi
            fi
        done

        # 如果存在子目录，按大小排序后递归处理
        if [ -f "$subdir_temp_file" ] && [ -s "$subdir_temp_file" ]; then
            # 按大小降序排序子目录
            sort -nr "$subdir_temp_file" | cut -d'|' -f2 | while IFS= read -r subdir; do
                if [ -n "$subdir" ] && [ -d "$subdir" ]; then
                    collect_directory_tree "$subdir" "$base_path" $((current_depth + 1)) "$max_depth" "$min_size_bytes"
                fi
            done
            rm -f "$subdir_temp_file"
        fi
    fi
}

# 生成CSV文件
generate_csv() {
    local target_dir="$1"
    local max_depth="$2"
    local min_size_mb="$3"
    local csv_prefix="$4"

    local base_path=$(get_normalized_path "$target_dir")
    local sanitized_path=""
    if [ "$base_path" = "/" ]; then
        sanitized_path="root"
    else
        sanitized_path=$(echo "$base_path" | sed 's:/:_:g' | sed 's:^_::')
        if [ -z "$sanitized_path" ]; then
            sanitized_path="root"
        fi
    fi
    local csv_file="${csv_prefix}_${sanitized_path}.csv"
    local min_size_bytes=$(($min_size_mb * 1024 * 1024))

    echo "开始统计目录: $base_path"
    echo "最大显示深度: $max_depth"
    echo "最小显示大小: $min_size_mb MB"
    echo "输出文件: $csv_file"
    echo ""

    # 创建临时文件
    local temp_file="/tmp/disk_stats_$$.tmp"
    local output_file="/tmp/disk_stats_output_$$.tmp"
    VISITED_PATHS_FILE="/tmp/disk_stats_visited_$$.tmp"

    # 初始化临时文件
    > "$temp_file"
    > "$output_file"
    > "$VISITED_PATHS_FILE"

    # 收集目录信息到临时文件
    echo "正在收集目录大小信息..."
    collect_directory_tree "$base_path" "$base_path" 1 "$max_depth" "$min_size_bytes" > "$temp_file"

    # 检查临时文件是否有内容
    if [ ! -s "$temp_file" ]; then
        echo "错误: 没有收集到任何目录信息"
        rm -f "$temp_file" "$output_file"
        if [ -n "$VISITED_PATHS_FILE" ]; then
            rm -f "$VISITED_PATHS_FILE"
            VISITED_PATHS_FILE=""
        fi
        exit 1
    fi

    echo "收集到的目录信息:"
    cat "$temp_file" | head -10  # 显示前10行用于调试

    # collect_directory_tree 已经按目录树顺序输出，直接使用结果
    echo "目录信息已按树结构排序。"
    cp "$temp_file" "$output_file"

    # 生成CSV文件
    echo "正在生成CSV文件..."
    echo "Level,Path,Size_Bytes,Size_KB,Size_Human" > "$csv_file"

    local prev_depth=1
    local indent=""

    while IFS='|' read depth path size_bytes; do
        if [ -n "$depth" ] && [ -n "$path" ] && [ -n "$size_bytes" ]; then
            # 计算KB大小
            local size_kb=$((size_bytes / 1024))
            local human_size=$(format_size "$size_bytes")

            # 生成缩进显示，便于查看层级关系
            local depth_num=$((depth + 0))
            local prev_depth_num=$((prev_depth + 0))

            if [ "$depth_num" -gt "$prev_depth_num" ]; then
                indent="${indent}  "
            elif [ "$depth_num" -lt "$prev_depth_num" ]; then
                local remove_count=$(( (prev_depth_num - depth_num) * 2 ))
                # 安全地移除缩进
                if [ "$remove_count" -gt 0 ]; then
                    while [ "$remove_count" -gt 0 ] && [ -n "$indent" ]; do
                        indent="${indent%?}"
                        remove_count=$((remove_count - 1))
                    done
                fi
            fi
            prev_depth="$depth_num"

            echo "$depth,\"$path\",$size_bytes,$size_kb,\"$human_size\"" >> "$csv_file"
            local display_name=$(basename "$path")
            if [ "$path" = "/" ]; then
                display_name="/"
            fi
            echo "深度 $depth: ${indent}${display_name} - $human_size"
        fi
    done < "$output_file"

    # 清理临时文件
    rm -f "$temp_file" "$output_file"
    if [ -n "$VISITED_PATHS_FILE" ]; then
        rm -f "$VISITED_PATHS_FILE"
        VISITED_PATHS_FILE=""
    fi

    echo ""
    echo "统计完成! 结果已保存到: $csv_file"
    echo ""
    echo "CSV文件说明:"
    echo "- Level: 目录层级 (1=根目录, 2=一级子目录, 以此类推)"
    echo "- Path: 绝对路径"
    echo "- Size_Bytes: 大小(字节) - 用于精确计算"
    echo "- Size_KB: 大小(KB)"
    echo "- Size_Human: 人类可读的大小"
    echo ""
    echo "在Excel中使用提示:"
    echo "1. 导入CSV后，可以使用'数据'->'分组'功能创建可折叠的层级视图"
    echo "2. 按'Level'列排序可以更好地查看层级结构"
    echo "3. 使用筛选功能可以快速找到大文件/目录"
}

# 主函数
main() {
    echo "================================================"
    echo "    Yocto Linux 磁盘空间统计工具"
    echo "================================================"
    echo ""

    parse_arguments "$@"

    generate_csv "$TARGET_DIR" "$MAX_DEPTH" "$MIN_SIZE_MB" "$CSV_PREFIX"
}

# 运行主函数
main "$@"
