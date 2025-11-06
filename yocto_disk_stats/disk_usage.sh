#!/bin/sh

# Disk space statistics script for Yocto Linux
# Supports analyzing the /bmhmi and /var/bmhmi directories

# Default configuration
DEFAULT_MAX_DEPTH=3
DEFAULT_MIN_SIZE_MB=1
CSV_FILE_PREFIX="disk_usage"
VISITED_PATHS_FILE=""

# Display usage information
show_usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -d, --dir DIR      Directory to analyze (/bmhmi or /var/bmhmi)"
    echo "  -m, --max-depth N  Maximum display depth (default: $DEFAULT_MAX_DEPTH)"
    echo "  -s, --min-size MB  Minimum size to display in MB (default: $DEFAULT_MIN_SIZE_MB)"
    echo "  -o, --output FILE  CSV output filename prefix (default: $CSV_FILE_PREFIX)"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -d /bmhmi -m 3 -s 1"
    echo "  $0 -d /var/bmhmi -m 7 -s 1"
}

# Parse command-line arguments
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
                echo "Error: Unknown argument $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [ -z "$TARGET_DIR" ]; then
        echo "Error: Target directory is required"
        show_usage
        exit 1
    fi

    if [ ! -d "$TARGET_DIR" ]; then
        echo "Error: Directory '$TARGET_DIR' does not exist"
        exit 1
    fi
}

# Get the normalized path for a directory
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

    # Remove trailing slashes, keeping / for the root directory
    dir=$(echo "$dir" | sed 's:/*$::')
    if [ -z "$dir" ]; then
        echo "/"
    else
        echo "$dir"
    fi
}

# Check whether a directory has already been processed (deduplication)
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

# Mark a directory as processed
remember_directory() {
    local dir="$1"

    if [ -n "$dir" ] && [ -n "$VISITED_PATHS_FILE" ]; then
        echo "$dir" >> "$VISITED_PATHS_FILE"
    fi
}

