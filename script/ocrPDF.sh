#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title ocrPDF
# @raycast.mode silent
# @raycast.icon 🤖
# @raycast.argument1 { "type": "text", "placeholder": "PDF URL, Path, or Directory (optional)", "optional": true }
# @raycast.argument2 { "type": "dropdown", "placeholder": "Category (optional)", "optional": true, "data": [{"title": "Clip", "value": "clip"}, {"title": "Scan", "value": "scan"}, {"title": "Paper", "value": "paper"}] }

# ocrPDF.sh - Unified PDF OCR Frontend
# TDD Implementation following t-wada methodology

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VAULT_DIR="$PROJECT_ROOT"

# Debug logging
DEBUG_LOG="/tmp/raycast_ocrPDF_debug.log"

# Logging function
log_debug() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$DEBUG_LOG"
}

# Show usage information
show_usage() {
    cat << 'EOF'
ocrPDF.sh - Unified PDF OCR Frontend

DESCRIPTION:
    Unified frontend for PDF OCR processing with automatic mode detection.
    Supports URL, file, and directory inputs with category specification.

USAGE:
    ./ocrPDF.sh [INPUT] [CATEGORY]
    ./ocrPDF.sh --help | -h

ARGUMENTS:
    INPUT               URL, file path, or directory (optional)
                       - No input: Scan mode with default directory
                       - URL: http://... or https://... → Clip mode
                       - File: /path/to/file.pdf → Clip mode  
                       - Directory: /path/to/dir/ → Scan mode
    CATEGORY           Optional: clip, scan, paper (default: auto-detected)

EXAMPLES:
    # Scan mode (no arguments)
    ./ocrPDF.sh
    
    # Process single PDF from URL
    ./ocrPDF.sh "https://example.com/paper.pdf" paper
    
    # Process local PDF file
    ./ocrPDF.sh "/path/to/document.pdf" scan
    
    # Batch process directory
    ./ocrPDF.sh "/scan/directory" scan
EOF
}

# Parse arguments with auto-detection
parse_arguments_new() {
    log_debug "=== parse_arguments_new called with $# arguments: $*"
    
    # Check for help option first
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        show_usage
        exit 0
    fi
    
    # Handle no arguments or empty first argument - default to scan mode
    if [ $# -eq 0 ] || [ -z "${1:-}" ]; then
        log_debug "No arguments or empty first argument - defaulting to scan mode"
        export INPUT_TYPE="SCAN_DEFAULT"
        export INPUT_VALUE=""
        # Use second argument as category if provided, otherwise default to scan
        export CATEGORY="${2:-scan}"
        export BATCH_MODE=true
        return 0
    fi
    
    # Validate argument count (1 or 2 arguments)
    if [ $# -gt 2 ]; then
        echo "Error: Too many arguments. Expected 1 or 2 arguments: [INPUT] [CATEGORY]" >&2
        echo "Usage: $0 [URL|FILE|DIR] [clip|scan|paper]" >&2
        return 1
    fi
    
    local input="$1"
    local category="${2:-}"
    
    log_debug "Input: '$input', Category: '$category'"
    
    # Auto-detect input type and set appropriate mode
    if [ -d "$input" ]; then
        # Directory → Batch processing (scan mode)
        export INPUT_TYPE="DIRECTORY"
        export INPUT_VALUE="$input"
        export CATEGORY="${category:-scan}"
        export BATCH_MODE=true
        log_debug "Directory detected - Batch mode: $input (category: ${CATEGORY})"
        
    elif echo "$input" | grep -q '^https\?://'; then
        # URL → Single processing (clip mode)
        export INPUT_TYPE="URL"
        export INPUT_VALUE="$input"
        export CATEGORY="${category:-clip}"
        export BATCH_MODE=false
        log_debug "URL detected - Single mode: $input (category: ${CATEGORY})"
        
    elif [ -f "$input" ]; then
        # File → Single processing (clip mode)
        export INPUT_TYPE="FILE"
        export INPUT_VALUE="$input"
        export CATEGORY="${category:-clip}"
        export BATCH_MODE=false
        log_debug "File detected - Single mode: $input (category: ${CATEGORY})"
        
    else
        echo "Error: Invalid input - not a valid URL, existing file, or directory: $input" >&2
        return 1
    fi
    
    log_debug "Input parsing completed: $input (category: ${CATEGORY}, type: ${INPUT_TYPE})"
    return 0
}

# Validate configuration
validate_environment() {
    log_debug "Validating environment..."
    
    # Use proven original background processor for stability
    local background_script="$SCRIPT_DIR/background_ocrPDF.sh"
    if [ ! -f "$background_script" ]; then
        echo "Error: Background processor not found at $background_script" >&2
        return 1
    fi
    log_debug "Using original background processor: $background_script"
    
    export BACKGROUND_SCRIPT="$background_script"
    log_debug "Background script: $BACKGROUND_SCRIPT"
    
    # Check .env file exists
    if [ ! -f "$VAULT_DIR/.env" ]; then
        echo "Error: Environment file not found: $VAULT_DIR/.env" >&2
        return 1
    fi
    
    log_debug "Environment validation completed"
    return 0
}

# Prepare arguments for background processor
prepare_background_args() {
    local args=()
    
    case "${INPUT_TYPE:-}" in
        "SCAN_DEFAULT")
            # For default scan mode, add the unprocessed directory path
            args+=("$VAULT_DIR/vault/scan/unprocessed")
            ;;
        "DIRECTORY"|"URL"|"FILE")
            args+=("$INPUT_VALUE")
            ;;
        *)
            echo "Error: Unknown input type: ${INPUT_TYPE:-}" >&2
            return 1
            ;;
    esac
    
    # Add category if specified
    if [ -n "${CATEGORY:-}" ]; then
        args+=("$CATEGORY")
    fi
    
    # Return arguments as space-separated string
    printf '%s ' "${args[@]}"
}

# Main execution function
main() {
    log_debug "=== ocrPDF.sh started with $# arguments: $*"
    
    # Parse arguments
    if ! parse_arguments_new "$@"; then
        log_debug "Argument parsing failed"
        exit 1
    fi
    
    # Validate environment
    if ! validate_environment; then
        log_debug "Environment validation failed"
        exit 1
    fi
    
    # Prepare arguments for background processor using array
    local -a bg_args_array
    case "${INPUT_TYPE:-}" in
        "SCAN_DEFAULT")
            bg_args_array=("$VAULT_DIR/vault/scan/unprocessed")
            ;;
        "DIRECTORY"|"URL"|"FILE")
            bg_args_array=("$INPUT_VALUE")
            ;;
        *)
            echo "Error: Unknown input type: ${INPUT_TYPE:-}" >&2
            exit 1
            ;;
    esac
    
    # Add category if specified
    if [ -n "${CATEGORY:-}" ]; then
        bg_args_array+=("$CATEGORY")
    fi
    
    log_debug "Background arguments: ${bg_args_array[*]}"
    
    # Execute background processor with nohup for Raycast compatibility
    log_debug "Executing: nohup $BACKGROUND_SCRIPT ${bg_args_array[*]}"
    
    if [ ${#bg_args_array[@]} -gt 0 ]; then
        nohup "$BACKGROUND_SCRIPT" "${bg_args_array[@]}" > /tmp/ocrPDF_output.log 2>&1 &
    else
        nohup "$BACKGROUND_SCRIPT" > /tmp/ocrPDF_output.log 2>&1 &
    fi
    
    local bg_pid=$!
    log_debug "Background processor started with PID: $bg_pid"
    
    # Silent mode - no output for Raycast
    exit 0
}

# Only run main if script is executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi