#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title background_ocrPDF
# @raycast.mode silent
# @raycast.icon 🤖
# @raycast.argument1 { "type": "text", "placeholder": "PDF URL or Path" }
# Auto-detects processing mode based on payload size
# @raycast.argument3 { "type": "dropdown", "placeholder": "Primary Tag (optional)", "optional": true, "data": [{"title": "Clip", "value": "clip"}, {"title": "Scan", "value": "scan"}, {"title": "Paper", "value": "paper"}] }

set -euo pipefail

# Source the Slack module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLACK_MODULE="$SCRIPT_DIR/background_slack.sh"

if [ -f "$SLACK_MODULE" ]; then
    source "$SLACK_MODULE"
fi

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LC_CTYPE=en_US.UTF-8

# Global variables for argument parsing
PDF_URL=""
PRIMARY_TAG="clip"  # Default to 'clip' for backward compatibility
IS_URL=true  # Flag to distinguish URL from local file

# Log buffer for delayed writing (only save logs on failure)
LOG_BUFFER=""

# PNG processing global variables
CONVERTED_PNG_DIR=""

# Constants (will be set after environment loading)


# Function to show usage information
show_usage() {
    cat << 'EOF'
background_ocrPDF.sh - Hybrid API Version

DESCRIPTION:
    PDF OCR processor with automatic mode detection and API switching.
    Automatically detects input type (file/directory/URL) and selects optimal API based on payload size.
    Uses FREE API (≤19MB) or PAID API (>19MB) automatically.

USAGE:
    ./background_ocrPDF.sh <INPUT> [CATEGORY]
    ./background_ocrPDF.sh --help | -h

ARGUMENTS:
    INPUT               URL, file path, or directory (automatically detected)
                   - URL: http://... or https://... → Single processing
                   - File: /path/to/file.pdf → Single processing  
                   - Directory: /path/to/dir/ → Batch processing
    CATEGORY           Optional: clip, scan, paper (default: clip)

EXAMPLES:
    # Process single PDF from URL (auto: single mode)
    ./background_ocrPDF.sh "https://example.com/paper.pdf" paper
    
    # Process local PDF file (auto: single mode)
    ./background_ocrPDF.sh "/path/to/document.pdf" scan
    
    # Batch process directory (auto: batch mode)  
    ./background_ocrPDF.sh "/scan/directory" scan

AUTO PROCESSING:
    - Input Detection: URL/File → Single | Directory → Batch
    - API Selection: Payload ≤19MB → FREE/REALTIME | >19MB → PAID/BATCH
    - Safe Fallback: Skip if large payload but no paid API key
EOF
}

# Function to parse command line arguments
parse_arguments() {
    # Check for help option first
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_usage
    exit 0
    fi
    
    # Simplified argument validation (1 or 2 arguments)
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Error: Expected 1 or 2 arguments: <INPUT> [CATEGORY]" >&2
    echo "Usage: $0 <URL|FILE|DIR> [clip|scan|paper]" >&2
    return 1
    fi
    
    INPUT="$1"
    PRIMARY_TAG="${2:-clip}"  # Default to 'clip' if not provided
    
    # 🔥 自動判定ロジック: INPUT内容で処理モード決定
    if [ -d "$INPUT" ]; then
    # ディレクトリ → バッチ処理
    BATCH_MODE=true
    SCAN_DIR="$INPUT"
    log_with_timestamp "🗂️ Directory detected - Batch mode: $INPUT (category: $PRIMARY_TAG)"
    elif echo "$INPUT" | grep -q '^https\?://'; then
    # URL → シングル処理
    BATCH_MODE=false
    PDF_URL="$INPUT"
    IS_URL=true
    log_with_timestamp "🌐 URL detected - Single mode: $INPUT"
    elif [ -f "$INPUT" ]; then
    # ファイル → シングル処理  
    BATCH_MODE=false
    PDF_URL="$INPUT"
    IS_URL=false
    log_with_timestamp "📄 File detected - Single mode: $INPUT"
    else
    echo "Error: Invalid input - not a valid URL, existing file, or directory: $INPUT" >&2
    return 1
    fi
    
    # 自動判定完了 - 引数解析終了
    log_with_timestamp "Input parsing completed: $INPUT (category: $PRIMARY_TAG)"
    return 0
}

# Configuration constants (common to both modes)
# Gemini model will be set from environment variables after loading .env
# PDF_DPI will be calculated dynamically based on page count
readonly TEMPERATURE="0.1"
readonly GEMINI_BASE_URL="https://generativelanguage.googleapis.com/v1beta"

# Realtime-specific constants
readonly REALTIME_API_TIMEOUT="1800"
readonly REALTIME_API_MAX_TIME="1800"

# Batch-specific constants  
readonly BATCH_API_TIMEOUT="28800"     # 8時間
readonly BATCH_API_MAX_TIME="28800"    # 8時間
readonly BATCH_POLL_INTERVAL="600"
readonly BATCH_MAX_WAIT="28800"        # 8時間

# Common processing constants
readonly DEFAULT_CONNECT_TIMEOUT="30"
readonly DEFAULT_MAX_TIME="300"
readonly MAX_TITLE_LENGTH="100"
readonly TITLE_EXTRACT_LINES="10"
readonly ERROR_MESSAGE_LINES="5"

# Directory setup will be done after argument parsing
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
VAULT_DIR="$(dirname "$SCRIPT_DIR")"
ATTACHMENTS_DIR="attachments"
TIMESTAMP=$(date +%Y%m%d%H%M%S%6N)_$$_$RANDOM

# These will be set after argument parsing and environment loading
BATCH_ID="batch_${TIMESTAMP}_$$"
STATE_FILE=""
LOG_FILE=""
THREAD_TS_FILE=""


# Calculate processing duration from start time
calculate_processing_duration() {
    local start_time="$1"
    local processing_duration="Unknown"
    
    if [ -n "$start_time" ]; then
    local end_time=$(date +%s)
    local start_time_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S JST" "$start_time" +%s 2>/dev/null || echo "0")
    if [ "$start_time_epoch" != "0" ]; then
        local duration_seconds=$((end_time - start_time_epoch))
        local hours=$((duration_seconds / 3600))
        local minutes=$(((duration_seconds % 3600) / 60))
        local seconds=$((duration_seconds % 60))
        processing_duration="${hours}時間${minutes}分${seconds}秒"
    fi
    fi
    
    echo "$processing_duration"
}

# Escape string for JSON
escape_json() {
    local input="$1"
    echo "$input" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//'
}



# Post-process Gemini output to ensure CSL-compatible YAML frontmatter exists
# Helper functions for YAML frontmatter processing

# Check if file has YAML frontmatter
check_yaml_exists() {
    local output_file="$1"
    head -1 "$output_file" | grep -q "^---$"
}

# Helper function to validate if title is meaningful
is_meaningful_title() {
    local title="$1"
    [ -n "$title" ] && \
    ! [[ "$title" =~ (ページ|Page|章|Chapter) ]] && \
    [ ${#title} -ge 5 ]
}

# Extract meaningful title from content with improved validation
extract_title_from_content() {
    local content="$1"
    local auto_title=""
    
    # Pattern 1: Try to extract from YAML title field (improved validation)
    local yaml_title=$(echo "$content" | grep -i "^title:" 2>/dev/null | head -1 | sed 's/^title: *//' | sed 's/[*_#]*//g' || true)
    if is_meaningful_title "$yaml_title"; then
        auto_title="$yaml_title"
    fi
    
    # Pattern 2: Try to extract a meaningful title from markdown headers
    if [ -z "$auto_title" ]; then
        local first_lines=$(echo "$content" | head -"${TITLE_EXTRACT_LINES:-10}" 2>/dev/null || true)
        local markdown_title=$(echo "$first_lines" | sed -n 's/^# *\(.*\)/\1/p' | head -1 2>/dev/null || true)
        if is_meaningful_title "$markdown_title"; then
            auto_title="$markdown_title"
        fi
    fi
    
    # Pattern 3: Look for meaningful content in first few lines
    if [ -z "$auto_title" ]; then
        local candidate=$(echo "$content" | head -5 2>/dev/null | grep -v "^$" | head -1 | sed 's/^[*#-] *//' | sed 's/^###* *//' | cut -c1-"${MAX_TITLE_LENGTH:-100}" 2>/dev/null || true)
        if is_meaningful_title "$candidate"; then
            auto_title="$candidate"
        fi
    fi
    
    # Pattern 4: Fallback to timestamp format for better file management
    if [ -z "$auto_title" ]; then
        auto_title="$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Clean up title: remove markdown formatting and replace spaces with underscores
    auto_title=$(echo "$auto_title" | sed 's/^[#*_ -]*//' | sed 's/[*_#]*$//' | sed 's/[ 　]/_/g')
    echo "$auto_title"
}

# Generate YAML frontmatter content
generate_yaml_frontmatter() {
    local auto_title="$1"
    local source_value="$2"
    local current_time=$(TZ='Asia/Tokyo' date '+%Y-%m-%dT%H:%M:%S+09:00')
    
    cat << EOF
---
# CSL JSON Standard Fields
id: 
type: article-journal
title: $auto_title
author:
container-title: 
volume: 
issue: 
page: 
issued:
  date-parts:
    - []
DOI: 
URL: 
ISBN: 
PMID: 
abstract: 
keywords:
language: 
editor: 
publisher: 
publisher-place: 

# Obsidian Specific Fields
source: $source_value
created: $current_time
tags:
  - ${PRIMARY_TAG}
  - pdf
  - academic
---
EOF
}

ensure_yaml_frontmatter() {
    local output_file="$1"
    local source_value="$2"
    
    # Check if file starts with YAML frontmatter using helper function
    if ! check_yaml_exists "$output_file"; then
    log_with_timestamp "WARNING: Gemini output lacks YAML frontmatter, adding CSL-compatible post-processing"
    
    # Read the original content
    local original_content=$(cat "$output_file")
    
    # Extract title using helper function
    local auto_title=$(extract_title_from_content "$original_content")
    
    # Generate YAML frontmatter using helper function
    local yaml_frontmatter=$(generate_yaml_frontmatter "$auto_title" "$source_value")
    
    # Create new content with YAML frontmatter
    cat > "$output_file" << EOF
$yaml_frontmatter

$original_content
EOF
    
    log_with_timestamp "Added YAML frontmatter with auto-extracted title: $auto_title"
    echo "$auto_title"
    else
    log_with_timestamp "YAML frontmatter detected in Gemini output"
    fix_yaml_array_fields "$output_file"
    # Extract title from existing YAML
    local existing_title=$(extract_title_from_content "$(cat "$output_file")")
    echo "$existing_title"
    fi
}

fix_yaml_array_fields() {
    local output_file="$1"
    local temp_file=$(mktemp)
    local in_frontmatter=false
    local author_fixed=false
    local skip_author_items=false
    
    while IFS= read -r line; do
    if [ "$line" = "---" ]; then
        if [ "$in_frontmatter" = false ]; then
            in_frontmatter=true
            echo "$line" >> "$temp_file"
        else
            in_frontmatter=false
            skip_author_items=false
            echo "$line" >> "$temp_file"
        fi
    elif [ "$in_frontmatter" = true ]; then
        if [ "$skip_author_items" = true ]; then
            if echo "$line" | grep -q "^  - "; then
                continue
            else
                skip_author_items=false
                echo "$line" >> "$temp_file"
            fi
        elif echo "$line" | grep -q "^author:$"; then
            if IFS= read -r next_line; then
                if echo "$next_line" | grep -q "^  - "; then
                    local author_value=$(echo "$next_line" | sed 's/^  - //')
                    echo "author: $author_value" >> "$temp_file"
                    skip_author_items=true
                    author_fixed=true
                else
                    echo "$line" >> "$temp_file"
                    echo "$next_line" >> "$temp_file"
                fi
            else
                echo "$line" >> "$temp_file"
            fi
        else
            echo "$line" >> "$temp_file"
        fi
    else
        echo "$line" >> "$temp_file"
    fi
    done < "$output_file"
    
    if [ "$author_fixed" = true ]; then
    mv "$temp_file" "$output_file"
    else
    rm -f "$temp_file"
    fi
}

generate_safe_filename() {
    local title="${1:-}"
    local safe_title="$title"
    
    # Remove filesystem-unsafe characters
    safe_title="${safe_title//[<>:\"\/\\|?*]/}"
    
    # Replace all types of spaces with underscores (ASCII space, full-width space, tab, etc.)
    safe_title="${safe_title//[ 　	]/_}"
    
    # Remove consecutive underscores
    while [[ "$safe_title" =~ "__" ]]; do
        safe_title="${safe_title//__/_}"
    done
    
    # Remove leading/trailing underscores
    safe_title="${safe_title#_}"
    safe_title="${safe_title%_}"
    
    # If title becomes empty or too short, use timestamp fallback
    if [ -z "$safe_title" ] || [ ${#safe_title} -lt 3 ]; then
        safe_title="$(date +%Y%m%d_%H%M%S)"
    fi
    
    echo "$safe_title"
}


log_with_timestamp() {
    local message="$1"
    local timestamp=$(TZ='Asia/Tokyo' date '+%Y-%m-%d %H:%M:%S JST')
    local log_entry="[$timestamp] $message"
    
    # Accumulate log entries in memory buffer
    LOG_BUFFER="${LOG_BUFFER}${log_entry}\n"
    
    # Always output to stderr immediately for real-time monitoring
    echo "$log_entry" >&2
}

# Save failed logs to file (only called on failure)
save_failed_logs() {
    if [ -n "$LOG_BUFFER" ]; then
        local failed_log="$SCRIPT_DIR/failed_logs/failed_$(date +%Y%m%d_%H%M%S)_$$.log"
        mkdir -p "$(dirname "$failed_log")"
        echo -e "$LOG_BUFFER" > "$failed_log"
        log_with_timestamp "Failed logs saved to: $failed_log"
    fi
}

# Create state file
create_state_file() {
    local status="$1"
    local additional_info="$2"
    
    mkdir -p "$STATE_DIR"
    local timestamp=$(TZ='Asia/Tokyo' date '+%Y-%m-%d %H:%M:%S JST')
    
    cat > "$STATE_FILE" << EOF
batch_id=$BATCH_ID
status=$status
timestamp=$timestamp
pdf_url=${PDF_URL:-}
start_time=${START_TIME:-}
${additional_info}
EOF
    
    log_with_timestamp "State updated: $status"
}

# Update state
update_state() {
    local status="$1"
    local additional_info="$2"
    
    if [ -f "$STATE_FILE" ]; then
    sed -i '' "s/^status=.*/status=$status/" "$STATE_FILE"
    sed -i '' "s/^timestamp=.*/timestamp=$(TZ='Asia/Tokyo' date '+%Y-%m-%d %H:%M:%S JST')/" "$STATE_FILE"
    
    if [ -n "$additional_info" ]; then
        echo "$additional_info" >> "$STATE_FILE"
    fi
    else
    create_state_file "$status" "$additional_info"
    fi
    
    log_with_timestamp "State updated: $status"
}


# Load environment variables
load_environment() {
    local env_file="$VAULT_DIR/.env"
    
    if [ ! -f "$env_file" ]; then
    log_with_timestamp "ERROR: Environment file not found: $env_file"
    return 1
    fi
    
    log_with_timestamp "Loading environment from: $env_file"
    
    # Use source instead of complex while loop with heredoc
    if source "$env_file" 2>/dev/null; then
    log_with_timestamp "Environment loaded successfully using source"
    
    # Convert relative paths to absolute after loading
    if [ -n "${PDF_TEMP_BASE_DIR:-}" ]; then
        if [[ "$PDF_TEMP_BASE_DIR" == ./* ]] || [[ "$PDF_TEMP_BASE_DIR" == ../* ]]; then
            PDF_TEMP_BASE_DIR="$(cd "$SCRIPT_DIR" && cd "$PDF_TEMP_BASE_DIR" 2>/dev/null && pwd)" || PDF_TEMP_BASE_DIR="$SCRIPT_DIR/$PDF_TEMP_BASE_DIR"
        fi
    fi
    
    # Log loaded variables
    
    # Set API size threshold from environment (required)
    if [ -z "${API_SIZE_THRESHOLD:-}" ]; then
        handle_validation_error "API_SIZE_THRESHOLD" "API_SIZE_THRESHOLD must be set in .env"
    fi
    readonly API_SIZE_THRESHOLD="${API_SIZE_THRESHOLD}"
    
    log_with_timestamp "Environment loading completed"
    return 0
    else
    log_with_timestamp "ERROR: Failed to source environment file"
    return 1
    fi
}

# Validate configuration (supports multiple AI providers)
validate_config() {
    log_with_timestamp "Starting configuration validation..."
    
    # Set AI provider (default to gemini for backward compatibility)
    AI_PROVIDER="${AI_PROVIDER:-gemini}"
    readonly AI_PROVIDER
    
    # Handle backward compatibility for API keys
    if [ -n "${GEMINI_API_KEY:-}" ] && [ -z "${AI_API_KEY:-}" ]; then
    AI_API_KEY="$GEMINI_API_KEY"
    fi
    
    # Validate API keys (either FREE or PAID must be available)
    local free_key=$(grep "AI_API_KEY_FREE=" "$VAULT_DIR/.env" 2>/dev/null | sed 's/^AI_API_KEY_FREE=//' | sed 's/ # .*//')
    local paid_key=$(grep "AI_API_KEY_PAID=" "$VAULT_DIR/.env" 2>/dev/null | sed 's/^AI_API_KEY_PAID=//' | sed 's/ # .*//')
    
    if [ -z "$free_key" ] && [ -z "$paid_key" ]; then
    log_with_timestamp "ERROR: Neither AI_API_KEY_FREE nor AI_API_KEY_PAID is set"
    handle_validation_error "API configuration" "At least one of AI_API_KEY_FREE or AI_API_KEY_PAID must be set. Please check your .env file."
    fi
    
    
    # Provider-specific API key validation using helper functions  
    case "$AI_PROVIDER" in
    "gemini")
        # Use available API key for validation (prefer paid, fallback to free)
        local validation_key="$paid_key"
        [ -z "$validation_key" ] && validation_key="$free_key"
        validate_gemini_config "$validation_key" "$AI_MODEL"
        ;;
    "openai")
        validate_openai_config "$validation_key" "$AI_MODEL"
        ;;
    *)
        log_with_timestamp "ERROR: Unsupported AI provider: $AI_PROVIDER"
        handle_validation_error "AI provider" "Unsupported AI provider: $AI_PROVIDER. Supported providers: gemini, openai"
        ;;
    esac
    
    
    # Handle backward compatibility for model names
    if [ -n "${GEMINI_MODEL:-}" ] && [ -z "${AI_MODEL:-}" ]; then
    AI_MODEL="$GEMINI_MODEL"
    fi
    
    # Set and validate AI_MODEL using helper functions
    AI_MODEL="${AI_MODEL:-gemini-2.5-pro}"
    readonly AI_MODEL
    
    # Re-validate with model information
    case "$AI_PROVIDER" in
    "gemini")
        validate_gemini_config "$validation_key" "$AI_MODEL"
        ;;
    "openai")
        validate_openai_config "$validation_key" "$AI_MODEL"
        ;;
    esac
    
    
    log_with_timestamp "Configuration validation completed successfully"
}

# AI Provider validation helper functions

# Validate Gemini configuration
validate_gemini_config() {
    local api_key="$1"
    local model="${2:-}"
    
    # Validate API key format
    if ! echo "$api_key" | grep -q '^AIzaSy' || [ ${#api_key} -lt 39 ]; then
    log_with_timestamp "ERROR: Gemini API key format appears invalid"
    handle_validation_error "Gemini API key" "API key format appears invalid. Please check your API key."
    fi
    
    # Validate model if provided
    if [ -n "$model" ]; then
    case "$model" in
        "gemini-2.5-pro"|"gemini-1.5-pro"|"gemini-1.5-flash")
            ;;
        *)
            log_with_timestamp "ERROR: Invalid Gemini model: $model"
            handle_validation_error "Gemini model" "Invalid model: $model. Supported models: gemini-2.5-pro, gemini-1.5-pro, gemini-1.5-flash"
            ;;
    esac
    fi
}


# Validate OpenAI configuration
validate_openai_config() {
    local api_key="$1"
    local model="${2:-}"
    
    # Validate API key format
    if ! echo "$api_key" | grep -q '^sk-' || [ ${#api_key} -lt 50 ]; then
    log_with_timestamp "ERROR: OpenAI API key format appears invalid"
    handle_validation_error "OpenAI API key" "API key format appears invalid. Please check your API key."
    fi
    
    # Validate model if provided
    if [ -n "$model" ]; then
    case "$model" in
        "gpt-4o"|"gpt-4-turbo"|"gpt-3.5-turbo")
            ;;
        *)
            log_with_timestamp "ERROR: Invalid OpenAI model: $model"
            handle_validation_error "OpenAI model" "Invalid model: $model. Supported models: gpt-4o, gpt-4-turbo, gpt-3.5-turbo"
            ;;
    esac
    fi
}

# Utility functions for file operations

# Get file size safely
get_file_size() {
    local file="$1"
    stat -f%z "$file" 2>/dev/null || echo "0"
}


# RECITATION error detection function
is_recitation_error() {
    local response_file="$1"
    
    if [[ -f "$response_file" ]]; then
        if grep -q '"finishReason": "RECITATION"' "$response_file" 2>/dev/null; then
            return 0  # RECITATIONエラー
        fi
    fi
    return 1  # 非RECITATIONエラー
}

# RECITATION error handler function  
handle_recitation_error() {
    local response_file="$1"
    local batch_id="$2"
    
    log_with_timestamp "⚠️ RECITATION error detected - attempting PAID API fallback"
    
    # 環境変数を設定（PAID API強制使用）
    export FORCE_PAID_API=true
    
    log_with_timestamp "🔄 Retrying with PAID API (File API mode)"
    
    return 0
}

# 503 Error Handling Functions
is_503_error() {
    local response_file="$1"
    
    if [[ -f "$response_file" ]]; then
        if grep -q '"code": 503' "$response_file" 2>/dev/null; then
            return 0  # 503エラー
        fi
    fi
    return 1  # 非503エラー
}

handle_503_error_retry() {
    local retry_count="${GEMINI_RETRY_COUNT:-0}"
    local max_retries=3
    
    if [ "$retry_count" -lt "$max_retries" ]; then
        local new_retry_count=$((retry_count + 1))
        local wait_time=$((new_retry_count * 10))  # 10秒, 20秒, 30秒
        
        log_with_timestamp "🔄 503エラー: リトライ ${new_retry_count}/${max_retries} (${wait_time}秒待機)"
        sleep $wait_time
        
        export GEMINI_RETRY_COUNT=$new_retry_count
        return 2  # 特別なリトライコード
    else
        log_with_timestamp "❌ 503エラー: リトライ上限到達"
        return 1
    fi
}

# Helper functions for PDF download

# Download PDF from URL with retry mechanism
download_pdf_from_url() {
    local pdf_url="$1"
    local pdf_file="$2"
    
    log_with_timestamp "Starting PDF download from: $pdf_url"
    update_state "downloading_pdf" "pdf_url=$pdf_url"
    
    # Use robust curl with retry for PDF downloads with comprehensive browser headers
    local temp_error_file=$(mktemp)
    local curl_exit_code=0
    
    # First attempt: Try with comprehensive browser headers (without Accept-Encoding to avoid PDF corruption)
    curl -L --http1.1 --silent --show-error \
    -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7" \
    -H "Accept-Language: ja,en-US;q=0.9,en;q=0.8" \
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36" \
    -H "Sec-Fetch-Dest: document" \
    -H "Sec-Fetch-Mode: navigate" \
    -H "Sec-Fetch-Site: same-origin" \
    -H "Sec-Fetch-User: ?1" \
    -H "Cache-Control: max-age=0" \
    -H "Upgrade-Insecure-Requests: 1" \
    --connect-timeout "$DEFAULT_CONNECT_TIMEOUT" --max-time "$DEFAULT_MAX_TIME" \
    -o "$pdf_file" "$pdf_url" 2>"$temp_error_file" || curl_exit_code=$?
    
    # If first attempt failed, try with simpler headers
    if [ $curl_exit_code -ne 0 ] || [ ! -s "$pdf_file" ]; then
    log_with_timestamp "First download attempt failed, trying with simpler headers"
    rm -f "$pdf_file" 2>/dev/null || true
    curl_exit_code=0
    curl -L --http1.1 --silent --show-error \
        -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36" \
        -H "Accept: application/pdf,*/*" \
        --connect-timeout "$DEFAULT_CONNECT_TIMEOUT" --max-time "$DEFAULT_MAX_TIME" \
        -o "$pdf_file" "$pdf_url" 2>"$temp_error_file" || curl_exit_code=$?
    fi
    
    # Validate download result
    if ! validate_pdf_file "$pdf_file" "$curl_exit_code" "$temp_error_file" "$pdf_url"; then
    rm -f "$temp_error_file"
    return 1
    fi
    
    rm -f "$temp_error_file" 2>/dev/null || true
    log_with_timestamp "PDF download completed successfully"
    return 0
}

# Handle local PDF file operations
handle_local_pdf_file() {
    local pdf_url="$1"
    local pdf_file="$2"
    
    log_with_timestamp "Moving local PDF file: $pdf_url"
    update_state "moving_pdf" "pdf_path=$pdf_url"
    
    # Check if called from scanPDF.sh by looking at the source file path
    if echo "$pdf_url" | grep -q "/scan/unprocessed/"; then
    # For scanPDF.sh, move the file instead of copy to avoid reprocessing
    if ! mv "$pdf_url" "$pdf_file" 2>/dev/null; then
        handle_file_error "move" "$pdf_url" "PDF file move failed"
    fi
    log_with_timestamp "PDF move completed successfully"
    else
    # For clipPDF.sh, still copy (don't move user's original file)
    if ! cp "$pdf_url" "$pdf_file" 2>/dev/null; then
        handle_file_error "copy" "$pdf_url" "PDF file copy failed"
    fi
    log_with_timestamp "PDF copy completed successfully"
    fi
    
    return 0
}

# Validate PDF file after download/copy
validate_pdf_file() {
    local pdf_file="$1"
    local curl_exit_code="$2"
    local temp_error_file="$3"
    local pdf_url="$4"
    
    # Check if download was successful
    if [ $curl_exit_code -ne 0 ] || [ ! -s "$pdf_file" ]; then
    local error_msg="$(cat "$temp_error_file" 2>/dev/null | head -3 | tr '\n' ' ')"
    local file_size=$(get_file_size "$pdf_file")
    
    log_with_timestamp "PDF download failed: exit code $curl_exit_code, file size: $file_size bytes, error: $error_msg"
    handle_file_error "download" "$pdf_url" "Server access denied or download failed"
    return 1
    fi
    
    return 0
}

# Download PDF
# Function: Extract page count from PDF using pdfinfo
get_page_count() {
    local pdf_file="$1"
    
    if [ -z "$pdf_file" ] || [ ! -f "$pdf_file" ]; then
    echo "0"
    return 1
    fi
    
    if command -v pdfinfo >/dev/null 2>&1; then
    local page_count=$(pdfinfo "$pdf_file" 2>/dev/null | grep "Pages:" | awk '{print $2}')
    if [[ "$page_count" =~ ^[0-9]+$ ]]; then
        echo "$page_count"
        return 0
    fi
    fi
    
    echo "0"
    return 1
}

# Function: Calculate optimal DPI based on page count
calculate_optimal_dpi() {
    local page_count="$1"
    
    if [ -z "$page_count" ] || ! [[ "$page_count" =~ ^[0-9]+$ ]]; then
    echo "300"
    return 1
    fi
    
    if [ "$page_count" -gt 150 ]; then
    echo "200"  # Extra large files: maximum compression
    elif [ "$page_count" -gt 50 ]; then
    echo "225"  # Large files: high compression
    elif [ "$page_count" -gt 20 ]; then
    echo "250"  # Medium files: moderate compression
    else
    echo "300"  # Small files: maintain quality
    fi
    
    return 0
}

# Function: Optimize PNG files using optipng
optimize_png_files() {
    local png_pattern="$1"
    local optimization_level="${2:-2}"
    
    # Skip PNG optimization if requested (for testing)
    if [ "${SKIP_PNG_OPTIMIZATION:-}" = "true" ]; then
    log_with_timestamp "🔧 PNG optimization skipped"
    return 0
    fi
    
    
    if [ -z "$png_pattern" ]; then
    log_with_timestamp "⚠️ PNG pattern not specified, skipping optimization"
    return 1
    fi
    
    if ! command -v optipng >/dev/null 2>&1; then
    log_with_timestamp "⚠️ optipng not available, skipping PNG optimization"
    return 1
    fi
    
    local png_files=($(find . -name "$png_pattern" -type f 2>/dev/null | sort -V))
    
    if [ ${#png_files[@]} -eq 0 ]; then
    log_with_timestamp "⚠️ No PNG files found matching pattern '$png_pattern'"
    return 1
    fi
    
    log_with_timestamp "🔧 Starting PNG optimization for ${#png_files[@]} files..."
    
    local optimized_count=0
    local failed_count=0
    
    for png_file in "${png_files[@]}"; do
    if [ -f "$png_file" ]; then
        log_with_timestamp "🔧 Optimizing: $(basename "$png_file")"
        # Use timeout to prevent hanging (600 seconds per file)
        # Use maximum optimization level 7 with metadata stripping for 50% size reduction
        if timeout 600s optipng -o7 -strip all "$png_file" >/dev/null 2>&1; then
            ((optimized_count++))
            log_with_timestamp "✅ Optimized: $(basename "$png_file")"
        else
            ((failed_count++))
            log_with_timestamp "⚠️ Failed/Timeout: $(basename "$png_file")"
        fi
    fi
    done
    
    log_with_timestamp "✅ PNG optimization completed: $optimized_count optimized, $failed_count failed"
    
    return 0
}

# Function: Determine API strategy based on PNG Base64 size
determine_api_strategy_v2() {
    local pdf_file="$1"
    
    # Validate input
    if [[ ! -f "$pdf_file" ]]; then
        log_with_timestamp "⚠️ PDF file not found: $pdf_file"
        echo "PAID_API"
        return 1
    fi
    
    # Get page count and calculate optimal DPI
    local page_count=$(get_page_count "$pdf_file")
    local optimal_dpi=$(calculate_optimal_dpi "$page_count")
    
    log_with_timestamp "📊 Analyzing PDF: ${page_count} pages, DPI: ${optimal_dpi}"
    
    # Create temporary directory for PNG conversion
    local temp_png_dir=$(mktemp -d)
    cd "$temp_png_dir"
    
    # Convert PDF to PNG for measurement
    log_with_timestamp "🔄 Converting PDF to PNG for size measurement..."
    if ! pdftoppm -png -r "$optimal_dpi" "$pdf_file" page 2>/dev/null; then
        log_with_timestamp "⚠️ PNG conversion failed, falling back to PAID API"
        rm -rf "$temp_png_dir"
        echo "PAID_API"
        return 1
    fi
    
    # Optimize PNG files to reduce size (using maximum optimization for 50% reduction)
    optimize_png_files "page-*.png" 7
    
    # Calculate total Base64 size
    local total_base64_size=0
    local png_count=0
    
    for png_file in page-*.png; do
        if [[ -f "$png_file" ]]; then
            local png_base64=$(base64 -i "$png_file" 2>/dev/null || base64 "$png_file" 2>/dev/null)
            local png_size=${#png_base64}
            total_base64_size=$((total_base64_size + png_size))
            ((png_count++))
        fi
    done
    
    local total_mb=$(echo "scale=2; $total_base64_size / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
    log_with_timestamp "📏 Measured: ${png_count} pages, Base64 total: ${total_mb}MB"
    
    # Calculate threshold in MB for logging
    local threshold_mb=$(echo "scale=2; $API_SIZE_THRESHOLD / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
    
    # Determine API based on threshold
    if [[ $total_base64_size -le $API_SIZE_THRESHOLD ]]; then
        log_with_timestamp "💰 Selected FREE API (${total_mb}MB ≤ ${threshold_mb}MB)"
        CONVERTED_PNG_DIR="$temp_png_dir"
        export PNG_DPI="$optimal_dpi"
        return 0
    else
        log_with_timestamp "🏆 Selected PAID API (${total_mb}MB > ${threshold_mb}MB)"
        rm -rf "$temp_png_dir"
        return 1
    fi
}


download_pdf() {
    local pdf_url="$1"
    local pdf_file="$2"
    
    if [ "$IS_URL" = true ]; then
    # Use helper function for URL downloads
    download_pdf_from_url "$pdf_url" "$pdf_file"
    else
    # Use helper function for local file handling
    handle_local_pdf_file "$pdf_url" "$pdf_file"
    fi
    
    # Get page count and calculate optimal DPI
    local page_count=$(get_page_count "$pdf_file")
    PDF_DPI=$(calculate_optimal_dpi "$page_count")
    
    log_with_timestamp "📊 PDF Analysis: $page_count pages, optimized DPI: $PDF_DPI"
    
    # Update final state
    update_state "pdf_ready" "file_size=$(ls -lh "$pdf_file" | awk '{print $5}'),pages=$page_count,dpi=$PDF_DPI"
}

# Convert PDF to images
convert_pdf_to_images() {
    local tmp_dir="$1"
    
    # Use global PDF_DPI variable set by download_pdf function
    local dpi="$PDF_DPI"
    
    # Ensure we have a valid DPI value (fallback to 300 if not set)
    if [ -z "$dpi" ] || ! [[ "$dpi" =~ ^[0-9]+$ ]]; then
    dpi="300"
    log_with_timestamp "⚠️ PDF_DPI not set or invalid, using fallback DPI: $dpi"
    else
    log_with_timestamp "✅ Using optimized DPI: $dpi"
    fi
    
    log_with_timestamp "Starting PDF to image conversion (DPI: $dpi)"
    update_state "converting_pdf" "dpi=$dpi"
    
    cd "$tmp_dir"
    if ! pdftoppm -png -r "$dpi" downloaded.pdf page 2>/dev/null; then
    handle_file_error "pdf_conversion" "PDF to images" "PDF conversion to images failed"
    fi
    
    local image_count=$(ls page-*.png 2>/dev/null | wc -l | tr -d ' ')
    log_with_timestamp "PDF conversion completed. Generated $image_count images"
    
    # Optimize PNG files for size reduction (using maximum optimization for 50% reduction)
    optimize_png_files "page-*.png" 7
    
    update_state "pdf_converted" "image_count=$image_count,dpi=$dpi"
}

# Helper functions for file saving

# Determine output directory based on PRIMARY_TAG and PDF URL
# Supports vault/ subdirectory structure for Obsidian Sync 3GB limit compliance
determine_output_directory() {
    local vault_dir="$1"
    local pdf_url="$2"
    
    # Configurable content base directory (defaults to 'vault' for new structure)
    local content_base="${CONTENT_BASE_DIR:-vault}"
    local base_path="$vault_dir/$content_base"
    
    # Determine save location based on PRIMARY_TAG first, then URL/file type
    if [ "$PRIMARY_TAG" = "paper" ]; then
        local output_dir="$base_path/${PAPER_OUTPUT_DIR:-paper}"
    elif [ "$PRIMARY_TAG" = "clip" ]; then
        local output_dir="$base_path/${CLIP_OUTPUT_DIR:-clip}"
    elif [ "$PRIMARY_TAG" = "scan" ]; then
        local output_dir="$base_path/${SCAN_OUTPUT_DIR:-scan}"
    elif echo "$pdf_url" | grep -q "^https\?://"; then
        local output_dir="$base_path/${CLIP_OUTPUT_DIR:-clip}"
    else
        local output_dir="$base_path/${SCAN_OUTPUT_DIR:-scan}"
    fi
    
    mkdir -p "$output_dir"
    echo "$output_dir"
}

# Copy files to destination directories
copy_files_to_destination() {
    local tmp_dir="$1"
    local vault_dir="$2"
    local filename="$3"
    local markdown_file="$4"
    
    cd "$tmp_dir"
    
    # Handle PDF file - always copy to attachments directory
    local attachments_dir="$vault_dir/${ATTACHMENTS_DIR}"
    mkdir -p "$attachments_dir"
    local pdf_target="$attachments_dir/${filename}.pdf"
    cp "downloaded.pdf" "$pdf_target"
    
    # Copy markdown content
    cp "gemini_output.log" "$markdown_file"
    
    # Return PDF target path for reference updating
    echo "$pdf_target"
}


# Update markdown file with dual PDF references (restored functionality)
update_markdown_references_with_dual_links() {
    local markdown_file="$1"
    local filename="$2"
    local vault_dir="$3"
    local relative_pdf_path="../../${ATTACHMENTS_DIR}/${filename}.pdf"
    local absolute_path="${vault_dir}/${ATTACHMENTS_DIR}/${filename}.pdf"
    local absolute_pdf_path="file://$(echo "$absolute_path" | sed 's/ /%20/g')"
    
    # Update file reference in markdown frontmatter
    if grep -q "^tags:" "$markdown_file"; then
    # Find the line number of the second --- (closing frontmatter)
    local closing_line=$(grep -n "^---$" "$markdown_file" | sed -n '2p' | cut -d: -f1)
    if [ -n "$closing_line" ]; then
        # Insert file: line before the closing --- with proper newline
        # Insert file: entry before closing frontmatter using head/tail approach
        head -n $((closing_line - 1)) "$markdown_file" > "${markdown_file}.tmp"
        echo "file: $relative_pdf_path" >> "${markdown_file}.tmp"
        tail -n +$closing_line "$markdown_file" >> "${markdown_file}.tmp"
        mv "${markdown_file}.tmp" "$markdown_file"
    fi
    fi
    echo "" >> "$markdown_file"
    echo "[pdf_relative]($relative_pdf_path)" >> "$markdown_file"
    echo "[pdf_absolute]($absolute_pdf_path)" >> "$markdown_file"
}

# Save files
save_files() {
    local title="${1:-}"
    local vault_dir="$2"
    local tmp_dir="$3"
    local pdf_url="$4"
    
    
    # Generate filename
    local date_prefix=$(date +%Y%m%d)
    local safe_title=$(generate_safe_filename "$title")
    local filename="${date_prefix}_${safe_title}"
    
    # Determine output directory using helper function
    local output_dir=$(determine_output_directory "$vault_dir" "$pdf_url")
    local markdown_file="$output_dir/${filename}.md"
    
    # Copy files using helper function
    local pdf_target=$(copy_files_to_destination "$tmp_dir" "$vault_dir" "$filename" "$markdown_file")
    
    # Update markdown references using helper function
    update_markdown_references_with_dual_links "$markdown_file" "$filename" "$vault_dir"
    
    # Return paths for caller
    echo "$markdown_file|$pdf_target"
}


# Handle errors
handle_error() {
    local error_msg="$1"
    ERROR_MSG="$error_msg"
    log_with_timestamp "ERROR: $error_msg"
    update_state "failed" "error_message=$error_msg"
    
    
    exit 1
}

# Unified error handling functions

# Handle validation errors (configuration, arguments, format validation)
handle_validation_error() {
    local context="$1"
    local error_msg="$2"
    local full_msg="Validation error in $context: $error_msg"
    handle_error "$full_msg"
}

# Handle API errors (Gemini, OpenAI failures)
handle_api_error() {
    local api_name="$1"
    local operation="$2"
    local error_details="$3"
    local full_msg="$api_name API error during $operation: $error_details"
    handle_error "$full_msg"
}

# Handle file operation errors (download, copy, move, pdf_conversion)
handle_file_error() {
    local operation="$1"
    local file_path="$2"
    local error_details="${3:-}"
    local full_msg="File $operation error: $file_path"
    if [ -n "$error_details" ]; then
    full_msg="$full_msg - $error_details"
    fi
    handle_error "$full_msg"
}


# Cleanup function
cleanup() {
    # Prevent duplicate cleanup execution
    if [ "${CLEANUP_DONE:-false}" = "true" ]; then
    return
    fi
    CLEANUP_DONE=true
    
    local success="${1:-false}"  # Default to false (failure)
    
    # Save logs to file only on failure
    if [ "$success" = "false" ] && [ -n "${ERROR_MSG:-}" ]; then
        save_failed_logs
        
        local thread_ts=""
        if [ -f "$THREAD_TS_FILE" ]; then
            thread_ts=$(cat "$THREAD_TS_FILE")
        fi
        # Calculate processing duration
        local processing_duration=$(calculate_processing_duration "${START_TIME:-}")
        # Send failure notification with token info
        send_slack_notification "failure" "${PDF_URL:-Unknown URL}" "${title:-Unknown Document}" "" "$ERROR_MSG" "$thread_ts" "$processing_duration" "${TOKEN_INFO:-0,0,0,0}"
    fi
    
    # Remove temporary directory without logging to avoid conflicts
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR" 2>/dev/null
    fi
    
    # Emergency logs are automatically preserved in failed_logs directory
    # No manual log file handling needed
}


# Get thread timestamp
get_thread_ts() {
    if [ -f "$THREAD_TS_FILE" ]; then
    cat "$THREAD_TS_FILE"
    fi
}

# Save thread timestamp
save_thread_ts() {
    local thread_ts="$1"
    mkdir -p "$STATE_DIR"
    echo "$thread_ts" > "$THREAD_TS_FILE"
    log_with_timestamp "Thread timestamp saved: $thread_ts"
}




# AI API PROCESSING - REALTIME MODE



# Determine processing mode and API key based on PNG Base64 size
determine_processing_mode_by_pdf() {
    local pdf_file="$1"
    
    # Use new strategy function (direct call to allow global variable assignment)
    if determine_api_strategy_v2 "$pdf_file"; then
        # Small payload: Use free API with PNG Base64
        local free_key=$(grep "AI_API_KEY_FREE=" "$VAULT_DIR/.env" 2>/dev/null | sed 's/^AI_API_KEY_FREE=//' | sed 's/ # .*//')
        if [ -z "$free_key" ]; then
            log_with_timestamp "ERROR: AI_API_KEY_FREE is required but not set"
            exit 1
        fi
        
        log_with_timestamp "🆓 FREE/REALTIME with PNG Base64"
        export PROCESSING_MODE="REALTIME" 
        export SELECTED_API_KEY="$free_key"
        export USE_PNG_BASE64="true"
        export USE_FILE_API="false"  # Never use File API with FREE
        return 0
    else
        # Large payload: Use paid API with PDF File API
        local paid_key=$(grep "AI_API_KEY_PAID=" "$VAULT_DIR/.env" 2>/dev/null | sed 's/^AI_API_KEY_PAID=//' | sed 's/ # .*//')
        if [ -z "$paid_key" ]; then
            log_with_timestamp "ERROR: AI_API_KEY_PAID is required for large files but not set"
            exit 1
        fi
        
        log_with_timestamp "💰 PAID/BATCH with PDF File API"
        export PROCESSING_MODE="BATCH"
        export SELECTED_API_KEY="$paid_key"
        export USE_PNG_BASE64="false"
        export USE_FILE_API="true"  # Use File API with PAID
        return 0
    fi
}

# Direct PDF File API upload (always uses File API)
upload_pdf_to_file_api() {
    local pdf_file="$1"
    
    # Get PDF size for API selection
    local pdf_size=$(get_file_size "$pdf_file")
    log_with_timestamp "📄 PDF file size: $pdf_size bytes"
    
    # Upload PDF to File API
    local file_uri=$(upload_file_to_file_api "$pdf_file" "application/pdf")
    
    if [ -n "$file_uri" ]; then
        export FILE_API_URI="$file_uri"
        export FILE_API_MIME_TYPE="application/pdf"
        export USE_FILE_API="true"
        log_with_timestamp "✅ File API upload successful: $file_uri"
        
        # Determine API mode based on PNG Base64 size
        determine_processing_mode_by_pdf "$pdf_file"
        return $?
    else
        log_with_timestamp "❌ File API upload failed"
        exit 1
    fi
}




# Process with Gemini realtime API
call_gemini_bash_api() {
    local prompt="$1"
    
    local escaped_prompt=$(escape_json "$prompt")
    
    # IMPORTANT: Use process-specific filename to avoid collisions in parallel processing
    local payload_file=$(generate_temp_filename "gemini_payload" "json")
    
    # Check if using PNG Base64 for FREE API
    if [ "${USE_PNG_BASE64:-false}" = "true" ] && [ -n "${CONVERTED_PNG_DIR:-}" ]; then
        log_with_timestamp "🖼️ Using PNG Base64 inline payload for FREE API"
        
        # Build payload with PNG images
        {
            echo '{"contents":[{"parts":['
            
            # Add prompt text
            echo "{\"text\":\"$escaped_prompt\"}"
            
            # Add each PNG as Base64
            for png_file in "$CONVERTED_PNG_DIR"/page-*.png; do
                if [[ -f "$png_file" ]]; then
                    echo ','
                    echo '{"inline_data":{'
                    echo '"mime_type":"image/png",'
                    echo -n '"data":"'
                    base64 -i "$png_file" 2>/dev/null || base64 "$png_file" 2>/dev/null | tr -d '\n'
                    echo '"'
                    echo '}}'
                fi
            done
            
            echo ']}],"generationConfig":{"temperature":'$TEMPERATURE'}}'
        } > "$payload_file"
        
    elif [ "$USE_FILE_API" = "true" ] && [ -n "$FILE_API_URI" ]; then
        log_with_timestamp "🔗 Using File API payload format for PAID API"
        generate_file_api_payload "$FILE_API_URI" "$FILE_API_MIME_TYPE" "$escaped_prompt" > "$payload_file"
        
    else
        # Fallback: should not reach here in normal flow
        log_with_timestamp "⚠️ Fallback: Creating PDF from images for File API"
        
        # For backward compatibility: still try to process images if neither mode is set
        local json_parts_file=$(generate_temp_filename "json_parts" "tmp")
        echo "{\"text\":\"$escaped_prompt\"}" > "$json_parts_file"
        upload_pdf_to_file_api "$json_parts_file"
        rm -f "$json_parts_file"
        
        if [ -n "$FILE_API_URI" ]; then
            generate_file_api_payload "$FILE_API_URI" "$FILE_API_MIME_TYPE" "$escaped_prompt" > "$payload_file"
        else
            log_with_timestamp "ERROR: No valid processing mode"
            return 1
        fi
    fi
    
    # API selection already done by upload_pdf_to_file_api
    # Using SELECTED_API_KEY and PROCESSING_MODE set earlier
    

    
    
    # IMPORTANT: Use process-specific filename to avoid collisions in parallel processing
    local response_file=$(generate_temp_filename "api_response" "json")
    
    
    # Make API call with verbose error logging
    local curl_exit_code=0
    if curl -s -X POST \
    "$GEMINI_BASE_URL/models/$AI_MODEL:generateContent" \
    -H "Content-Type: application/json" \
    -H "x-goog-api-key: ${SELECTED_API_KEY:-$AI_API_KEY}" \
    -d "@$payload_file" \
    --connect-timeout "$REALTIME_API_TIMEOUT" \
    --max-time "$REALTIME_API_MAX_TIME" \
    -o "$response_file"; then
    
    # Check if response contains error
    if grep -q '"error"' "$response_file" 2>/dev/null; then
        # 503エラーの場合はリトライ処理
        if is_503_error "$response_file"; then
            log_with_timestamp "⚠️ 503エラーが発生しました"
            rm -f "$payload_file" "$response_file"
            
            local retry_result
            handle_503_error_retry
            retry_result=$?
            
            if [ $retry_result -eq 2 ]; then
                # リトライを続行
                call_gemini_bash_api "$prompt"
                return $?
            else
                # リトライ上限到達
                return 1
            fi
        else
            # その他のエラーの場合は従来の処理
            log_with_timestamp "❌ Gemini API returned error response:"
            local error_content=$(cat "$response_file")
            log_with_timestamp "$error_content"
            rm -f "$payload_file" "$response_file"
            return 1
        fi
    fi
    
    local raw_text=$(jq -r '.candidates[0].content.parts[0].text // empty' "$response_file" 2>/dev/null || echo "")
    
    if [ -n "$raw_text" ]; then
        log_with_timestamp "✅ Gemini API response received successfully"
        rm -f "$payload_file" "$response_file"
        process_api_response_text "$raw_text" > "$TMP_DIR/gemini_output.log"
        return 0
    else
        # Check for RECITATION error first
        if is_recitation_error "$response_file"; then
            log_with_timestamp "⚠️ RECITATION error detected"
            handle_recitation_error "$response_file" "${batch_id:-""}"
            rm -f "$payload_file" "$response_file"
            return 2  # Special return code for RECITATION error
        fi
        
        # Check if response has proper structure but no text (image unreadable)
        if grep -q '"parts"' "$response_file" 2>/dev/null; then
            log_with_timestamp "❌ Gemini could not extract readable text from the image(s)"
        else
            log_with_timestamp "❌ Gemini returned response without text content (image may be unprocessable)"
        fi
        log_with_timestamp "Response content:"
        cat "$response_file" | head -10 >&2
        rm -f "$payload_file" "$response_file"
        return 1
    fi
    else
    curl_exit_code=$?
    log_with_timestamp "❌ Curl command failed with exit code: $curl_exit_code"
    if [ -s "$response_file" ]; then
        log_with_timestamp "Response content:"
        cat "$response_file"
    fi
    rm -f "$payload_file" "$response_file"
    return 1
    fi
}


# AI API PROCESSING - BATCH MODE

# Create batch request
create_batch_request() {
    local prompt="$1"
    local request_file="$2"
    
    local escaped_prompt=$(escape_json "$prompt")
    
    # IMPORTANT: Use process-specific filename to avoid collisions in parallel processing
    local json_parts_file=$(generate_temp_filename "json_parts" "tmp")
    echo "{\"text\":\"$escaped_prompt\"}" > "$json_parts_file"
    
    # For BATCH processing, always use File API for optimal performance
    log_with_timestamp "Using File API for batch processing (PAID API always uses File API)"
    
    # Use original PDF directly for File API upload (no re-generation needed)
    local pdf_file="$TMP_DIR/downloaded.pdf"
    
    local file_uri=$(upload_file_to_file_api "$pdf_file" "application/pdf")
    if [ -z "$file_uri" ]; then
        log_with_timestamp "ERROR: File API upload failed"
        rm -f "$json_parts_file"
        return 1
    fi
    
    log_with_timestamp "PDF uploaded successfully via File API: $file_uri"
    
    # Create 8/25 format batch request (proven working format)
    echo -n '{"batch":{"display_name":"pdf-ocr-'$TIMESTAMP'","input_config":{"requests":{"requests":[{"request":' > "$request_file"
    generate_file_api_payload "$file_uri" "application/pdf" "$escaped_prompt" | tr -d '\n' >> "$request_file"
    echo ',"metadata":{"key":"request-1"}}]}}}}' >> "$request_file"
    
    # Validate request_file before use
    if [ ! -f "$request_file" ] || [ ! -s "$request_file" ]; then
        log_with_timestamp "ERROR: Batch request file is empty or missing: $request_file"
        return 1
    fi
    
    # Using SELECTED_API_KEY and PROCESSING_MODE set by determine_processing_mode_by_pdf_size()
    
    rm -f "$json_parts_file"
}



# Helper functions for robust curl operations

# Validate curl parameters
validate_curl_parameters() {
    local url="$1"
    local output_file="$2"
    local max_retries="$3"
    local base_delay="$4" 
    local timeout="$5"
    local api_key="$6"
    
    if [ -z "$url" ] || [ -z "$output_file" ]; then
    log_with_timestamp "ERROR: URL and output file are required"
    return 1
    fi
    
    if [ "$max_retries" -lt 1 ] || [ "$max_retries" -gt 10 ]; then
    log_with_timestamp "ERROR: max_retries must be between 1 and 10"
    return 1
    fi
    
    if [ "$base_delay" -lt 1 ] || [ "$base_delay" -gt 30 ]; then
    log_with_timestamp "ERROR: base_delay must be between 1 and 30 seconds"
    return 1
    fi
    
    if [ "$timeout" -lt 5 ] || [ "$timeout" -gt 28800 ]; then
    log_with_timestamp "ERROR: timeout must be between 5 and 28800 seconds (8 hours)"
    return 1
    fi
    
    if [ -z "$api_key" ]; then
    log_with_timestamp "ERROR: API key is required"
    return 1
    fi
    
    return 0
}

# Perform single curl request
perform_curl_request() {
    local url="$1"
    local output_file="$2"
    local timeout="$3"
    local api_key="$4"
    local temp_error_file="$5"
    
    # Remove any existing output file to ensure clean state
    rm -f "$output_file" 2>/dev/null || true
    
    # Perform curl with proper error capture
    local curl_exit_code=0
    curl -s -X GET \
    "$url" \
    -H "x-goog-api-key: $api_key" \
    --connect-timeout "$timeout" \
    --max-time $((timeout * 2)) \
    -o "$output_file" \
    --write-out "CURL_STATUS:%{http_code};SIZE:%{size_download};TIME:%{time_total}" \
    2>"$temp_error_file" || curl_exit_code=$?
    
    return $curl_exit_code
}

# Parse curl response and determine success
parse_curl_response() {
    local output_file="$1"
    local curl_exit_code="$2"
    local temp_error_file="$3"
    
    local success=false
    local last_error=""
    
    # Capture curl metadata
    local curl_info=""
    if [ -f "$temp_error_file" ]; then
    curl_info=$(tail -1 "$temp_error_file" 2>/dev/null | grep "CURL_STATUS:" || echo "")
    last_error=$(grep -v "CURL_STATUS:" "$temp_error_file" 2>/dev/null | head -"$ERROR_MESSAGE_LINES" | tr '\n' ' ' || echo "")
    fi
    
    # Parse HTTP status if available
    local http_status=""
    if [[ "$curl_info" =~ CURL_STATUS:([0-9]+) ]]; then
    http_status="${BASH_REMATCH[1]}"
    fi
    
    log_with_timestamp "Curl exit code: $curl_exit_code, HTTP status: ${http_status:-unknown}"
    
    # Check for success conditions
    if [ $curl_exit_code -eq 0 ]; then
    if [ -f "$output_file" ]; then
        local file_size=$(get_file_size "$output_file")
        log_with_timestamp "Output file created with size: $file_size bytes"
        
        if [ "$file_size" -gt 0 ]; then
            # File has content - check if it's valid JSON
            if jq . "$output_file" >/dev/null 2>&1; then
                success=true
                log_with_timestamp "SUCCESS: Valid JSON content retrieved and saved"
            else
                log_with_timestamp "WARNING: File created but content is not valid JSON"
                last_error="Invalid JSON content in response file"
            fi
        else
            log_with_timestamp "WARNING: Empty file created (possible Google Drive sync interference)"
            last_error="Empty response file created"
        fi
    else
        log_with_timestamp "ERROR: Output file not created despite curl success"
        last_error="Output file not created"
    fi
    else
    log_with_timestamp "ERROR: Curl failed with exit code $curl_exit_code"
    if [ -n "$last_error" ]; then
        log_with_timestamp "ERROR details: $last_error"
    fi
    fi
    
    # Handle HTTP errors
    if [ -n "$http_status" ] && [ "$http_status" -ge 400 ]; then
    log_with_timestamp "HTTP ERROR: Status $http_status"
    last_error="HTTP $http_status error"
    
    # Don't retry on certain HTTP errors
    case "$http_status" in
        401|403|404|429)
            log_with_timestamp "HTTP $http_status - Not retrying (permanent error)"
            echo "$last_error"
            return 2  # Special return code for permanent errors
            ;;
    esac
    fi
    
    if [ "$success" = true ]; then
    echo "SUCCESS"
    return 0
    else
    echo "$last_error"
    return 1
    fi
}

