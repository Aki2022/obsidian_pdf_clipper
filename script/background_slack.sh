#!/bin/bash
# Slack module for background processing - TDD implementation

# Check if Slack is properly configured
is_slack_configured() {
    [ "${SLACK_PROJECT_NOTIFICATIONS:-true}" = "true" ] && \
    [ -n "${SLACK_BOT_TOKEN:-}" ] && \
    [ -n "${SLACK_REPORT_CHANNEL:-}" ]
}

# Format token cost for display
# Input: input_tokens, output_tokens, thoughts_tokens 
# Output: formatted cost string like "$0.012(i$0.001+t$0.002+o$0.009: total 184 tkn)"
format_token_cost() {
    local input_tokens="${1:-0}"
    local output_tokens="${2:-0}"
    local thoughts_tokens="${3:-0}"
    local total_tokens=$((input_tokens + output_tokens + thoughts_tokens))
    
    # Calculate costs (using bc for decimal arithmetic)
    local input_cost=$(echo "scale=6; $input_tokens * ${GEMINI_INPUT_COST_PER_1K:-0.0025} / 1000" | bc)
    local output_cost=$(echo "scale=6; $output_tokens * ${GEMINI_OUTPUT_COST_PER_1K:-0.015} / 1000" | bc)
    local thoughts_cost=$(echo "scale=6; $thoughts_tokens * ${GEMINI_THOUGHTS_COST_PER_1K:-0.0025} / 1000" | bc)
    local total_cost=$(echo "scale=6; $input_cost + $output_cost + $thoughts_cost" | bc)
    
    # Format display with 3 decimal places
    local i_display=$(printf "%.3f" "$input_cost")
    local o_display=$(printf "%.3f" "$output_cost")
    local t_display=$(printf "%.3f" "$thoughts_cost")
    local total_display=$(printf "%.3f" "$total_cost")
    
    echo "\$${total_display}(i\$${i_display}+t\$${t_display}+o\$${o_display}: total ${total_tokens} tkn)"
}

create_slack_start_payload() {
    local pdf_url="$1"
    local batch_id="$2"
    local mode="$3"
    local channel="$4"
    local user_id="$5"
    
    local user_mention="<@${user_id}>"
    local message_text="$user_mention 🚀 PDF OCR処理 - 開始"
    local pdf_source_label=$([ "${IS_URL:-false}" = true ] && echo "URL" || echo "PDF")
    local attachment_text="• *$pdf_source_label*: $pdf_url"
    
    echo "{
        \"channel\": \"$channel\",
        \"text\": \"$message_text\",
        \"attachments\": [{
            \"color\": \"#36a64f\",
            \"text\": \"$attachment_text\",
            \"footer\": \"Obsidian PDF Clipper\",
            \"ts\": $(date +%s)
        }]
    }"
}

send_slack_start_notification() {
    local pdf_url="$1"
    local batch_id="$2"
    local mode="$3"
    
    # Graceful degradation - return early if Slack config not available
    if ! is_slack_configured; then
        return 0
    fi
    
    # Only proceed if we have the required configuration
    local payload=$(create_slack_start_payload "$pdf_url" "$batch_id" "$mode" "$SLACK_REPORT_CHANNEL" "${SLACK_MENTION_USER_ID:-}")
    
    
    # Real Slack API implementation
    local response=$(curl -s -X POST \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "https://slack.com/api/chat.postMessage")
    
    # Parse Slack API response using jq with proper error handling
    local is_ok=$(echo "$response" | jq -r '.ok // false' 2>/dev/null)
    
    if [ "$is_ok" = "true" ]; then
        local thread_ts=$(echo "$response" | jq -r '.ts // empty' 2>/dev/null)
        
        if [ -n "$thread_ts" ] && [ "$thread_ts" != "null" ] && [ "$thread_ts" != "Error:"* ]; then
            # Save thread timestamp if save_thread_ts function exists
            if command -v save_thread_ts >/dev/null 2>&1; then
                save_thread_ts "$thread_ts"
            fi
            # Log if log_with_timestamp function exists
            if command -v log_with_timestamp >/dev/null 2>&1; then
                log_with_timestamp "Start notification sent successfully. Thread TS: $thread_ts"
            fi
            echo "$thread_ts"
        else
            if command -v log_with_timestamp >/dev/null 2>&1; then
                log_with_timestamp "Failed to extract thread timestamp"
            fi
        fi
    else
        local error_msg=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
        if [ -n "$error_msg" ]; then
            if command -v log_with_timestamp >/dev/null 2>&1; then
                log_with_timestamp "Slack API error: $error_msg"
            fi
        else
            if command -v log_with_timestamp >/dev/null 2>&1; then
                log_with_timestamp "Slack API failed with unknown error"
            fi
        fi
    fi
}

