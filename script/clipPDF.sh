#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title clipPDF
# @raycast.mode silent
# @raycast.icon 🤖
# @raycast.argument1 { "type": "text", "placeholder": "PDF URL or Path" }
# @raycast.argument2 { "type": "dropdown", "placeholder": "default: paper", "optional": true, "data": [{"title": "Paper", "value": "paper"}, {"title": "Clip", "value": "clip"}] }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# DEBUG: Log Raycast execution context
DEBUG_LOG="/tmp/raycast_clipPDF_debug.log"
{
    echo "=== Raycast clipPDF Debug $(date) ==="
    echo "PWD: $(pwd)"
    echo "BASH_SOURCE[0]: ${BASH_SOURCE[0]}"
    echo "SCRIPT_DIR: $SCRIPT_DIR" 
    echo "background_ocrPDF.sh exists: $([ -f "$SCRIPT_DIR/background_ocrPDF.sh" ] && echo "YES" || echo "NO")"
    echo "Args: $1 ${2:-paper}"
    echo
} >> "$DEBUG_LOG"

nohup "$SCRIPT_DIR/background_ocrPDF.sh" "$1" "${2:-paper}" > /tmp/clipPDF_debug.log 2>&1 &
# Silent mode - no echo output