# Handle retry logic and delays
handle_retry_logic() {
    local attempt="$1"
    local max_retries="$2"
    local delay="$3"
    
    # If this was the last attempt, give up
    if [ $attempt -eq $max_retries ]; then
    log_with_timestamp "FINAL FAILURE: All $max_retries attempts exhausted"
    return 1
    fi
    
    # Wait before retry with exponential backoff
    log_with_timestamp "Waiting ${delay}s before retry (Google Drive sync interference mitigation)"
    sleep "$delay"
    
    # Exponential backoff with jitter
    delay=$((delay * 2))
    if [ $delay -gt 60 ]; then
    delay=60  # Cap at 60 seconds
    fi
    
    # Add random jitter (0-2 seconds) to avoid thundering herd
    local jitter=$((RANDOM % 3))
    delay=$((delay + jitter))
    
    echo $delay  # Return new delay
    return 0
}

# Robust curl with retry mechanism for Google Drive sync interference
robust_curl_with_retry() {
    local url="$1"
    local output_file="$2"
    local max_retries="${3:-5}"
    local base_delay="${4:-1}"
    local timeout="${5:-30}"
    local api_key="$6"
    
    # Ensure API key is set
    if [ -z "$api_key" ]; then
    api_key="$AI_API_KEY"
    fi
    
    # Validate parameters using helper function
    if ! validate_curl_parameters "$url" "$output_file" "$max_retries" "$base_delay" "$timeout" "$api_key"; then
    return 1
    fi
    
    local attempt=0
    local delay="$base_delay"
    local temp_error_file=$(mktemp)
    
    log_with_timestamp "Starting robust curl request to: $url"
    log_with_timestamp "Output file: $output_file (max_retries: $max_retries)"
    
    while [ $attempt -lt $max_retries ]; do
    attempt=$((attempt + 1))
    log_with_timestamp "Curl attempt $attempt/$max_retries (delay: ${delay}s)"
    
    # Perform curl request using helper function
    local curl_exit_code=0
    perform_curl_request "$url" "$output_file" "$timeout" "$api_key" "$temp_error_file" || curl_exit_code=$?
    
    # Parse response using helper function  
    local parse_result
    parse_result=$(parse_curl_response "$output_file" "$curl_exit_code" "$temp_error_file")
    local parse_exit_code=$?
    
    # Handle different response types
    if [ $parse_exit_code -eq 0 ]; then
        # Success
        rm -f "$temp_error_file"
        return 0
    elif [ $parse_exit_code -eq 2 ]; then
        # Permanent error, don't retry
        rm -f "$temp_error_file"
        return 1
    fi
    
    # Handle retry logic using helper function
    if delay=$(handle_retry_logic "$attempt" "$max_retries" "$delay"); then
        continue
    else
        # Max retries reached
        log_with_timestamp "Final error: $parse_result"
        rm -f "$temp_error_file"
        return 1
    fi
    done
    
    rm -f "$temp_error_file"
    return 1
}