create_slack_simple_payload() {
    local status="$1"
    local pdf_url="$2"
    local title="$3"
    local markdown_file="$4"
    local error_msg="$5"
    local channel="$6"
    local user_id="$7"
    local thread_ts="$8"
    local processing_duration="$9"
    local token_info="${10:-0,0,0,0}"  # input,output,thoughts,total
    
    local user_mention="<@${user_id}>"
    
    # Parse token info
    IFS=',' read -r input_tokens output_tokens thoughts_tokens total_tokens <<< "$token_info"
    
    # Generate cost display
    local cost_display=$(format_token_cost "$input_tokens" "$output_tokens" "$thoughts_tokens")
    
    # Generate API info display
    local processing_mode="${PROCESSING_MODE:-UNKNOWN}"
    local api_info=""
    case "$processing_mode" in
        "REALTIME")
            api_info="🆓 Free API / REALTIME mode"
            ;;
        "BATCH")
            api_info="💰 Paid API / BATCH mode"
            ;;
        "AUTO")
            api_info="🔄 Auto-detecting API mode"
            ;;
        *)
            api_info="❓ Unknown mode"
            ;;
    esac
    
    local base_payload=""
    if [ -n "$thread_ts" ]; then
        base_payload="\"thread_ts\": \"$thread_ts\","
    fi
    
    if [ "$status" = "success" ]; then
        local color="good"
        local status_emoji="✅"
        local status_text="成功"
        local markdown_basename=$(basename "$markdown_file")
        local message_text="$user_mention $status_emoji PDF OCR処理 - $status_text"
        local pdf_source_label=$([ "${IS_URL:-false}" = true ] && echo "URL" || echo "PDF")
        local display_source=$([ "${IS_URL:-false}" = true ] && echo "$pdf_url" || basename "$pdf_url")
        local attachment_text="• *$pdf_source_label*: $display_source\\n• *md*: $markdown_basename\\n• *API*: $api_info\\n• *cost*: $cost_display\\n• *time*: $processing_duration"
    else
        local color="danger"
        local status_emoji="❌"
        local status_text="失敗"
        local message_text="$user_mention $status_emoji PDF OCR処理 - $status_text"
        local pdf_source_label=$([ "${IS_URL:-false}" = true ] && echo "URL" || echo "PDF")
        local display_source=$([ "${IS_URL:-false}" = true ] && echo "$pdf_url" || basename "$pdf_url")
        local attachment_text="• *$pdf_source_label*: $display_source\\n• *message*: $error_msg\\n• *API*: $api_info\\n• *cost*: $cost_display\\n• *time*: $processing_duration"
    fi
    
    echo "{
        \"channel\": \"$channel\",
        $base_payload
        \"text\": \"$message_text\",
        \"attachments\": [{
            \"color\": \"$color\",
            \"text\": \"$attachment_text\",
            \"footer\": \"Obsidian PDF Clipper\",
            \"ts\": $(date +%s)
        }]
    }"
}

send_slack_notification() {
    local status="$1"
    local pdf_url="$2"
    local title="$3"
    local markdown_file="$4"
    local error_msg="$5"
    local thread_ts="$6"
    local processing_duration="$7"
    local token_info="${8:-0,0,0,0}"  # input,output,thoughts,total
    
    # Graceful degradation - return early if Slack config not available
    if ! is_slack_configured; then
        return 0
    fi
    
    # Simple notification for vector.sh operations
    if [[ "$pdf_url" == vector.sh* ]]; then
        local user_mention="<@${SLACK_MENTION_USER_ID:-}>"
        local status_icon=""
        
        if [ "$status" = "success" ]; then
            status_icon="✅"
        elif [ "$status" = "failed" ]; then
            status_icon="❌"
        fi
        
        local message_text="$user_mention $status_icon : $pdf_url $status"
        
        local simple_payload="{
            \"channel\": \"$SLACK_REPORT_CHANNEL\",
            \"text\": \"$message_text\"
        }"
        
        curl -s -X POST \
            -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$simple_payload" \
            "https://slack.com/api/chat.postMessage" >/dev/null 2>&1
        
        if command -v log_with_timestamp >/dev/null 2>&1; then
            log_with_timestamp "Simple vector notification sent: $message_text"
        fi
        return 0
    fi
    
    # Original complex notification for PDF processing
    local payload=$(create_slack_simple_payload "$status" "$pdf_url" "$title" "$markdown_file" "$error_msg" "$SLACK_REPORT_CHANNEL" "${SLACK_MENTION_USER_ID:-}" "$thread_ts" "$processing_duration" "$token_info")
    
    
    # Real Slack API implementation - Debug enabled
    local response=$(curl -s -X POST \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "https://slack.com/api/chat.postMessage")
    
    # Log API response for debugging
    if command -v log_with_timestamp >/dev/null 2>&1; then
        if echo "$response" | grep -q '"ok":true'; then
            log_with_timestamp "✅ Slack API success"
        else
            log_with_timestamp "❌ Slack API error: $(echo "$response" | head -100)"
        fi
    fi
    
    # Log completion if log_with_timestamp function exists
    if command -v log_with_timestamp >/dev/null 2>&1; then
        log_with_timestamp "Completion notification sent (thread: ${thread_ts:-none})"
    fi
}