# Convert bytes to a human-readable format
format_size() {
    local bytes="$1"
    # Ensure the bytes value is numeric
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

# Get the size of a directory (including all subdirectories)
get_directory_size() {
    local dir="$1"
    local size=""

    # Try GNU du -sb for byte precision
    size=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
    if [ -n "$size" ]; then
        echo "$size"
        return
    fi

    # Fallback for BSD du: use -sk and convert to bytes
    size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
    if [ -n "$size" ]; then
        echo "$((size * 1024))"
        return
    fi

    echo "0"
}

# Recursively collect directory information while preserving the tree structure
collect_directory_tree() {
    local current_dir="$1"
    local base_path="$2"
    local current_depth="$3"
    local max_depth="$4"
    local min_size_bytes="$5"
    local normalized_dir=$(get_normalized_path "$current_dir")

    # Ensure the directory is valid and has not been processed
    if [ -z "$normalized_dir" ] || has_directory_been_visited "$normalized_dir"; then
        return
    fi

    remember_directory "$normalized_dir"
    current_dir="$normalized_dir"

    # Get the current directory size
    local size_bytes=$(get_directory_size "$current_dir")
    local size_num=$((size_bytes + 0))  # Ensure the value is treated as a number

    # Skip subdirectories if below the minimum threshold (unless this is the first level)
    if [ "$size_num" -lt "$min_size_bytes" ] && [ "$current_depth" -gt 1 ]; then
        return
    fi

    # Output the current directory information
    echo "$current_depth|$current_dir|$size_bytes"

    # Recurse into subdirectories if depth and size requirements are met
    if [ "$current_depth" -lt "$max_depth" ] && [ "$size_num" -ge "$min_size_bytes" ]; then
        # Create a temporary file to store subdirectory information
        local subdir_temp_file="/tmp/subdirs_$$_$RANDOM.tmp"

        # Find direct subdirectories and collect their size information
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
                # Only process subdirectories above the threshold, or always for the first level
                if [ "$sub_size_num" -ge "$min_size_bytes" ] || [ "$current_depth" -eq 1 ]; then
                    echo "$sub_size|$subdir_normalized" >> "$subdir_temp_file"
                fi
            fi
        done

        # If subdirectories exist, sort them by size and recurse
        if [ -f "$subdir_temp_file" ] && [ -s "$subdir_temp_file" ]; then
            # Sort subdirectories by size in descending order
            sort -nr "$subdir_temp_file" | cut -d'|' -f2 | while IFS= read -r subdir; do
                if [ -n "$subdir" ] && [ -d "$subdir" ]; then
                    collect_directory_tree "$subdir" "$base_path" $((current_depth + 1)) "$max_depth" "$min_size_bytes"
                fi
            done
            rm -f "$subdir_temp_file"
        fi
    fi
}

# Generate a CSV file
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

    echo "Starting statistics for: $base_path"
    echo "Maximum display depth: $max_depth"
    echo "Minimum display size: $min_size_mb MB"
    echo "Output file: $csv_file"
    echo ""

    # Create temporary files
    local temp_file="/tmp/disk_stats_$$.tmp"
    local output_file="/tmp/disk_stats_output_$$.tmp"
    VISITED_PATHS_FILE="/tmp/disk_stats_visited_$$.tmp"

    # Initialize temporary files
    > "$temp_file"
    > "$output_file"
    > "$VISITED_PATHS_FILE"

    # Collect directory information into the temporary file
    echo "Collecting directory size information..."
    collect_directory_tree "$base_path" "$base_path" 1 "$max_depth" "$min_size_bytes" > "$temp_file"

    # Check whether the temporary file has data
    if [ ! -s "$temp_file" ]; then
        echo "Error: No directory information collected"
        rm -f "$temp_file" "$output_file"
        if [ -n "$VISITED_PATHS_FILE" ]; then
            rm -f "$VISITED_PATHS_FILE"
            VISITED_PATHS_FILE=""
        fi
        exit 1
    fi

    echo "Collected directory information:"
    cat "$temp_file" | head -10  # Show the first 10 lines for debugging

    # collect_directory_tree already outputs in tree order, so reuse it directly
    echo "Directory information is already ordered as a tree."
    cp "$temp_file" "$output_file"

    # Generate the CSV file
    echo "Generating CSV file..."
    echo "Level,Path,Size_Bytes,Size_KB,Size_Human" > "$csv_file"

    local prev_depth=1
    local indent=""

    while IFS='|' read depth path size_bytes; do
        if [ -n "$depth" ] && [ -n "$path" ] && [ -n "$size_bytes" ]; then
            # Calculate sizes in KB
            local size_kb=$((size_bytes / 1024))
            local human_size=$(format_size "$size_bytes")

            # Generate indentation to highlight the hierarchy
            local depth_num=$((depth + 0))
            local prev_depth_num=$((prev_depth + 0))

            if [ "$depth_num" -gt "$prev_depth_num" ]; then
                indent="${indent}  "
            elif [ "$depth_num" -lt "$prev_depth_num" ]; then
                local remove_count=$(( (prev_depth_num - depth_num) * 2 ))
                # Safely remove indentation
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
            echo "Depth $depth: ${indent}${display_name} - $human_size"
        fi
    done < "$output_file"

    # Clean up temporary files
    rm -f "$temp_file" "$output_file"
    if [ -n "$VISITED_PATHS_FILE" ]; then
        rm -f "$VISITED_PATHS_FILE"
        VISITED_PATHS_FILE=""
    fi

    echo ""
    echo "Statistics complete! Results saved to: $csv_file"
    echo ""
    echo "CSV file details:"
    echo "- Level: Directory depth (1=root, 2=first-level subdirectory, etc.)"
    echo "- Path: Absolute path"
    echo "- Size_Bytes: Size in bytes (for precise calculations)"
    echo "- Size_KB: Size in KB"
    echo "- Size_Human: Human-readable size"
    echo ""
    echo "Tips for use in Excel:"
    echo "1. After importing the CSV, use Data -> Group to build collapsible hierarchies."
    echo "2. Sort by the Level column to inspect the structure more easily."
    echo "3. Use filters to quickly locate large files or directories."
}

# Main function
main() {
    echo "================================================"
    echo "    Yocto Linux Disk Usage Tool"
    echo "================================================"
    echo ""

    parse_arguments "$@"

    generate_csv "$TARGET_DIR" "$MAX_DEPTH" "$MIN_SIZE_MB" "$CSV_PREFIX"
}

# Execute the main function
main "$@"