# Enhanced wait_for_batch_completion with robust error handling
wait_for_batch_completion() {
    local batch_name="$1"
    local total_wait=0
    local consecutive_failures=0
    local max_consecutive_failures=3
    
    log_with_timestamp "Starting robust batch completion wait for: $batch_name"
    update_state "waiting_for_batch" "batch_name=$batch_name"
    
    while [ $total_wait -lt $BATCH_MAX_WAIT ]; do
    # IMPORTANT: Use process-specific filename to avoid collisions in parallel processing
    local status_file=$(generate_temp_filename "batch_status" "json")
    
    # Use robust curl with retry (fixes Google Drive sync issues)
    if robust_curl_with_retry "$GEMINI_BASE_URL/$batch_name" "$status_file" 2 1 "$BATCH_API_TIMEOUT" "${SELECTED_API_KEY:-$AI_API_KEY}"; then
        # Reset failure counter on success
        consecutive_failures=0
        
        # Parse state using jq with proper error handling and fallback patterns
        local state=""
        
        # Pattern 1: Check nested metadata.state (current API format)
        state=$(jq -r '.metadata.state // empty' "$status_file" 2>/dev/null)
        
        
        # Handle parsing errors or null values
        if [ -z "$state" ] || [ "$state" = "null" ]; then
            log_with_timestamp "Failed to parse batch state from JSON response, treating as unknown state"
            state=""
        fi
        
        log_with_timestamp "Batch state: '$state' (waited ${total_wait}s / ${BATCH_MAX_WAIT}s)"
        
        case "$state" in
            "BATCH_STATE_SUCCEEDED")
                log_with_timestamp "Batch completed successfully!"
                rm -f "$status_file"
                return 0
                ;;
            "BATCH_STATE_FAILED")
                log_with_timestamp "Batch processing failed. Check Gemini API logs for details."
                rm -f "$status_file"
                return 1
                ;;
            "BATCH_STATE_CANCELLED")
                log_with_timestamp "Batch was cancelled. Processing stopped."
                rm -f "$status_file"
                return 1
                ;;
            "BATCH_STATE_PENDING")
                log_with_timestamp "Batch is pending (queued), continuing to wait..."
                ;;
            "BATCH_STATE_RUNNING")
                log_with_timestamp "Batch is running (actively processing), continuing to wait..."
                ;;
            "BATCH_STATE_PROCESSING")
                log_with_timestamp "Batch is processing (finalizing results), continuing to wait..."
                ;;
            "")
                log_with_timestamp "Unable to determine batch state from API response, continuing to wait..."
                ;;
            *)
                log_with_timestamp "Unknown batch state: '$state', continuing to wait..."
                ;;
        esac
        
        rm -f "$status_file"
    else
        # Handle curl failure with robust error handling
        consecutive_failures=$((consecutive_failures + 1))
        log_with_timestamp "Batch status check failed (consecutive failures: $consecutive_failures/$max_consecutive_failures)"
        
        if [ $consecutive_failures -ge $max_consecutive_failures ]; then
            log_with_timestamp "ERROR: Too many consecutive failures checking batch status"
            return 1
        fi
    fi
    
    sleep $BATCH_POLL_INTERVAL
    total_wait=$((total_wait + BATCH_POLL_INTERVAL))
    done
    
    log_with_timestamp "ERROR: Batch wait timeout exceeded ($BATCH_MAX_WAIT seconds)"
    return 1
}

# Enhanced get_batch_result with robust error handling
get_batch_result() {
    local batch_name="$1"
    local output_file="$2"
    local max_retries="${3:-3}"
    
    log_with_timestamp "Retrieving batch result for: $batch_name"
    
    # IMPORTANT: Use process-specific filename to avoid collisions in parallel processing
    local result_file=$(generate_temp_filename "batch_result" "json")
    
    if robust_curl_with_retry "$GEMINI_BASE_URL/$batch_name" "$result_file" "$max_retries" 1 "$BATCH_API_TIMEOUT" "${SELECTED_API_KEY:-$AI_API_KEY}"; then
    if [ -f "$result_file" ] && [ -s "$result_file" ]; then
        # Extract text using helper function
        # Call function without command substitution to preserve exported variables
        extract_text_from_json "$result_file"
        local extract_result=$?
        local raw_text="$EXTRACTED_TEXT"
        
        if [ $extract_result -eq 0 ] && [ -n "$raw_text" ] && [ "$raw_text" != "Error:"* ] && [ "$raw_text" != "null" ]; then
            process_api_response_text "$raw_text" > "$output_file"
            
            rm -f "$result_file"
            log_with_timestamp "Batch result retrieved and processed successfully"
            return 0
        else
            log_with_timestamp "ERROR: No valid text content found in batch result"
            rm -f "$result_file"
            return 1
        fi
    else
        log_with_timestamp "ERROR: Batch result file not created or empty"
        return 1
    fi
    else
    log_with_timestamp "ERROR: Failed to retrieve batch result after $max_retries attempts"
    return 1
    fi
}

# Helper function to extract text from JSON responses with multiple pattern support
# Also extracts token usage metadata and exports it to global variables
extract_text_from_json() {
    local result_file="$1"
    
    # Initialize global variables
    EXTRACTED_TEXT=""
    TOKEN_INFO="0,0,0,0"  # Default: input,output,thoughts,total
    
    if [ ! -f "$result_file" ] || [ ! -s "$result_file" ]; then
    return 1
    fi
    
    # Check for error responses first
    local error_msg=$(jq -r '.response.inlinedResponses.inlinedResponses[0].error.message // .metadata.output.inlinedResponses.inlinedResponses[0].error.message // empty' "$result_file" 2>/dev/null)
    if [ -n "$error_msg" ] && [ "$error_msg" != "null" ]; then
    log_with_timestamp "ERROR: Batch processing failed - $error_msg"
    return 1
    fi
    
    # Extract token usage metadata
    # Try different patterns for token info location
    local token_patterns=(
    '.response.inlinedResponses.inlinedResponses[0]?.response?.usageMetadata'
    '.usageMetadata'
    '.metadata.output.inlinedResponses.inlinedResponses[0]?.response?.usageMetadata'
    )
    
    for token_pattern in "${token_patterns[@]}"; do
    local usage_metadata=$(jq -r "$token_pattern // empty" "$result_file" 2>/dev/null)
    if [ -n "$usage_metadata" ] && [ "$usage_metadata" != "null" ] && [ "$usage_metadata" != "empty" ]; then
        local prompt_tokens=$(echo "$usage_metadata" | jq -r '.promptTokenCount // 0')
        local total_tokens=$(echo "$usage_metadata" | jq -r '.totalTokenCount // 0')
        local thoughts_tokens=$(echo "$usage_metadata" | jq -r '.thoughtsTokenCount // 0')
        # Use candidatesTokenCount if available, otherwise calculate
        local candidates_tokens=$(echo "$usage_metadata" | jq -r '.candidatesTokenCount // 0')
        local output_tokens=$candidates_tokens
        if [ "$output_tokens" -eq 0 ]; then
            # Fallback calculation if candidatesTokenCount is not available
            output_tokens=$((total_tokens - prompt_tokens - thoughts_tokens))
        fi
        TOKEN_INFO="$prompt_tokens,$output_tokens,$thoughts_tokens,$total_tokens"
        log_with_timestamp "Token usage: input=$prompt_tokens, output=$output_tokens, thoughts=$thoughts_tokens, total=$total_tokens"
        break
    fi
    done
    
    # Extract text content
    local patterns=(
    '.metadata.output.inlinedResponses.inlinedResponses[0].response.candidates[0].content.parts[0].text // empty'
    '.response.inlinedResponses.inlinedResponses[0]?.response?.candidates[0]?.content?.parts[]?.text // empty'
    '.candidates[0]?.content?.parts[]?.text // empty'
    '.content?.parts[]?.text // empty'
    '.parts[]?.text // empty'
    '.text // empty'
    )
    
    for pattern in "${patterns[@]}"; do
    local raw_text=$(jq -r "$pattern" "$result_file" 2>/dev/null)
    if [ -n "$raw_text" ] && [ "$raw_text" != "null" ]; then
        EXTRACTED_TEXT="$raw_text"  # Set global variable instead of echoing
        return 0
    fi
    done
    
    return 1
}

# Helper function to process API response text (escape sequences and markdown cleanup)
process_api_response_text() {
    local raw_text="$1"
    
    echo "$raw_text" | \
    sed 's/\\n/\n/g' | \
    sed 's/\\"/"/g' | \
    sed 's/\\\\/\\/g' | \
    sed 's/\\t/\t/g' | \
    sed 's/\\r/\r/g' | \
    sed 's/\\u003e/>/g' | \
    sed 's/\\u003cbr\\u003e//g' | \
    sed 's/^```markdown[[:space:]]*//g' | \
    sed 's/[[:space:]]*```[[:space:]]*$//g' | \
    sed '/^```markdown$/d' | \
    sed '/^```$/d' | \
    sed '1{/^[[:space:]]*$/d;}'
}

# Helper function to generate process-specific temporary filenames
generate_temp_filename() {
    local base_name="$1"
    local extension="${2:-tmp}"
    echo "${TMP_DIR}/${base_name}_${BATCH_ID}.${extension}"
}

# Process with Gemini batch mode
process_with_gemini_batch() {
    local prompt="$1"
    local output_file="$2"
    
    # Ensure correct API key for batch processing (PAID API required)
    if [[ "${PROCESSING_MODE:-}" == "BATCH" ]] || [[ "${FORCE_PAID_API:-false}" == "true" ]]; then
        SELECTED_API_KEY="$AI_API_KEY_PAID"
    fi
    
    log_with_timestamp "Starting Gemini batch processing"
    update_state "creating_batch_request" "model=$AI_MODEL"
    
    # IMPORTANT: Use process-specific filename to avoid collisions in parallel processing
    local request_file=$(generate_temp_filename "batch_request" "json")
    local response_file=$(generate_temp_filename "batch_response" "json")
    
    # Create and submit batch request
    create_batch_request "$prompt" "$request_file"
    
    log_with_timestamp "Submitting batch request to Gemini API"
    if curl -s -X POST \
    "$GEMINI_BASE_URL/models/$AI_MODEL:batchGenerateContent" \
    -H "Content-Type: application/json" \
    -H "x-goog-api-key: ${SELECTED_API_KEY:-$AI_API_KEY}" \
    -d "@$request_file" \
    --connect-timeout "$BATCH_API_TIMEOUT" \
    --max-time "$BATCH_API_MAX_TIME" \
    -o "$response_file"; then
    # Parse batch name using jq with proper error handling
    local batch_name=$(jq -r '.name // empty' "$response_file" 2>/dev/null)
    
    if [ -n "$batch_name" ] && [ "$batch_name" != "null" ]; then
        log_with_timestamp "Batch submitted successfully: $batch_name"
        
        if wait_for_batch_completion "$batch_name"; then
            if get_batch_result "$batch_name" "$output_file"; then
                log_with_timestamp "Batch processing completed successfully"
                update_state "batch_processing_completed" "output_file=$output_file"
                return 0
            fi
        fi
    else
        log_with_timestamp "ERROR: Failed to parse batch response or empty batch name"
        if [ -f "$response_file" ]; then
            log_with_timestamp "API Response: $(cat "$response_file")"
        fi
    fi
    else
    log_with_timestamp "ERROR: Failed to submit batch request"
    if [ -f "$response_file" ]; then
        log_with_timestamp "API Response: $(cat "$response_file")"
    fi
    fi
    
    handle_api_error "Gemini" "batch processing" "Batch processing failed"
}

# Set trap for cleanup (defaults to failure)
trap 'cleanup "false"' EXIT

# Setup directories after argument parsing
setup_directories() {
    # Get PDF basename for temp directory naming
    local pdf_basename="unknown"
    if [ -n "${PDF_URL:-}" ]; then
    if [ "${IS_URL:-true}" = false ] && [ -f "$PDF_URL" ]; then
        pdf_basename="$(basename "$PDF_URL" .pdf)"
    fi
    fi
    
    # Determine temp directory location - always in script/ directory
    local temp_base_dir="${PDF_TEMP_BASE_DIR:-$SCRIPT_DIR}"
    if [[ "$temp_base_dir" == ./* ]] || [[ "$temp_base_dir" == ../* ]]; then
    temp_base_dir="$(cd "$SCRIPT_DIR" && cd "$temp_base_dir" 2>/dev/null && pwd)" || temp_base_dir="$SCRIPT_DIR/$temp_base_dir"
    fi
    
    TMP_DIR="$temp_base_dir/temp_${TIMESTAMP}_${pdf_basename}"
    
    PDF_FILE="$TMP_DIR/downloaded.pdf"
    STATE_DIR="$TMP_DIR/state"
    STATE_FILE="$STATE_DIR/${BATCH_ID}.state"
    LOG_FILE="$STATE_DIR/${BATCH_ID}.log"
    THREAD_TS_FILE="$STATE_DIR/${BATCH_ID}.thread_ts"
}

# Main processing stage functions

# Stage 1: Initialize processing environment (merged and simplified)
initialize_processing() {
    START_TIME=$(TZ='Asia/Tokyo' date '+%Y-%m-%d %H:%M:%S JST')
    
    log_with_timestamp "===== Starting PDF processing pipeline ====="
    log_with_timestamp "Input: $INPUT (Batch: ${BATCH_MODE:-false})"
    log_with_timestamp "PDF URL: $PDF_URL"
    log_with_timestamp "Batch ID: $BATCH_ID"
}



# Stage 2: Setup and validate environment
setup_and_validate_environment() {
    # Load environment first to get PDF_PROCESSED_DIR
    if ! load_environment; then
    handle_validation_error "environment" "Failed to load environment variables"
    fi
    
    # Setup directories after loading environment
    setup_directories
    
    # Create directories
    mkdir -p "$VAULT_DIR/$ATTACHMENTS_DIR" "$TMP_DIR" "$STATE_DIR"
    
    # Validate configuration
    validate_config
}

# Stage 3: Handle PDF acquisition and initial notifications
handle_pdf_acquisition() {
    # Create initial state and send start notification
    create_state_file "initializing" "start_time=$START_TIME;mode=AUTO"
    
    log_with_timestamp "Sending start notification to Slack"
    local thread_ts=$(send_slack_start_notification "$PDF_URL" "$BATCH_ID" "${PROCESSING_MODE:-AUTO}")
    
    if [ -n "$thread_ts" ]; then
    update_state "start_notification_sent" "thread_ts=$thread_ts"
    else
    update_state "start_notification_failed" "fallback_mode=true"
    fi
    
    # Download PDF
    download_pdf "$PDF_URL" "$PDF_FILE"
    
    # Return thread_ts and PDF_DPI for use by main function (fixes subshell scope issue)
    echo "$thread_ts|${PDF_DPI:-300}"
}

# Stage 4: Convert and prepare images
convert_and_prepare_images() {
    # Convert PDF to images (this function already changes to TMP_DIR)
    convert_pdf_to_images "$TMP_DIR"
    
    # Note: convert_pdf_to_images already changes to TMP_DIR, no need to cd again
}

# Stage 5: Process with AI API  
process_with_ai_api() {
    log_with_timestamp "🔄 Starting Stage 5: Process with AI API"
    local source_value
    
    # Prepare source value for YAML frontmatter
    if [ "$IS_URL" = true ]; then
    source_value="$PDF_URL"
    else
    # For local files, use relative path from vault root
    local vault_relative_path
    # Get absolute paths for comparison (macOS compatible)
    local abs_vault_dir=$(cd "$VAULT_DIR" && pwd)
    
    # PDF_URLの絶対パス化 - 現在のディレクトリがTMP_DIRに変更されていることを考慮
    local abs_pdf_path
    if [[ "$PDF_URL" = /* ]]; then
        # 既に絶対パス
        abs_pdf_path="$PDF_URL"
    else
        # 相対パスの場合 - TMP_DIRに移動後の状況を考慮
        local current_dir=$(pwd)
        local parent_dir=$(dirname "$current_dir")
        
        # PDF_URLが"dirname/filename"形式の場合の処理
        if [[ "$PDF_URL" == */* ]]; then
            # パスにディレクトリが含まれる場合
            abs_pdf_path="$parent_dir/$PDF_URL"
        else
            # ファイル名のみの場合は現在のディレクトリ
            abs_pdf_path="$current_dir/$PDF_URL"
        fi
    fi
    
    # Create relative path by removing vault directory prefix
    if [[ "$abs_pdf_path" == "$abs_vault_dir"/* ]]; then
        vault_relative_path="${abs_pdf_path#$abs_vault_dir/}"
    else
        # Fallback to basename if not under vault directory
        vault_relative_path="$(basename "$PDF_URL")"
    fi
    source_value="$vault_relative_path"
    fi
    
    log_with_timestamp "✅ Stage 5 completed: source_value=$source_value"
    echo "$source_value"
}

# Load tag dictionary function
load_tag_dictionary() {
    local tag_file="$VAULT_DIR/script/tag.md"
    if [ -f "$tag_file" ]; then
    cat "$tag_file"
    else
    echo "# Tag dictionary not available"
    fi
}

# Generate OCR processing prompt with hybrid tagging
generate_ocr_prompt() {
    log_with_timestamp "🔄 Starting generate_ocr_prompt"
    local source_value="$1"
    local tag_dictionary=$(load_tag_dictionary)
    log_with_timestamp "✅ generate_ocr_prompt completed"
    
    cat << EOF
これらの画像を以下のステップに従って完全なMarkdown文書を生成してください：

1. **OCR変換**
- 画像に含まれる全てのテキストを正確にOCRで読み取る
- **一言一句を正確にMarkdown化する。内容の要約や省略は禁止**
- 文書構造を完全に保持（見出し、節、小節、項目番号）
- 適切な段落区切りと改行を維持
- 表を正確なMarkdownテーブル形式に変換
- 番号付きリスト・箇条書きリストを保持
- 日本語テキストの自然な間隔とフォーマット
- 図・表キャプション、注釈を適切に配置
- 学術引用形式・参考文献を維持
- 強調やフォーマットに適切なMarkdown記法を使用
- **全ページの内容を結合して一つの連続した文書として出力** この際に要約などは行うことは禁止

2. **日本語以外の場合: 日本語訳の追加**
- OCRした内容が日本語以外の場合は、**内容をパラグラフごとに日本語**に翻訳し、各原文のパラグラフの直下に日本語訳を追加
- **原文は保持してmarkdownから削除しないこと**

3. **HYBRID TAGGING システム:**

【利用可能な標準タグ辞書】
$tag_dictionary

【タグ付与の手順】
STEP1: 必須タグを設定
- ${PRIMARY_TAG} (処理カテゴリ)
- pdf (ファイル形式)

STEP2: 標準タグを3-5個選択
上記辞書から文書の主要テーマに合致するタグを選択してください。

STEP3: 動的タグを2-4個新規作成  
文書の具体的・専門的な内容を表現する新しいタグを作成してください。

【動的タグ作成例】
✅ 良い例：
- ai_transformer_model (AI技術の具体的手法)
- urban_planning_shibuya (地域特化の都市計画)
- covid19_vaccine_efficacy (具体的な医学研究)
- climate_change_adaptation (環境問題の対策)
- digital_transformation_sme (中小企業のDX)
- quantum_computing_algorithm (量子計算アルゴリズム)
- renewable_energy_policy (再生エネルギー政策)

❌ 悪い例：
- general_study (曖昧すぎる)
- important_document (意味がない)
- japanese_text (当然の情報)
- good_paper (主観的で無意味)

【命名規則】
- 全て英語小文字
- 単語間はアンダースコア(_)で区切り  
- 2-4語の組み合わせ
- 検索で絞り込める具体性を持つ
- 専門用語や固有名詞を活用

4. **YAML frontmatter要件:**
- 文書の先頭に以下のYAMLメタデータを含めてください
- CSL JSON Standard Fieldsに従い、必要なフィールドを埋めてください。もし不明な場合は空欄にしてください

---
title: 文書内容を踏まえた適切な日本語タイトル
author: 文書から特定できる著者名、不明な場合は空欄
abstract: 文書の概要・要約を1-2文で記述
URL: ${source_value}
created: 現在の日時（日本時間）
issued: 元の文書の出版日時、不明な場合は空欄 
container-title:
volume:
issue:
page:
editor:
publisher:
publisher-place:
type: article-journal
DOI:
ISBN:
PMID:
id:
keywords:
language:
tags:
    - ${PRIMARY_TAG}
    - pdf
    - [標準タグ1]
    - [標準タグ2]  
    - [標準タグ3]
    - [動的タグ1]
    - [動的タグ2]
    - [動的タグ3]
---

5. **出力形式:**
- 直接Markdown形式で出力
- 日本語以外の場合は原文・日本語訳の両方を含める
- ファイル操作やプロセスの説明は含めない
- Markdownコンテンツのみを返す
- **一言一句を正確にMarkdown化する。内容の要約や省略は禁止**

この指示に従い、文書の完全なOCR転記と完全で正確なMarkdown文書を生成してください。

🚨 **CRITICAL OCR INSTRUCTIONS** 🚨
**DO NOT SUMMARIZE OR ANALYZE. PERFORM DIRECT OCR TRANSCRIPTION.**
EOF
}

# Stage 6: Determine API mode based on PNG Base64 size
determine_api_mode_from_images() {
    log_with_timestamp "Determining API mode based on PNG Base64 size"
    
    # Get the downloaded PDF file path
    local pdf_file="$TMP_DIR/downloaded.pdf"
    
    if [[ ! -f "$pdf_file" ]]; then
        log_with_timestamp "⚠️ PDF file not found, using fallback to PAID API"
        # Set PAID API as fallback
        local paid_key=$(grep "AI_API_KEY_PAID=" "$VAULT_DIR/.env" 2>/dev/null | sed 's/^AI_API_KEY_PAID=//' | sed 's/ # .*//')
        if [ -z "$paid_key" ]; then
            log_with_timestamp "ERROR: AI_API_KEY_PAID is required but not set"
            handle_validation_error "api_selection" "PAID API key not available"
            return 1
        fi
        export PROCESSING_MODE="BATCH"
        export SELECTED_API_KEY="$paid_key"
        export USE_FILE_API="true"
        return 0
    fi
    
    # Use the new determine function
    determine_processing_mode_by_pdf "$pdf_file"
    local api_selection_status=$?
    
    if [ $api_selection_status -eq 0 ]; then
        log_with_timestamp "API mode determined: ${PROCESSING_MODE:-UNKNOWN}"
        return 0
    else
        log_with_timestamp "API mode determination completed"
        return 0
    fi
}

# Stage 7: Execute AI processing based on mode
execute_ai_processing() {
    local prompt="$1"
    
    case "${PROCESSING_MODE:-REALTIME}" in
    "REALTIME")
        log_with_timestamp "Processing in realtime mode"
        log_with_timestamp "Starting Gemini realtime processing"
        update_state "processing_with_gemini" "mode=realtime;model=$AI_MODEL"
        
        local gemini_result=0
        call_gemini_bash_api "$prompt" > "$TMP_DIR/gemini_output.log" || gemini_result=$?
        
        if [ $gemini_result -eq 0 ]; then
            log_with_timestamp "Gemini API processing completed successfully"
            update_state "gemini_completed" "output_file=$TMP_DIR/gemini_output.log"
        elif [ $gemini_result -eq 2 ]; then
            # RECITATION error - retry with PAID API automatically
            log_with_timestamp "🔄 Retrying with PAID API due to RECITATION error..."
            
            # Force PAID API mode temporarily
            local original_processing_mode="${PROCESSING_MODE}"
            PROCESSING_MODE="BATCH"
            
            if process_with_gemini_batch "$prompt" "$TMP_DIR/gemini_output.log"; then
                log_with_timestamp "✅ PAID API retry successful"
                update_state "gemini_completed" "output_file=$TMP_DIR/gemini_output.log;retry=paid_api"
                # Restore original mode
                PROCESSING_MODE="${original_processing_mode}"
            else
                log_with_timestamp "❌ PAID API retry also failed"
                PROCESSING_MODE="${original_processing_mode}"
                handle_api_error "Gemini" "realtime processing with PAID API fallback" "Both APIs failed"
            fi
        else
            handle_api_error "Gemini" "realtime processing" "API processing failed"
        fi
        ;;
        
    "BATCH")
        log_with_timestamp "Processing in batch mode"
        
        if process_with_gemini_batch "$prompt" "$TMP_DIR/gemini_output.log"; then
            log_with_timestamp "Gemini batch processing completed successfully"
            update_state "gemini_completed" "output_file=$TMP_DIR/gemini_output.log"
        else
            handle_api_error "Gemini" "batch processing" "Batch processing failed"
        fi
        ;;
    esac
}

# Stage 7: Finalize and save results
finalize_and_save_results() {
    local source_value="$1"
    
    # Post-process Gemini output to ensure YAML frontmatter and get title
    local gemini_file="$TMP_DIR/gemini_output.log"
    
    local title
    title=$(ensure_yaml_frontmatter "$gemini_file" "$source_value" 2>/dev/null || echo "")
    
    
    log_with_timestamp "Processing completed, saving files with title: $title"
    update_state "saving_files" "title=$title"
    
    # Save files and get paths
    local save_result
    save_result=$(save_files "$title" "$VAULT_DIR" "$TMP_DIR" "$PDF_URL")
    
    local markdown_file=$(echo "$save_result" | cut -d'|' -f1)
    local pdf_target=$(echo "$save_result" | cut -d'|' -f2)
    
    log_with_timestamp "Files saved successfully"
    log_with_timestamp "Markdown: $markdown_file"
    log_with_timestamp "PDF: $pdf_target"
    
    # Return file info for notifications
    echo "$title|$markdown_file|$pdf_target"
}


# Stage 8: Send completion notifications
send_completion_notifications() {
    local thread_ts="$1"
    local title="$2"
    local markdown_file="$3"
    local pdf_target="$4"
    
    # Calculate processing duration
    local processing_duration=$(calculate_processing_duration "$START_TIME")
    
    # Send completion notification with token info
    log_with_timestamp "Sending completion notification to Slack"
    send_slack_notification "success" "$PDF_URL" "$title" "$markdown_file" "" "$thread_ts" "$processing_duration" "${TOKEN_INFO:-0,0,0,0}"
    
    update_state "completed" "markdown_file=$(basename "$markdown_file");pdf_file=$(basename "$pdf_target");processing_time=$processing_duration"
    
    
    log_with_timestamp "Processing pipeline completed successfully"
    log_with_timestamp "Processing time: $processing_duration"
    log_with_timestamp "=========================================="
}

# Batch processing function
process_batch() {
    local scan_dir="$1"
    local category="$2"
    
    # Initialize batch start time
    START_TIME=$(date +%s)
    
    log_with_timestamp "Starting batch processing in directory: $scan_dir"
    
    # Load environment to get MAX_PARALLEL_JOBS
    load_environment
    
    # Check for unprocessed directory first
    local unprocessed_dir="$scan_dir/unprocessed"
    local pdf_files=()
    
    if [ -d "$unprocessed_dir" ]; then
    log_with_timestamp "Processing files from unprocessed directory: $unprocessed_dir"
    # Build array of PDF files to avoid xargs command line length issues
    while IFS= read -r -d '' pdf_file; do
        pdf_files+=("$pdf_file")
    done < <(find "$unprocessed_dir" -name "*.pdf" -type f -print0)
    else
    log_with_timestamp "No unprocessed directory found, processing all PDFs in: $scan_dir"
    # Build array for main directory processing
    while IFS= read -r -d '' pdf_file; do
        pdf_files+=("$pdf_file")
    done < <(find "$scan_dir" -name "*.pdf" -type f -print0)
    fi
    
    # Process files with proper parallel job control
    if [ ${#pdf_files[@]} -gt 0 ]; then
    log_with_timestamp "Found ${#pdf_files[@]} PDF files to process"
    
    for pdf_file in "${pdf_files[@]}"; do
        log_with_timestamp "Starting processing for: $pdf_file"
        # Execute in background to maintain parallel processing
        "$0" "$pdf_file" "$category" &
        
        # Simple job control to limit concurrent processes
        while [ "$(jobs -r | wc -l)" -ge "${MAX_PARALLEL_JOBS:-5}" ]; do
            sleep 1
        done
    done
    
    # Wait for all background jobs to complete
    log_with_timestamp "Waiting for all background processes to complete..."
    wait
    else
    log_with_timestamp "No PDF files found to process"
    fi
    
    log_with_timestamp "Batch processing completed"
    
    # Send batch completion notification to Slack
    local processed_count=${#pdf_files[@]}
    local batch_summary="Processed $processed_count PDF files from $(basename "$scan_dir")"
    local processing_duration=$(calculate_processing_duration "$START_TIME")
    send_slack_notification "success" "$scan_dir" "Batch Processing Complete" "$batch_summary" "" "" "$processing_duration" "0,0,0,0"
}

# Main execution function
main() {
    # Parse arguments first to determine processing mode
    if ! parse_arguments "$@"; then
    exit 1
    fi
    
    # Check if running in batch mode
    if [[ "${BATCH_MODE:-false}" == "true" ]]; then
    process_batch "$SCAN_DIR" "$PRIMARY_TAG"
    return 0
    fi
    
    # Single file processing (original pipeline)
    # Stage 1: Initialize processing environment (skip argument parsing since already done)
    initialize_processing
    
    # Stage 2: Setup and validate environment
    setup_and_validate_environment
    
    # Stage 3: Handle PDF acquisition and initial notifications
    local acquisition_result=$(handle_pdf_acquisition)
    local thread_ts="${acquisition_result%|*}"
    local returned_dpi="${acquisition_result#*|}"
    
    # Set PDF_DPI in main shell (fixes subshell scope issue)
    PDF_DPI="$returned_dpi"
    
    # Stage 4: Convert and prepare images
    convert_and_prepare_images
    
    # Stage 5: Process with AI API (prepare source value and generate prompt)
    local source_value=$(process_with_ai_api)
    
    # Generate prompt to temporary file to avoid shell variable limitation
    local prompt_file=$(generate_temp_filename "prompt" "txt")
    
    # Generate prompt using the dedicated function
    generate_ocr_prompt "$source_value" > "$prompt_file"
    
    # Stage 6: Determine API mode based on payload size
    log_with_timestamp "🔄 Starting Stage 6: Determine API mode"
    determine_api_mode_from_images
    log_with_timestamp "✅ Stage 6 completed: API mode determined"
    
    # Stage 7: Execute AI processing based on mode
    log_with_timestamp "🔄 Starting Stage 7: Execute AI processing"
    execute_ai_processing "$(cat "$prompt_file")"
    log_with_timestamp "✅ Stage 7 completed: AI processing done"
    
    # Stage 7: Finalize and save results
    local result_info=$(finalize_and_save_results "$source_value")
    local title=$(echo "$result_info" | cut -d'|' -f1)
    local markdown_file=$(echo "$result_info" | cut -d'|' -f2)
    local pdf_target=$(echo "$result_info" | cut -d'|' -f3)
    
    # Stage 8: Send completion notifications
    send_completion_notifications "$thread_ts" "$title" "$markdown_file" "$pdf_target"
}

# File API Implementation Functions


# Upload file to File API and return file URI
upload_file_to_file_api() {
    local file_path="$1"
    local mime_type="${2:-application/octet-stream}"
    
    if [ ! -f "$file_path" ]; then
    log_with_timestamp "ERROR: File not found: $file_path"
    return 1
    fi
    
    # Get appropriate API key based on current processing mode
    local api_key
    if [ "${PROCESSING_MODE:-}" = "REALTIME" ]; then
    api_key=$(grep "AI_API_KEY_FREE=" "$VAULT_DIR/.env" 2>/dev/null | sed 's/^AI_API_KEY_FREE=//' | sed 's/ # .*//')
    else
    api_key=$(grep "AI_API_KEY_PAID=" "$VAULT_DIR/.env" 2>/dev/null | sed 's/^AI_API_KEY_PAID=//' | sed 's/ # .*//')
    # Fallback to free if paid not available
    if [ -z "$api_key" ]; then
        api_key=$(grep "AI_API_KEY_FREE=" "$VAULT_DIR/.env" 2>/dev/null | sed 's/^AI_API_KEY_FREE=//' | sed 's/ # .*//')
    fi
    fi
    
    if [ -z "$api_key" ]; then
    log_with_timestamp "ERROR: No API key available for File API"
    return 1
    fi
    
    log_with_timestamp "Uploading file to File API: $(basename "$file_path")"
    log_with_timestamp "File size: $(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null) bytes"
    
    local response_file=$(generate_temp_filename "file_upload" "json")
    local curl_log_file=$(generate_temp_filename "curl_debug" "log")
    
    local start_time=$(date +%s.%N)
    local curl_exit_code=0
    
    if curl -v --max-time 30 -s -X POST \
    "https://generativelanguage.googleapis.com/upload/v1beta/files?key=$api_key" \
    -H "Content-Type: $mime_type" \
    --data-binary "@$file_path" \
    -o "$response_file" 2>"$curl_log_file"; then
        curl_exit_code=0
    else
        curl_exit_code=$?
    fi
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "unknown")
    
    if [ $curl_exit_code -eq 0 ]; then
        log_with_timestamp "File upload successful (${duration}s)"
        
        # Extract file URI from response (Gemini File API returns 'uri' field for generateContent)
        local file_uri=$(grep -o '"uri": "[^"]*"' "$response_file" | sed 's/"uri": "//' | sed 's/"//')
        
        if [ -n "$file_uri" ]; then
            log_with_timestamp "File uploaded successfully: $file_uri"
            echo "$file_uri"
            rm -f "$response_file" "$curl_log_file"
            return 0
        else
            log_with_timestamp "ERROR: Failed to extract file URI from response (${duration}s)"
            log_with_timestamp "Response content: $(cat "$response_file" 2>/dev/null | head -5)"
            log_with_timestamp "Curl debug: $(cat "$curl_log_file" 2>/dev/null | tail -10)"
            rm -f "$response_file" "$curl_log_file"
            return 1
        fi
    else
        log_with_timestamp "ERROR: File API upload failed (exit: $curl_exit_code, ${duration}s)"
        if [ -f "$response_file" ]; then
            log_with_timestamp "Error response: $(cat "$response_file" 2>/dev/null | head -5)"
        fi
        if [ -f "$curl_log_file" ]; then
            log_with_timestamp "Curl debug log: $(cat "$curl_log_file" 2>/dev/null | tail -10)"
        fi
        rm -f "$response_file" "$curl_log_file"
        return 1
    fi
}

# Generate JSON payload for File API
generate_file_api_payload() {
    local file_uri="$1" 
    local mime_type="$2"
    local prompt="$3"
    
    echo "{
    \"contents\": [{
        \"parts\": [
            {\"text\": \"$prompt\"},
            {
                \"fileData\": {
                    \"mimeType\": \"$mime_type\",
                    \"fileUri\": \"$file_uri\"
                }
            }
        ]
    }],
    \"generationConfig\": {\"temperature\": ${TEMPERATURE:-0.1}}
    }"
}



# Only run main if script is executed directly (not sourced)
if [ "$(basename "$0")" = "background_ocrPDF.sh" ]; then
    main "$@"
fi
