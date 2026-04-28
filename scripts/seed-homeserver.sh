#!/usr/bin/env bash
# seed-homeserver.sh — Spin up a local Matrix homeserver and populate it with
# realistic data for taking Relay screenshots and promotional material.
#
# The script creates a continuwuity (Matrix) homeserver inside a container,
# then seeds it with users, spaces, rooms, and messages that look like the
# internal chat instance of a fictional software company called "Pebble".
#
# Prerequisites: a container runtime (docker/podman), curl, jq
#
# Usage:
#   ./scripts/seed-homeserver.sh
#
# Supports Docker, Podman, or any OCI-compatible runtime.
# Override with:  CONTAINER_RUNTIME=podman ./scripts/seed-homeserver.sh

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

CONTAINER_NAME="relay-homeserver"
VOLUME_NAME="relay-homeserver-data"
IMAGE="ghcr.io/continuwuity/continuwuity:latest"
SERVER_NAME="pebble.dev"
SERVER_URL="http://localhost:8008"
PASSWORD="pebble123"
REGISTRATION_TOKEN="seed-token"
SCREENSHOT_USER="alex"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="${SCRIPT_DIR}/profiles"

# Detect container runtime
if [[ -n "${CONTAINER_RUNTIME:-}" ]]; then
    RUNTIME="$CONTAINER_RUNTIME"
elif command -v container &> /dev/null; then
    RUNTIME="container"
elif command -v docker &>/dev/null; then
    RUNTIME="docker"
elif command -v podman &>/dev/null; then
    RUNTIME="podman"
else
    echo "Error: No container runtime found. Install Docker or Podman."
    exit 1
fi

# Transaction ID counter (for idempotent message sends)
TXN_ID=0

# Associative arrays for tokens, room IDs, and display names
declare -A TOKENS
declare -A ROOMS
declare -A SPACES
declare -A DISPLAY_NAMES

# User definitions: username|display_name
USERS=(
    "morgan|Morgan Torres"
    "priya|Priya Sharma"
    "alex|Alex Kim"
    "jordan|Jordan Lee"
    "sam|Sam Nakamura"
    "riley|Riley Chen"
    "casey|Casey Brooks"
    "taylor|Taylor Okafor"
)

# =============================================================================
# Helper Functions
# =============================================================================

step() {
    local step_num="$1"
    local total="$2"
    local label="$3"
    printf "\r  [%s/%s] %-40s" "$step_num" "$total" "$label"
}

step_done() {
    printf "done\n"
}

next_txn() {
    TXN_ID=$((TXN_ID + 1))
    # Return value via a variable instead of echo, because $(next_txn) would
    # run in a subshell and the TXN_ID increment would be lost.
    NEXT_TXN_RESULT="txn_${TXN_ID}"
}

# Register a user and store the access token.
# Continuwuity requires the m.login.registration_token auth flow: first call
# without auth to obtain a session, then call again with the token.
# Usage: register_user <username> <password> <registration_token>
register_user() {
    local username="$1"
    local password="$2"
    local reg_token="$3"

    # Step 1: Initiate registration to get a session ID.
    local init_response
    init_response=$(curl -s -X POST "${SERVER_URL}/_matrix/client/v3/register" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"${username}\",
            \"password\": \"${password}\",
            \"inhibit_login\": false
        }")

    local session
    session=$(echo "$init_response" | jq -r '.session // empty')
    if [[ -z "$session" ]]; then
        echo ""
        echo "Error: Failed to initiate registration for '${username}'."
        echo "Response: ${init_response}"
        exit 1
    fi

    # Step 2: Complete registration with the registration token.
    local response
    response=$(curl -s -X POST "${SERVER_URL}/_matrix/client/v3/register" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"${username}\",
            \"password\": \"${password}\",
            \"auth\": {
                \"type\": \"m.login.registration_token\",
                \"token\": \"${reg_token}\",
                \"session\": \"${session}\"
            },
            \"inhibit_login\": false
        }")

    local token
    token=$(echo "$response" | jq -r '.access_token // empty')
    if [[ -z "$token" ]]; then
        echo ""
        echo "Error: Failed to register user '${username}'."
        echo "Response: ${response}"
        exit 1
    fi

    TOKENS["$username"]="$token"
}

# Set a user's display name.
# Usage: set_displayname <username> <display_name>
set_displayname() {
    local username="$1"
    local display_name="$2"
    local token="${TOKENS[$username]}"

    curl -s -X PUT "${SERVER_URL}/_matrix/client/v3/profile/@${username}:${SERVER_NAME}/displayname" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"displayname\": \"${display_name}\"}" >/dev/null
}

# Upload a local avatar image and set it on the user's profile.
# Looks for <username>.png or <username>.jpg in PROFILES_DIR.
# Usage: set_avatar <username>
set_avatar() {
    local username="$1"
    local token="${TOKENS[$username]}"

    # Find the avatar file (try common extensions)
    local avatar_file=""
    local content_type=""
    for ext in png jpg jpeg webp; do
        if [[ -f "${PROFILES_DIR}/${username}.${ext}" ]]; then
            avatar_file="${PROFILES_DIR}/${username}.${ext}"
            case "$ext" in
                png)          content_type="image/png" ;;
                jpg|jpeg)     content_type="image/jpeg" ;;
                webp)         content_type="image/webp" ;;
            esac
            break
        fi
    done

    if [[ -z "$avatar_file" ]]; then
        return 0  # No avatar file found; skip silently
    fi

    # Upload to homeserver
    local upload_response
    upload_response=$(curl -s -X POST "${SERVER_URL}/_matrix/media/v3/upload?filename=$(basename "$avatar_file")" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: ${content_type}" \
        --data-binary "@${avatar_file}")

    local content_uri
    content_uri=$(echo "$upload_response" | jq -r '.content_uri // empty')
    if [[ -z "$content_uri" ]]; then
        return 0  # Non-fatal: skip avatar
    fi

    # Set avatar URL on profile
    curl -s -X PUT "${SERVER_URL}/_matrix/client/v3/profile/@${username}:${SERVER_NAME}/avatar_url" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"avatar_url\": \"${content_uri}\"}" >/dev/null
}

# Create a room and store its ID.
# Usage: create_room <key> <creator_username> <name> <topic> [preset]
create_room() {
    local key="$1"
    local creator="$2"
    local name="$3"
    local topic="$4"
    local preset="${5:-private_chat}"
    local token="${TOKENS[$creator]}"
    local alias
    alias=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

    local response
    response=$(curl -s -X POST "${SERVER_URL}/_matrix/client/v3/createRoom" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"${name}\",
            \"topic\": \"${topic}\",
            \"room_alias_name\": \"${alias}\",
            \"preset\": \"${preset}\",
            \"visibility\": \"private\",
            \"initial_state\": [
                {
                    \"type\": \"m.room.history_visibility\",
                    \"content\": {\"history_visibility\": \"shared\"},
                    \"state_key\": \"\"
                }
            ]
        }")

    local room_id
    room_id=$(echo "$response" | jq -r '.room_id // empty')
    if [[ -z "$room_id" ]]; then
        echo ""
        echo "Error: Failed to create room '${name}'."
        echo "Response: ${response}"
        exit 1
    fi

    ROOMS["$key"]="$room_id"
}

# Create a space (a room with m.space type) and store its ID.
# Usage: create_space <key> <creator_username> <name> <topic>
create_space() {
    local key="$1"
    local creator="$2"
    local name="$3"
    local topic="$4"
    local token="${TOKENS[$creator]}"
    local alias
    alias="space-$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"

    local response
    response=$(curl -s -X POST "${SERVER_URL}/_matrix/client/v3/createRoom" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"${name}\",
            \"topic\": \"${topic}\",
            \"room_alias_name\": \"${alias}\",
            \"creation_content\": {\"type\": \"m.space\"},
            \"preset\": \"private_chat\",
            \"visibility\": \"private\",
            \"initial_state\": [
                {
                    \"type\": \"m.room.join_rules\",
                    \"content\": {\"join_rule\": \"invite\"},
                    \"state_key\": \"\"
                },
                {
                    \"type\": \"m.room.history_visibility\",
                    \"content\": {\"history_visibility\": \"shared\"},
                    \"state_key\": \"\"
                }
            ]
        }")

    local room_id
    room_id=$(echo "$response" | jq -r '.room_id // empty')
    if [[ -z "$room_id" ]]; then
        echo ""
        echo "Error: Failed to create space '${name}'."
        echo "Response: ${response}"
        exit 1
    fi

    SPACES["$key"]="$room_id"
}

# Create a direct message room between two users.
# Usage: create_dm <key> <creator_username> <other_username>
create_dm() {
    local key="$1"
    local creator="$2"
    local other="$3"
    local token="${TOKENS[$creator]}"

    local response
    response=$(curl -s -X POST "${SERVER_URL}/_matrix/client/v3/createRoom" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{
            \"is_direct\": true,
            \"preset\": \"trusted_private_chat\",
            \"invite\": [\"@${other}:${SERVER_NAME}\"],
            \"initial_state\": [
                {
                    \"type\": \"m.room.history_visibility\",
                    \"content\": {\"history_visibility\": \"shared\"},
                    \"state_key\": \"\"
                }
            ]
        }")

    local room_id
    room_id=$(echo "$response" | jq -r '.room_id // empty')
    if [[ -z "$room_id" ]]; then
        echo ""
        echo "Error: Failed to create DM between '${creator}' and '${other}'."
        echo "Response: ${response}"
        exit 1
    fi

    ROOMS["$key"]="$room_id"

    # Other user joins
    curl -s -X POST "${SERVER_URL}/_matrix/client/v3/join/${room_id}" \
        -H "Authorization: Bearer ${TOKENS[$other]}" \
        -H "Content-Type: application/json" \
        -d '{}' >/dev/null
}

# Invite a user to a room and have them join.
# Usage: invite_and_join <room_key> <inviter_username> <invitee_username>
# The room_key is looked up in ROOMS first, then SPACES.
invite_and_join() {
    local room_key="$1"
    local inviter="$2"
    local invitee="$3"

    local room_id="${ROOMS[$room_key]:-${SPACES[$room_key]:-}}"
    if [[ -z "$room_id" ]]; then
        echo ""
        echo "Error: Room key '${room_key}' not found."
        exit 1
    fi

    local inviter_token="${TOKENS[$inviter]}"
    local invitee_token="${TOKENS[$invitee]}"

    # Invite
    curl -s -X POST "${SERVER_URL}/_matrix/client/v3/rooms/${room_id}/invite" \
        -H "Authorization: Bearer ${inviter_token}" \
        -H "Content-Type: application/json" \
        -d "{\"user_id\": \"@${invitee}:${SERVER_NAME}\"}" >/dev/null

    # Join
    curl -s -X POST "${SERVER_URL}/_matrix/client/v3/join/${room_id}" \
        -H "Authorization: Bearer ${invitee_token}" \
        -H "Content-Type: application/json" \
        -d '{}' >/dev/null
}

# Add a child room or space to a parent space.
# Usage: add_space_child <parent_space_key> <child_key> <order> <creator_username>
# child_key is looked up in ROOMS first, then SPACES.
add_space_child() {
    local parent_key="$1"
    local child_key="$2"
    local order="$3"
    local creator="$4"

    local parent_id="${SPACES[$parent_key]}"
    local child_id="${ROOMS[$child_key]:-${SPACES[$child_key]:-}}"
    local token="${TOKENS[$creator]}"

    # Set m.space.child on parent
    curl -s -X PUT "${SERVER_URL}/_matrix/client/v3/rooms/${parent_id}/state/m.space.child/${child_id}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"via\": [\"${SERVER_NAME}\"], \"suggested\": true, \"order\": \"${order}\"}" >/dev/null

    # Set m.space.parent on child
    curl -s -X PUT "${SERVER_URL}/_matrix/client/v3/rooms/${child_id}/state/m.space.parent/${parent_id}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"via\": [\"${SERVER_NAME}\"], \"canonical\": true}" >/dev/null
}

# Promote a user to admin (power level 100) in a room.
# The caller must be the room creator (or already have sufficient power).
# Usage: promote_to_admin <room_key> <promoter_username> <target_username>
promote_to_admin() {
    local room_key="$1"
    local promoter="$2"
    local target="$3"

    local room_id="${ROOMS[$room_key]:-${SPACES[$room_key]:-}}"
    local token="${TOKENS[$promoter]}"

    # Fetch current power levels
    local current
    current=$(curl -s -X GET "${SERVER_URL}/_matrix/client/v3/rooms/${room_id}/state/m.room.power_levels" \
        -H "Authorization: Bearer ${token}")

    # Inject the target user at power level 100 and PUT back
    local updated
    updated=$(echo "$current" | jq --arg uid "@${target}:${SERVER_NAME}" '.users[$uid] = 100')

    curl -s -X PUT "${SERVER_URL}/_matrix/client/v3/rooms/${room_id}/state/m.room.power_levels" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$updated" >/dev/null
}

# Send a text message to a room.
# Usage: send_message <room_key> <sender_username> <body>
send_message() {
    local room_key="$1"
    local sender="$2"
    local body="$3"
    local room_id="${ROOMS[$room_key]:-${SPACES[$room_key]:-}}"
    local token="${TOKENS[$sender]}"
    next_txn
    local txn="$NEXT_TXN_RESULT"
    # Escape the body for JSON
    local escaped_body
    escaped_body=$(echo -n "$body" | jq -Rs '.')

    local response
    response=$(curl -s -X PUT "${SERVER_URL}/_matrix/client/v3/rooms/${room_id}/send/m.room.message/${txn}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"msgtype\": \"m.text\", \"body\": ${escaped_body}}")

    local event_id
    event_id=$(echo "$response" | jq -r '.event_id // empty')
    if [[ -z "$event_id" ]]; then
        echo ""
        echo "Warning: Failed to send message to '${room_key}' as '${sender}'"
        echo "Response: ${response}"
    fi
}

# Send a text message that mentions one or more users.
# The body should contain the mentioned user's display name where the mention
# should appear. This function adds the Matrix m.mentions structured data and
# an HTML formatted_body with proper matrix.to user pills.
# Usage: send_mention <room_key> <sender_username> <body> <mentioned_user_id> [additional_user_ids...]
send_mention() {
    local room_key="$1"
    local sender="$2"
    local body="$3"
    shift 3
    local mentioned_ids=("$@")
    local room_id="${ROOMS[$room_key]:-${SPACES[$room_key]:-}}"
    local token="${TOKENS[$sender]}"
    next_txn
    local txn="$NEXT_TXN_RESULT"

    local escaped_body
    escaped_body=$(echo -n "$body" | jq -Rs '.')

    # Build the HTML formatted_body by replacing display names with pills.
    # Start with the plain body as the base HTML.
    local html_body="$body"

    # Build the m.mentions.user_ids JSON array and replace display names with
    # pills in the HTML body.
    local user_ids_json="["
    local first=true
    for uid in "${mentioned_ids[@]}"; do
        if [[ "$first" == true ]]; then
            first=false
        else
            user_ids_json+=","
        fi
        user_ids_json+="\"${uid}\""

        # Look up the display name for this user (strip the @...:server part).
        local username="${uid#@}"
        username="${username%%:*}"
        local display_name="${DISPLAY_NAMES[$username]:-$username}"

        # Replace the display name in the HTML body with a mention pill link.
        html_body="${html_body//$display_name/<a href=\"https://matrix.to/#\/${uid}\">$display_name</a>}"
    done
    user_ids_json+="]"

    local escaped_html
    escaped_html=$(echo -n "$html_body" | jq -Rs '.')

    local response
    response=$(curl -s -X PUT "${SERVER_URL}/_matrix/client/v3/rooms/${room_id}/send/m.room.message/${txn}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"msgtype\": \"m.text\", \"body\": ${escaped_body}, \"format\": \"org.matrix.custom.html\", \"formatted_body\": ${escaped_html}, \"m.mentions\": {\"user_ids\": ${user_ids_json}}}")

    local event_id
    event_id=$(echo "$response" | jq -r '.event_id // empty')
    if [[ -z "$event_id" ]]; then
        echo ""
        echo "Warning: Failed to send mention to '${room_key}' as '${sender}'"
        echo "Response: ${response}"
    fi
}

# Send a notice (bot-style message) to a room.
# Usage: send_notice <room_key> <sender_username> <body>
send_notice() {
    local room_key="$1"
    local sender="$2"
    local body="$3"
    local room_id="${ROOMS[$room_key]:-${SPACES[$room_key]:-}}"
    local token="${TOKENS[$sender]}"
    next_txn
    local txn="$NEXT_TXN_RESULT"

    local escaped_body
    escaped_body=$(echo -n "$body" | jq -Rs '.')

    local response
    response=$(curl -s -X PUT "${SERVER_URL}/_matrix/client/v3/rooms/${room_id}/send/m.room.message/${txn}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"msgtype\": \"m.notice\", \"body\": ${escaped_body}}")

    local event_id
    event_id=$(echo "$response" | jq -r '.event_id // empty')
    if [[ -z "$event_id" ]]; then
        echo ""
        echo "Warning: Failed to send notice to '${room_key}' as '${sender}'"
        echo "Response: ${response}"
    fi
}

# Wait for the homeserver to become available.
# Usage: wait_for_server
wait_for_server() {
    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s -o /dev/null -w "%{http_code}" "${SERVER_URL}/_matrix/client/versions" 2>/dev/null | grep -q "200"; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo ""
    echo "Error: Homeserver did not become available within ${max_attempts} seconds."
    exit 1
}

# Extract the one-time bootstrap registration token from the container logs.
# Continuwuity generates this on first start; the configured registration_token
# only activates after the first account is created with the bootstrap token.
# Usage: get_bootstrap_token
get_bootstrap_token() {
    local max_attempts=10
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        local token
        token=$("$RUNTIME" logs "$CONTAINER_NAME" 2>&1 \
            | sed 's/\x1b\[[0-9;]*m//g' \
            | grep -o 'registration token [^ ]*' \
            | head -1 \
            | awk '{print $NF}')
        if [[ -n "$token" ]]; then
            echo "$token"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo ""
    echo "Error: Could not extract bootstrap token from container logs."
    exit 1
}

# =============================================================================
# Prerequisites Check
# =============================================================================

for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '${cmd}' is required but not installed."
        exit 1
    fi
done

# =============================================================================
# Main Flow
# =============================================================================

echo ""
echo "  Pebble HQ — Matrix Homeserver Seed Script"
echo "  =========================================="
echo ""

# ---- Step 0: Check for existing container ------------------------------------

existing=$("$RUNTIME" inspect "$CONTAINER_NAME" 2>/dev/null) || existing=""
if [[ -n "$existing" ]] && [[ $(echo "$existing" | jq 'length') -gt 0 ]]; then
    echo "  A homeserver container already exists."
    printf "  Delete it and start fresh? [y/N] "
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        "$RUNTIME" stop "$CONTAINER_NAME" &>/dev/null || true
        "$RUNTIME" rm -f "$CONTAINER_NAME" &>/dev/null || true
        "$RUNTIME" volume rm "$VOLUME_NAME" &>/dev/null || true
        echo ""
    else
        echo ""
        echo "  Aborted. The existing homeserver was not modified."
        exit 0
    fi
fi

# ---- Step 1: Start homeserver -----------------------------------------------

step 1 7 "Starting homeserver..."

# Start the container
"$RUNTIME" run -d \
    --name "$CONTAINER_NAME" \
    -p 8008:8008 \
    -v "${VOLUME_NAME}:/var/lib/continuwuity" \
    -e CONTINUWUITY_SERVER_NAME="$SERVER_NAME" \
    -e CONTINUWUITY_DATABASE_PATH=/var/lib/continuwuity \
    -e CONTINUWUITY_ADDRESS=0.0.0.0 \
    -e CONTINUWUITY_PORT=8008 \
    -e CONTINUWUITY_ALLOW_REGISTRATION=true \
    -e "CONTINUWUITY_ALLOW_GUEST_REGISTRATION=false" \
    -e CONTINUWUITY_REGISTRATION_TOKEN="$REGISTRATION_TOKEN" \
    -e "CONTINUWUITY_NEW_USER_DISPLAYNAME_SUFFIX=" \
    -e CONTINUWUITY_LOG=warn \
    "$IMAGE" >/dev/null

wait_for_server
step_done

# ---- Step 2: Register users -------------------------------------------------

step 2 7 "Registering users..."

# Continuwuity requires the first account to be created with a one-time
# bootstrap token from the logs. After that, the configured registration token
# takes effect.
BOOTSTRAP_TOKEN=$(get_bootstrap_token)

first_user=true
for user_def in "${USERS[@]}"; do
    IFS='|' read -r username display_name <<< "$user_def"
    DISPLAY_NAMES[$username]="$display_name"
    if [[ "$first_user" == true ]]; then
        ACTIVE_TOKEN="$BOOTSTRAP_TOKEN"
        first_user=false
    else
        ACTIVE_TOKEN="$REGISTRATION_TOKEN"
    fi
    register_user "$username" "$PASSWORD" "$ACTIVE_TOKEN"
done

step_done

# ---- Step 3: Set up profiles ------------------------------------------------

step 3 7 "Setting up profiles..."

for user_def in "${USERS[@]}"; do
    IFS='|' read -r username display_name <<< "$user_def"
    set_displayname "$username" "$display_name"
    set_avatar "$username"
done

step_done

# ---- Step 4: Create spaces --------------------------------------------------

step 4 7 "Creating spaces..."

create_space "pebble-hq"   "morgan" "Pebble HQ"    "Company-wide space for all Pebble teams"
create_space "engineering"  "morgan" "Engineering"   "Engineering teams and technical discussion"
create_space "design"       "jordan" "Design"        "Design team collaboration"
create_space "product"      "casey"  "Product"       "Product planning and strategy"
create_space "general"      "morgan" "General"       "Company-wide channels"

step_done

# ---- Step 5: Create rooms ---------------------------------------------------

step 5 7 "Creating rooms..."

# General channels
create_room "general"       "morgan" "General"        "Company-wide discussion"
create_room "random"        "morgan" "Random"         "Watercooler, off-topic, and fun"
create_room "announcements" "morgan" "Announcements"  "Company news and updates"

# Engineering channels
create_room "backend"       "priya"  "Backend"        "Backend services, APIs, and infrastructure"
create_room "ios"           "alex"   "iOS"            "iOS and macOS development"
create_room "frontend"      "riley"  "Frontend"       "Web frontend development"
create_room "devops"        "sam"    "DevOps"         "CI/CD, deployment, and infrastructure"
create_room "code-review"   "morgan" "Code Review"    "Pull requests, reviews, and merge discussion"

# Design channels
create_room "design-chat"   "jordan" "Design"         "UI/UX discussion and design reviews"
create_room "design-system" "jordan" "Design System"  "Component library, tokens, and guidelines"

# Product channels
create_room "product-chat"  "casey"  "Product"        "Product planning and feature discussion"
create_room "roadmap"       "casey"  "Roadmap"        "Release planning and milestones"

# Direct messages (from alex's perspective)
create_dm "dm-alex-priya"   "alex"   "priya"
create_dm "dm-alex-jordan"  "alex"   "jordan"
create_dm "dm-alex-morgan"  "alex"   "morgan"

step_done

# ---- Step 6: Organize space hierarchy and memberships ------------------------

step 6 7 "Organizing spaces..."

# -- Wire space hierarchy --

# Pebble HQ contains the four sub-spaces
add_space_child "pebble-hq" "engineering" "a" "morgan"
add_space_child "pebble-hq" "design"      "b" "morgan"
add_space_child "pebble-hq" "product"     "c" "morgan"
add_space_child "pebble-hq" "general"     "d" "morgan"

# Engineering space contains engineering rooms
add_space_child "engineering" "backend"     "a" "morgan"
add_space_child "engineering" "ios"         "b" "morgan"
add_space_child "engineering" "frontend"    "c" "morgan"
add_space_child "engineering" "devops"      "d" "morgan"
add_space_child "engineering" "code-review" "e" "morgan"

# Design space contains design rooms
add_space_child "design" "design-chat"   "a" "jordan"
add_space_child "design" "design-system" "b" "jordan"

# Product space contains product rooms
add_space_child "product" "product-chat" "a" "casey"
add_space_child "product" "roadmap"      "b" "casey"

# General space contains general rooms
add_space_child "general" "general"       "a" "morgan"
add_space_child "general" "random"        "b" "morgan"
add_space_child "general" "announcements" "c" "morgan"

# -- Invite everyone to the top-level space and general channels --
# morgan created pebble-hq and general channels, so they're already in.

for user in priya alex jordan sam riley casey taylor; do
    # Spaces
    invite_and_join "pebble-hq"  "morgan" "$user"
    invite_and_join "general"    "morgan" "$user"

    # General channels
    invite_and_join "general"       "morgan" "$user"
    invite_and_join "random"        "morgan" "$user"
    invite_and_join "announcements" "morgan" "$user"
done

# -- Engineering space & rooms --
# morgan (created engineering space), priya, alex, sam, riley, taylor
for user in priya alex sam riley taylor; do
    invite_and_join "engineering" "morgan" "$user"
done

# #backend: priya (creator), morgan, sam, alex
invite_and_join "backend" "priya" "morgan"
invite_and_join "backend" "priya" "sam"
invite_and_join "backend" "priya" "alex"

# #ios: alex (creator), priya, taylor, morgan
invite_and_join "ios" "alex" "priya"
invite_and_join "ios" "alex" "taylor"
invite_and_join "ios" "alex" "morgan"

# #frontend: riley (creator), priya, taylor, morgan
invite_and_join "frontend" "riley" "priya"
invite_and_join "frontend" "riley" "taylor"
invite_and_join "frontend" "riley" "morgan"

# #devops: sam (creator), morgan, priya
invite_and_join "devops" "sam" "morgan"
invite_and_join "devops" "sam" "priya"

# #code-review: morgan (creator), priya, alex, sam, riley, taylor
for user in priya alex sam riley taylor; do
    invite_and_join "code-review" "morgan" "$user"
done

# -- Design space & rooms --
# jordan created design space
for user in casey alex morgan riley; do
    invite_and_join "design" "jordan" "$user"
done

# #design-chat: jordan (creator), casey, alex, morgan
invite_and_join "design-chat" "jordan" "casey"
invite_and_join "design-chat" "jordan" "alex"
invite_and_join "design-chat" "jordan" "morgan"

# #design-system: jordan (creator), riley, alex
invite_and_join "design-system" "jordan" "riley"
invite_and_join "design-system" "jordan" "alex"

# -- Product space & rooms --
# casey created product space
for user in morgan jordan priya alex; do
    invite_and_join "product" "casey" "$user"
done

# #product-chat: casey (creator), morgan, jordan
invite_and_join "product-chat" "casey" "morgan"
invite_and_join "product-chat" "casey" "jordan"

# #roadmap: casey (creator), morgan, priya, alex
invite_and_join "roadmap" "casey" "morgan"
invite_and_join "roadmap" "casey" "priya"
invite_and_join "roadmap" "casey" "alex"

# -- Promote alex to admin in select rooms --
promote_to_admin "random"      "morgan" "alex"
promote_to_admin "code-review" "morgan" "alex"

step_done

# ---- Step 7: Send messages --------------------------------------------------

step 7 7 "Sending messages..."

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# #announcements
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "announcements" "morgan" "Welcome to Pebble's internal chat! This is our space for company-wide announcements. Please keep discussion in #general and save this channel for important updates."

send_message "announcements" "morgan" "Team, I'm thrilled to announce that Taylor Okafor is joining us as our new QA Engineer starting today. Taylor comes from Stripe and brings a ton of experience in automated testing and CI pipelines. Please give them a warm welcome!"

send_message "announcements" "casey" "Q3 goals are now posted in the Product space. The big themes this quarter are: improving onboarding, launching the Teams feature, and cutting p95 API latency by 40%. Reach out if you have questions about how your work fits in."

send_message "announcements" "morgan" "Reminder: Engineering office hours are every Thursday at 2pm PT. Bring your cross-team questions, architecture proposals, or anything you want to discuss. No agenda required."

send_message "announcements" "casey" "We just crossed 10,000 active users on the platform. Huge milestone for the team. Thank you all for the incredible work this quarter."

send_message "announcements" "morgan" "Heads up: we're upgrading our CI infrastructure this weekend (Saturday 10pm - Sunday 6am PT). Expect intermittent build failures during that window. Sam will post updates in #devops."

send_message "announcements" "casey" "Product update: the Teams feature is officially in internal beta. If you'd like early access, reach out to me or Morgan. We're targeting a public launch in mid-July."

send_message "announcements" "morgan" "Quick process change: starting next week, all PRs will require at least one approval before merging. This applies to all repos. Details in #code-review."

send_message "announcements" "morgan" "Please welcome Casey Brooks, who just celebrated 2 years at Pebble this week. Casey, thank you for everything you do to keep us focused and shipping. We're lucky to have you."

send_message "announcements" "casey" "We're hosting a design sprint next Wednesday and Thursday. Jordan will be leading sessions on the onboarding redesign. Calendar invites are going out today — please make it a priority."

send_message "announcements" "morgan" "Security reminder: please enable 2FA on your GitHub accounts if you haven't already. Sam is auditing access this week and accounts without 2FA will be flagged."

send_message "announcements" "casey" "NPS scores are in from the latest survey: we jumped from 42 to 58 this quarter. Biggest driver was performance improvements. Shoutout to the entire engineering team."

send_message "announcements" "morgan" "The office will be closed Monday for the holiday. Enjoy the long weekend, everyone. If anything urgent comes up, the on-call rotation is in PagerDuty."

send_message "announcements" "casey" "Reminder that Q3 OKR self-assessments are due by end of day Friday. Please update your progress in Lattice. Reach out to your manager if you need help."

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# #general
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "general" "morgan"  "Good morning, everyone. How's the week shaping up?"
send_message "general" "priya"   "Pretty solid. Finishing up the database migration prep today, then switching over to the notification service."
send_message "general" "alex"    "Wrapping up the new room list refactor. The SwiftUI performance improvements are looking really promising."
send_message "general" "jordan"  "I just published the updated style guide to the wiki. Would love everyone to take a look when you get a chance."
send_message "general" "riley"   "Nice, I'll check it out. We've been needing clearer spacing guidelines for the web dashboard."
send_message "general" "casey"   "Quick reminder that sprint retro is at 3pm today. I'll send the Zoom link in a few."
send_message "general" "sam"     "Build times are down 35% after the CI cache changes I shipped yesterday. If anyone notices anything weird with their builds, let me know."
send_message "general" "taylor"  "That's a huge improvement, Sam. I noticed the test suite runs are faster too."
send_message "general" "morgan"  "Great work, Sam. That's been a pain point for a while."
send_message "general" "priya"   "Has anyone read that new blog post about structured concurrency patterns? Really well written: https://swiftbysundell.com/articles/structured-concurrency"
send_message "general" "alex"    "Yeah, I read it last night. The section on task groups is especially relevant to what we're doing in the networking layer."
send_message "general" "jordan"  "Not my area but I bookmarked it anyway. Always good to understand what the engineers are working with."
send_message "general" "casey"   "Just got out of the customer call. They're really happy with the latest release. Specifically called out how fast the search feels now."
send_message "general" "priya"   "That's great to hear. The Elasticsearch tuning we did last sprint is paying off."
send_message "general" "riley"   "Speaking of which, are we still planning to add search filters to the web UI this sprint?"
send_message "general" "casey"   "Yes, it's in the sprint backlog. Let's sync on the specifics tomorrow."
send_message "general" "sam"     "Anyone up for a coffee chat today? I found a new place near the office that does a great cortado."
send_message "general" "taylor"  "I'm in! Right after standup?"
send_message "general" "jordan"  "Count me in too."
send_message "general" "morgan"  "Congrats to the team on shipping the notifications feature. Users are already loving it based on early feedback."
send_message "general" "taylor"  "Has anyone figured out how to get Xcode 26 to stop re-indexing every time you switch branches? It's killing me."
send_message "general" "alex"    "I've had the same issue. Deleting the DerivedData folder for the project usually fixes it, but it's annoying."
send_message "general" "sam"     "I added a script to our tooling repo that clears derived data automatically on branch switch. Check out scripts/clean-branch.sh."
send_message "general" "taylor"  "You're a lifesaver, Sam."
send_message "general" "jordan"  "Design review for the onboarding flow is tomorrow at 11am. I'll share the Figma link in #design-chat beforehand."
send_message "general" "casey"   "Everyone please try to make it — onboarding is our top priority for the next sprint."
send_message "general" "priya"   "I'll be there. Quick question — are we redesigning the server-side onboarding flow too, or just the client UX?"
send_message "general" "casey"   "Primarily the client UX, but if there are backend changes needed to support it, we'll scope those in."
send_message "general" "riley"   "Just a heads up, I updated the shared ESLint config. If your editor starts showing new warnings, that's why. All the rules are auto-fixable."
send_message "general" "morgan"  "Happy Friday, team. Solid week all around. Enjoy the weekend and recharge."
send_message "general" "casey"   "Alright, I've finalized the agenda for Monday's standup. We're going to cover the sprint retro, onboarding progress, and the beta release."
send_mention "general" "casey" "Alex Kim — can you give a quick update on the iOS release status at Monday's standup?" "@alex:pebble.dev"
send_mention "general" "jordan" "Also Alex Kim, I left some updated assets in the Figma file for the new empty states. Take a look when you get a chance!" "@alex:pebble.dev"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# #random
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "random" "sam"     "Just discovered that our staging server has been running for 847 days without a reboot. I'm afraid to touch it."
send_message "random" "priya"   "That server has survived three major version upgrades. It deserves a medal."
send_message "random" "riley"   "We should name it. I vote 'Cockroach'."
send_message "random" "alex"    "Anyone have lunch recs near the office? I'm tired of the usual spots."
send_message "random" "jordan"  "There's a new ramen place on 3rd Street that's really good. Opened last week."
send_message "random" "taylor"  "I went there yesterday, can confirm. The tonkotsu is excellent."
send_message "random" "casey"   "Has anyone been watching Severance? Just started it and I can't stop."
send_message "random" "morgan"  "One of the best shows I've seen in years. You're in for a ride."
send_message "random" "alex"    "The set design alone is worth watching it for. Every frame is so intentional."
send_message "random" "priya"   "I finished it last weekend. The finale is incredible."
send_message "random" "sam"     "Fun fact: I automated my coffee machine with a Raspberry Pi. It now starts brewing when my first CI build of the day kicks off."
send_message "random" "riley"   "That is either genius or deeply concerning. Possibly both."
send_message "random" "jordan"  "I need this in my life. Can you share the setup?"
send_message "random" "taylor"  "This is why I love this team."
send_message "random" "alex"    "Just saw this and thought of us: 'A QA engineer walks into a bar. Orders 1 beer. Orders 0 beers. Orders 99999999 beers. Orders -1 beers. Orders a lizard.'"
send_message "random" "taylor"  "I feel personally attacked and also very seen."
send_message "random" "casey"   "Trivia night this Thursday at The Brass Tap. Last time engineering lost to the product team and I will never let you forget it."
send_message "random" "priya"   "That's because you had a sports category. That's basically cheating against us."
send_message "random" "morgan"  "I'm in. Redemption arc starts now."
send_message "random" "jordan"  "Just got back from a typography exhibit at the MoMA. If anyone wants to go, it runs until August. Highly recommend."
send_message "random" "riley"   "Oh I saw that on Instagram. The variable font section looked incredible."
send_message "random" "sam"     "My home lab now has more compute power than our staging environment. I might have a problem."
send_message "random" "alex"    "You definitely have a problem, but it's one of the cooler problems to have."
send_message "random" "taylor"  "Weekend project update: I taught my dog to bring me a seltzer from a mini fridge. Took 3 weeks and a lot of treats."
send_message "random" "jordan"  "Please tell me you have a video of this."
send_message "random" "taylor"  "Obviously. I'll drop it in here Monday."

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# #backend
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "backend" "priya"  "I've been looking at the migration plan for splitting the users table. Here's what I'm thinking: we do it in three phases — add new columns, backfill, then drop the old ones."
send_message "backend" "morgan" "That sounds right. Do we need a maintenance window for the backfill?"
send_message "backend" "priya"  "No, we can do it online. I'll use batched writes with a cursor so we don't lock the table. Should take about 20 minutes for the full dataset."
send_message "backend" "sam"    "Make sure we have a rollback plan. Last time we did a migration like this, the foreign key constraints got tricky."
send_message "backend" "priya"  "Good call. I'll add a rollback script and test it against a snapshot of prod first."
send_message "backend" "alex"   "Will the API response shape change at all? I want to make sure the mobile clients are ready."
send_message "backend" "priya"  "The public API won't change. We're keeping the same serialization layer. The only change is internal to the query layer."
send_message "backend" "alex"   "Perfect, thanks."
send_message "backend" "morgan" "Priya, can you also document the new schema in the architecture repo? I want to keep that up to date."
send_message "backend" "priya"  "Already on my list. I'll open the PR today."
send_message "backend" "sam"    "On a different topic — I've been profiling the /search endpoint and found that we're making 3 redundant database calls per request. Should be an easy fix, expecting about 2x improvement."
send_message "backend" "priya"  "Nice find. Is that the N+1 issue we flagged last sprint?"
send_message "backend" "sam"    "Yep, same one. I'll put up a PR this afternoon."
send_message "backend" "morgan" "Let's make sure we add a regression test for that."
send_message "backend" "priya"  "Agreed. I'll review the PR. @alex if you want to keep an eye on it too, the perf improvement should be noticeable on mobile."
send_message "backend" "priya"  "Heads up — I'm adding rate limiting to the public API. Starting with the /search and /messages endpoints since those are the most expensive."
send_message "backend" "sam"    "What are you thinking for limits? Per-user or per-IP?"
send_message "backend" "priya"  "Per-user for authenticated requests, per-IP for unauthenticated. I'm using a sliding window counter backed by Redis. 100 requests per minute for search, 300 for messages."
send_message "backend" "morgan" "Those numbers seem reasonable. Can we make them configurable per plan later?"
send_message "backend" "priya"  "Yes, the limits are defined in a config file so we can adjust per tier without a code change. I'll set up the free/pro/enterprise tiers now even though we only use one today."
send_message "backend" "alex"   "Will the API return rate limit headers? I want to handle 429 responses gracefully on the client."
send_message "backend" "priya"  "Yep — X-RateLimit-Limit, X-RateLimit-Remaining, and X-RateLimit-Reset. Standard stuff. I'll include a Retry-After header on 429 responses too."
send_message "backend" "alex"   "Great. I'll add a retry-with-backoff handler on the iOS side once those are live."
send_message "backend" "sam"    "I'll make sure the Redis instance for rate limiting is on a separate cluster from the cache. Don't want rate limit lookups competing with cache reads."
send_message "backend" "priya"  "Just deployed the rate limiting changes to staging. All the tests are passing and I've verified the headers manually with curl."
send_mention "backend" "priya" "Alex Kim — the rate limit headers are live on staging. You should be good to start on the retry-with-backoff handler whenever you're ready." "@alex:pebble.dev"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# #ios
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "ios" "alex"    "I've been working on the new room list implementation using LazyVStack with pinned headers. The scroll performance is significantly better than what we had before."
send_message "ios" "priya"   "Are you using the new ScrollPosition API for restoring scroll state?"
send_message "ios" "alex"    "Yes, it's so much cleaner than ScrollViewReader. The anchor-based approach just works."
send_message "ios" "taylor"  "I've been testing the build on macOS 26 beta 3 and noticed a rendering glitch with the sidebar when the window is resized quickly. Want me to file an issue?"
send_message "ios" "alex"    "Please do. Is it reproducible or intermittent?"
send_message "ios" "taylor"  "Reproducible, but only at certain window widths. I'll capture a screen recording."
send_message "ios" "morgan"  "Nice work on the room list, Alex. How's the memory footprint looking compared to the old implementation?"
send_message "ios" "alex"    "About 30% lower at steady state. The lazy loading means we're not keeping hundreds of views in memory anymore. The Observable framework handles invalidation really efficiently."
send_message "ios" "priya"   "I've been looking at how we handle the sync response on the client side. Right now we're doing too much work on the main actor. I think we should move the parsing to a background task."
send_message "ios" "alex"    "Agreed. I was thinking we could use an AsyncStream to bridge the SDK callbacks and process them off the main actor, then only push the final state updates to the UI."
send_message "ios" "priya"   "That's exactly what I had in mind. Want to pair on it tomorrow?"
send_message "ios" "alex"    "Sounds great. Morning work for you?"
send_message "ios" "priya"   "Let's do 10am."
send_message "ios" "taylor"  "Filed the sidebar issue: #347. Includes the screen recording and steps to reproduce."
send_message "ios" "alex"    "Thanks, Taylor. I'll take a look after lunch."
send_message "ios" "morgan"  "Quick reminder that we need to submit the TestFlight build by Friday for the beta testers."
send_message "ios" "alex"    "On track. I'll have the room list changes merged by Thursday. Taylor, can you do a full regression pass on Thursday afternoon?"
send_message "ios" "taylor"  "Already blocked off my calendar for it."
send_message "ios" "alex"    "Been experimenting with the new mesh gradient API in SwiftUI. It could give our room avatars a really nice generative background when there's no custom image set."
send_message "ios" "taylor"  "That sounds cool. How does it perform in a list with 100+ items?"
send_message "ios" "alex"    "Tested it and it's fine — the gradient is computed once and cached. No measurable impact on scroll performance."
send_message "ios" "priya"   "I finally got the end-to-end encryption key backup flow working on the client side. The Rust SDK handles most of the heavy lifting, but wiring up the verification UI took some finessing."
send_message "ios" "alex"    "Nice. How are you handling the case where the user has multiple devices?"
send_message "ios" "priya"   "Cross-signing handles it. When you verify on one device, the SDK propagates trust to your other sessions automatically. I just needed to surface the right prompts."
send_message "ios" "morgan"  "E2EE is going to be a big selling point. Great work getting that over the line."
send_message "ios" "taylor"  "I've written about 40 UI tests for the room list. Coverage is at 85% now. The remaining 15% is edge cases around offline mode that are tricky to simulate."
send_message "ios" "alex"    "That's solid coverage. For the offline tests, we could inject a mock network layer that returns errors. Want me to set up the protocol for that?"
send_message "ios" "taylor"  "That would be perfect. A simple protocol with a flag to toggle connectivity would be enough."
send_message "ios" "priya"   "Just finished rebasing the async bridging branch. Had to rework a few of the cancellation handlers but it's cleaner now."
send_message "ios" "priya"   "Also added a unit test for the backpressure case — turns out we were dropping events when the buffer filled up. Fixed."
send_mention "ios" "priya" "Hey Alex Kim, I pushed the AsyncStream bridging changes to the feature branch. Can you pull and see if it plays nicely with the room list?" "@alex:pebble.dev"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# #frontend
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "frontend" "riley"  "Just pushed the new dashboard layout. It uses CSS Grid for the main structure and Flexbox for the card components. Much more maintainable than what we had."
send_message "frontend" "priya"  "Looks clean. Does it handle the responsive breakpoints well?"
send_message "frontend" "riley"  "Yeah, tested down to 768px. Below that it stacks into a single column. I'll add the tablet-specific layout next week."
send_message "frontend" "taylor" "I ran through the accessibility audit on the new layout. A few contrast issues on the secondary text — I'll file them."
send_message "frontend" "riley"  "Thanks, Taylor. I know the gray-on-white was borderline. I'll bump it up."
send_message "frontend" "morgan" "Are we still targeting Chrome, Firefox, and Safari for the initial launch?"
send_message "frontend" "riley"  "Yes, plus Edge since it's Chromium-based and basically free. I'm not worrying about IE at all."
send_message "frontend" "morgan" "Good call. Nobody should be worrying about IE in 2026."
send_message "frontend" "priya"  "The API pagination changes I made should help with the dashboard load times. Instead of loading everything upfront, it now fetches page by page as you scroll."
send_message "frontend" "riley"  "I noticed that. The initial render went from 2.8s to under 500ms. Huge difference."
send_message "frontend" "taylor" "The infinite scroll behavior is smooth. One thing — when you scroll to the bottom and there's no more data, there's no visual indicator. A small 'end of list' message would help."
send_message "frontend" "riley"  "Good catch. I'll add that."
send_message "frontend" "riley"  "Started working on the keyboard shortcuts system. I'm using a global event listener that maps key combos to actions. Similar to how VS Code does it."
send_message "frontend" "morgan" "Are the shortcuts going to be customizable?"
send_message "frontend" "riley"  "Not in v1, but the architecture supports it. Each shortcut is just a key-action mapping in a JSON config. We can expose a UI for customization later."
send_message "frontend" "priya"  "For the search filters — I added a new query parameter to the API. You can now pass 'filters' as a JSON object with fields like 'sender', 'date_range', and 'room_type'."
send_message "frontend" "riley"  "Perfect, that's exactly what I need. I'll build the filter panel this week. Thinking a collapsible sidebar that slides in from the right."
send_message "frontend" "taylor" "I tested the keyboard shortcuts branch. Cmd+K for search, Cmd+Shift+N for new room, and Cmd+[ for back navigation all feel natural. One issue: Cmd+, should open settings but it opens the browser settings instead."
send_message "frontend" "riley"  "Good catch. I need to call preventDefault on that one. Will fix."
send_message "frontend" "morgan" "How are we handling discoverability? Users won't know the shortcuts exist unless we tell them."
send_message "frontend" "riley"  "I'm adding a Cmd+/ shortcut that opens a quick reference overlay. And tooltips on buttons will show the shortcut hint after a short delay."

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# #devops
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "devops" "sam"    "CI migration update: we're now fully on the new runners. Build times are averaging 4 minutes, down from 11. The caching layer is doing most of the heavy lifting."
send_message "devops" "morgan" "That's fantastic. The team has been feeling the slow builds for months."
send_message "devops" "sam"    "Next up: I'm working on ephemeral preview environments for PRs. The idea is that every PR automatically gets a deployed preview URL that the team can test against."
send_message "devops" "priya"  "That would be incredible for code review. Being able to click a link and see the changes live would save a lot of time."
send_message "devops" "sam"    "Exactly. I'm using containers with auto-cleanup after 24 hours of inactivity. Should keep costs minimal."
send_message "devops" "morgan" "Love it. Keep us posted on the progress."
send_message "devops" "sam"    "Also heads up — I'm rotating the staging API keys this afternoon. If you're testing against staging, you'll need to pull the new keys from 1Password."
send_message "devops" "priya"  "Thanks for the heads up. I'll update my local config."
send_message "devops" "sam"    "One more thing: I set up automated database backups for staging. They run every 6 hours and retain for 7 days. If anyone nukes the staging DB again, we can recover in minutes."
send_message "devops" "morgan" "The 'again' in that sentence is doing a lot of work."
send_message "devops" "sam"    "Preview environments are live. Every PR now gets a deploy preview URL posted as a comment. Links expire after 48 hours of inactivity."
send_message "devops" "priya"  "Just tested it on my PR — works beautifully. The deploy took about 90 seconds."
send_message "devops" "morgan" "This is going to change how we do code review. Being able to click and test live is huge."
send_message "devops" "sam"    "Next on my list: setting up structured logging. Right now our logs are a mix of plain text and JSON. I want everything in JSON so we can query them properly in Grafana."
send_message "devops" "priya"  "Yes please. Debugging production issues with grep and hope is not sustainable."
send_message "devops" "sam"    "I'm also adding correlation IDs to every request. That way you can trace a single user action across all our services."
send_message "devops" "morgan" "How are we on monitoring coverage? I want to make sure we have alerts for the critical paths."
send_message "devops" "sam"    "Good — we have alerts on API latency p95, error rate, and database connection pool usage. I'm adding one for the message queue depth this week. If it backs up, we'll know within 2 minutes."
send_message "devops" "priya"  "Can you also add an alert for when the Redis memory usage crosses 80%? We've been close a couple of times."
send_message "devops" "sam"    "Done. I'll set it at 75% as a warning and 85% as critical."

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# #code-review
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "code-review" "priya"  "PR #412 is up: refactors the authentication middleware to support OAuth2 PKCE. It's a big one but I broke it into small commits. Reviews welcome."
send_message "code-review" "morgan" "I'll take first pass. How urgent is it?"
send_message "code-review" "priya"  "Moderate — it's blocking the SSO work Casey wants for Q3, but no rush today."
send_message "code-review" "alex"   "PR #415: new room list implementation for iOS. This is the LazyVStack refactor I mentioned in #ios. Would love eyes on the scroll state management in particular."
send_message "code-review" "taylor" "I'll review #415. I've been testing the feature branch so I have good context."
send_message "code-review" "riley"  "PR #418: dashboard layout rewrite (CSS Grid migration). Straightforward refactor, no logic changes. Should be a quick review."
send_message "code-review" "sam"    "Reviewed #418 — looks good. Left one minor comment about the media query ordering but it's a nit. Approved."
send_message "code-review" "riley"  "Thanks Sam, I'll fix that before merging."
send_message "code-review" "taylor" "Finished reviewing #415. Left some comments on the accessibility of the pinned section headers. Overall looks great, Alex."
send_message "code-review" "alex"   "Thanks Taylor. Good catches — I'll address those today."
send_message "code-review" "morgan" "Finished reviewing #412. Solid work, Priya. A few questions about the token refresh flow but nothing blocking. Approved with comments."
send_message "code-review" "priya"  "Thanks Morgan. I'll respond to the comments and merge once CI passes."
send_message "code-review" "sam"    "PR #421: adds structured logging to all API endpoints. Replaces the old console.log calls with proper JSON output. Would appreciate a quick look."
send_message "code-review" "priya"  "Reviewing now. Is this using the new logging library you mentioned in #devops?"
send_message "code-review" "sam"    "Yes, it's pino. Extremely fast and supports child loggers so we can attach request context automatically."
send_message "code-review" "priya"  "Looks solid. One suggestion — can we add a sanitizer that strips PII from the log output? Don't want email addresses ending up in Grafana."
send_message "code-review" "sam"    "Great call. I'll add a redaction layer before merging."
send_message "code-review" "alex"   "PR #423: rate limit handling on the iOS client. This adds retry-with-backoff for 429 responses and surfaces a user-friendly message when throttled."
send_message "code-review" "taylor" "Reviewing #423. The backoff logic looks good. One question — do you cap the max retry delay? I see it doubles each time but I didn't spot an upper bound."
send_message "code-review" "alex"   "Good eye. I'll cap it at 30 seconds. No point waiting longer than that."
send_message "code-review" "riley"  "PR #425: keyboard shortcuts system for the web client. Adds Cmd+K for search, Cmd+Shift+N for new room, and a Cmd+/ shortcut reference overlay."
send_message "code-review" "morgan" "I'll take #425. I've been wanting this feature for months."
send_message "code-review" "morgan" "Reviewed #425 — this is really well done, Riley. Clean separation between the key listener and the action dispatcher. Approved."
send_message "code-review" "taylor" "Did another pass on #423 this morning. The error handling for network timeouts during retry is solid."
send_mention "code-review" "taylor" "Alex Kim, one last thing on PR #423 — I think we should add jitter to the backoff to avoid thundering herd. Quick fix!" "@alex:pebble.dev"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# #design-chat
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "design-chat" "jordan" "I've posted the updated mockups for the Teams feature in Figma. The main changes are: simplified invite flow, new member role selector, and a cleaner settings page."
send_message "design-chat" "casey"  "These look great. I especially like how the invite flow went from 4 steps to 2. That was our biggest user complaint."
send_message "design-chat" "jordan" "Yeah, the key insight was combining the role selection with the invite step. Users don't need a separate screen for that."
send_message "design-chat" "alex"   "From an implementation perspective, the new invite flow is actually simpler to build too. Less state to manage."
send_message "design-chat" "jordan" "That's always a good sign. If the design is simpler to build, it's usually simpler to use."
send_message "design-chat" "morgan" "Jordan, can you also do a pass on the empty states? A few of our screens just show blank white space when there's no data."
send_message "design-chat" "jordan" "Already on my radar. I'm designing a consistent set of empty state illustrations. Should have drafts by end of week."
send_message "design-chat" "casey"  "Love that. Empty states are such an underappreciated part of the UX."
send_message "design-chat" "alex"   "Agreed. A good empty state can guide users to the right action instead of leaving them confused."
send_message "design-chat" "jordan" "Exactly. Each empty state will have: an illustration, a headline explaining what belongs here, and a primary action button to get started."
send_message "design-chat" "jordan" "Also, I ran the new designs through an accessibility contrast checker. Everything passes WCAG AA. A few of the secondary text styles are close to the boundary, so I bumped them up."
send_message "design-chat" "casey"  "Accessibility is non-negotiable for us. Thanks for being proactive on that."
send_message "design-chat" "jordan" "Working on the onboarding flow mockups. The first-run experience has 4 steps: create workspace, invite members, set up channels, and a quick tour of the UI."
send_message "design-chat" "casey"  "Can we get it down to 3? Every extra step in onboarding is a drop-off point."
send_message "design-chat" "jordan" "I think we can combine 'invite members' and 'set up channels' into a single step. The user picks a template that includes both. Like 'Engineering team' or 'Small business'."
send_message "design-chat" "casey"  "Love that. Templates lower the cognitive load and get users to value faster."
send_message "design-chat" "alex"   "From a technical standpoint, templates are just JSON configs. Easy to implement and easy to add new ones later."
send_message "design-chat" "morgan" "Jordan, how are we handling the case where someone joins an existing workspace? That's a different flow from creating a new one."
send_message "design-chat" "jordan" "Good point. For joiners, the flow is simpler: accept invite, set up profile, quick tour. I'm designing both paths but the joiner flow is lighter — just 2 steps."
send_message "design-chat" "jordan" "Also shared the empty state illustrations in Figma. There are 6 in the set: no messages, no rooms, no members, no search results, no notifications, and a generic 'nothing here yet' fallback."
send_message "design-chat" "casey"  "These are beautiful. The illustration style is consistent and they feel warm without being childish. Exactly the right tone."
send_message "design-chat" "alex"   "I can start implementing the empty states on iOS this sprint. They'll be reusable components in our design system."
send_mention "design-chat" "jordan" "Alex Kim, I just uploaded the final empty state illustrations to Figma with export-ready assets. The 'no messages' and 'no rooms' ones turned out really well." "@alex:pebble.dev"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# #design-system
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "design-system" "jordan" "Proposing a new component: SegmentedPicker. It's a horizontal tab-style selector for toggling between 2-4 options. Common enough in the app that it should be in the system."
send_message "design-system" "riley"  "We have something similar on the web side. Would be great to unify the naming and behavior across platforms."
send_message "design-system" "jordan" "Good idea. Let's align on the API: it takes an array of options and a binding to the selected index. Supports labels and optionally icons."
send_message "design-system" "alex"   "On iOS, we can back it with a native Picker with the segmented style. That gives us the platform look for free."
send_message "design-system" "jordan" "Perfect. I'll add it to the Figma library with specs for both web and native."
send_message "design-system" "riley"  "Also — I want to revisit our spacing scale. We're using 4px increments but some of the designs use 6px and 10px which don't fit the scale. Should we switch to an 8px base?"
send_message "design-system" "jordan" "I've been thinking about this too. An 8px scale with a 4px half-step for tight spots would cover most of our needs. Let me draft a proposal."
send_message "design-system" "alex"   "SwiftUI's default spacing tends to align with 8pt grids anyway, so that would work well natively."
send_message "design-system" "jordan" "Spacing proposal is posted in Figma. The scale is: 4, 8, 12, 16, 24, 32, 48, 64. Covers everything from tight icon padding to section margins."
send_message "design-system" "riley"  "I like this. It's the same scale Tailwind uses, which makes it familiar for the web side."
send_message "design-system" "alex"   "I'll define these as constants in the iOS codebase. Something like Spacing.xs, Spacing.sm, Spacing.md, etc."
send_message "design-system" "jordan" "New component request: StatusBadge. A small colored dot with an optional label for showing online/offline/busy status. We use it in at least 5 places already with inconsistent implementations."
send_message "design-system" "riley"  "Yeah, I've seen three different versions on the web side alone. Happy to consolidate."
send_message "design-system" "jordan" "Specs: 8px dot, 3 variants (green for online, amber for idle, gray for offline). The label is optional and uses caption style text."
send_message "design-system" "alex"   "Simple and clean. I'll build the SwiftUI version this week. Should take less than an hour since it's just a circle with a text label."
send_message "design-system" "jordan" "Also thinking about our color system. Right now we have 24 named colors but some are only used once. I want to audit and consolidate down to a semantic palette: primary, secondary, accent, destructive, success, warning, and their surface variants."
send_message "design-system" "riley"  "That would simplify theming a lot. Right now changing the accent color means updating like 12 different CSS variables."

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# #product-chat
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "product-chat" "casey"  "User research findings from last week: the top 3 requests are search filters, keyboard shortcuts, and a dark mode toggle in the quick settings."
send_message "product-chat" "morgan" "Keyboard shortcuts should be relatively straightforward. We already have the infrastructure for it."
send_message "product-chat" "casey"  "Agreed. I'm thinking we prioritize: 1) search filters (high impact, medium effort), 2) keyboard shortcuts (medium impact, low effort), 3) dark mode quick toggle (lower impact, low effort)."
send_message "product-chat" "jordan" "For the dark mode toggle — can we just respect the system setting? That's the macOS convention and it's zero UI to build."
send_message "product-chat" "casey"  "We already do, but some users want to override it per-app. The request is specifically for an in-app toggle."
send_message "product-chat" "jordan" "Makes sense. I'll include it in the settings redesign."
send_message "product-chat" "casey"  "Also, churn analysis shows that users who don't set up their workspace in the first 24 hours are 3x more likely to leave. We need to invest in the onboarding flow."
send_message "product-chat" "morgan" "That's a compelling stat. Let's make onboarding a priority for the next sprint."
send_message "product-chat" "casey"  "I'll draft an onboarding spec this week. Jordan, can we sync on the flow design?"
send_message "product-chat" "jordan" "Thursday works for me. I'll sketch some ideas beforehand."
send_message "product-chat" "casey"  "Competitor analysis update: Slack just shipped a new canvas feature and Discord added forum channels. Neither has a great native macOS experience though — that's still our differentiator."
send_message "product-chat" "morgan" "We need to keep leaning into the native angle. Nobody else is building a Matrix client that feels like a real Mac app."
send_message "product-chat" "casey"  "Exactly. Our positioning is 'the iMessage experience for team chat.' Fast, native, and beautifully integrated with macOS."
send_message "product-chat" "jordan" "I've been doing some competitive teardowns. One thing Element does well is their space hierarchy — but the UX around it is confusing. We can do better."
send_message "product-chat" "casey"  "Feature request from a beta user: message scheduling. They want to type a message now and have it send at a specific time. Thoughts?"
send_message "product-chat" "morgan" "Interesting. It's a nice-to-have but probably not a priority right now. I'd put it in the 'Q4 maybe' bucket."
send_message "product-chat" "casey"  "Agreed. I'll add it to the backlog with a 'future' label. Let's focus on the core experience first."
send_message "product-chat" "jordan" "One more thing — can we add a feedback button in the app? Right now users have to email us or find the GitHub repo. A simple 'Send Feedback' in the menu would lower the barrier."
send_message "product-chat" "morgan" "That's a great idea and it's trivial to implement. Let's add it to the current sprint."

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# #roadmap
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "roadmap" "casey"  "Q3 roadmap overview: we have three major milestones. M1 (July): Teams feature launch. M2 (August): Search improvements + keyboard shortcuts. M3 (September): Onboarding redesign + performance pass."
send_message "roadmap" "morgan" "The Teams feature is the biggest risk item. Priya, how's the backend work tracking?"
send_message "roadmap" "priya"  "The data model is done and the API is about 70% complete. Main remaining work is the permission system and the invite flow. I'd say we're on track for mid-July."
send_message "roadmap" "alex"   "On the iOS side, the Teams UI is mostly stubbed out. Once the API is finalized I can wire it up pretty quickly. I'd estimate a week of integration work."
send_message "roadmap" "casey"  "Good. Let's plan for a two-week internal beta before the public launch. That gives us a buffer for edge cases."
send_message "roadmap" "morgan" "Agreed. I'll set up the beta group. Taylor, can you write up a test plan for the Teams feature?"
send_message "roadmap" "casey"  "M2 is lower risk since it's mostly iteration on existing features. Riley, are you comfortable with the August timeline for search filters?"
send_message "roadmap" "casey"  "Actually, let's discuss M2 specifics in our Thursday planning session. I want to make sure we're scoping it right."
send_message "roadmap" "priya"  "Update on M1: the Teams permission system is done. API coverage is now at 95%. Last piece is the admin transfer flow."
send_message "roadmap" "alex"   "iOS integration for Teams is progressing well. The room list now shows team groupings and the invite flow is working end-to-end."
send_message "roadmap" "casey"  "Great. I'm scheduling the internal beta for the first week of July. That gives us two weeks of buffer before the public launch mid-July."
send_message "roadmap" "morgan" "For M3, I want to include a performance audit of the entire app. Not just API latency — also client-side metrics like time-to-interactive and memory usage."
send_message "roadmap" "alex"   "I've been tracking those on iOS already. Time-to-interactive is around 800ms on an M1 Mac, which is good, but I think we can get it under 500ms with lazy loading."
send_message "roadmap" "casey"  "Let's capture those benchmarks now so we have a baseline to measure against after the performance pass."
send_message "roadmap" "priya"  "I'll set up automated API benchmarks in CI. We can track p50, p95, and p99 latency for every endpoint and alert if anything regresses."
send_message "roadmap" "morgan" "That's exactly the kind of infrastructure we need. Proactive performance monitoring will save us from slow regressions creeping in."
send_message "roadmap" "casey"  "Updated the roadmap doc with all of this. Link is pinned in the Product space. Let's keep this cadence of weekly check-ins."

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# DM: alex <-> priya
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "dm-alex-priya" "alex"   "Hey, quick question about the new API endpoint for room members — is it paginated?"
send_message "dm-alex-priya" "priya"  "Yes, it uses cursor-based pagination. Default page size is 50. Pass the 'after' parameter with the cursor from the previous response."
send_message "dm-alex-priya" "alex"   "Got it. And the response shape is the same as the existing members list?"
send_message "dm-alex-priya" "priya"  "Almost — I added a 'role' field to each member object. Everything else is the same."
send_message "dm-alex-priya" "alex"   "Perfect, that's exactly what I needed for the member list UI. Thanks!"
send_message "dm-alex-priya" "priya"  "No problem. Let me know if you run into anything. The endpoint is on staging now if you want to test against it."
send_message "dm-alex-priya" "priya"  "Oh also — I saw your PR for the room list. The scroll performance fix is really clever. Nice work."
send_message "dm-alex-priya" "alex"   "Thanks! I was nervous about the approach but the benchmarks speak for themselves."
send_message "dm-alex-priya" "alex"   "Hey, one more thing — the E2E key backup flow you finished, does it handle the case where the user's key backup password is different from their account password?"
send_message "dm-alex-priya" "priya"  "Yes, the backup uses a separate recovery key. The user can either save it as a file or protect it with a passphrase. Both flows are implemented."
send_message "dm-alex-priya" "alex"   "Got it. I'll make sure the UI flow makes it clear that it's a separate credential. Don't want users confused."
send_message "dm-alex-priya" "priya"  "Good thinking. Maybe a short explainer card in the setup wizard? Something like 'This recovery key is separate from your password and is used to restore your encrypted messages on new devices.'"
send_message "dm-alex-priya" "alex"   "That's perfect. I'll add it to the key backup screen."

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# DM: alex <-> jordan
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "dm-alex-jordan" "jordan" "Hey Alex, I have a question about the room header component. Is there a max width for the room name before it truncates?"
send_message "dm-alex-jordan" "alex"   "Currently it truncates at the trailing edge of the header bar. It uses the standard SwiftUI truncation behavior — single line with an ellipsis."
send_message "dm-alex-jordan" "jordan" "Could we make it wrap to two lines for longer names? I've seen some rooms with descriptive names that get cut off too aggressively."
send_message "dm-alex-jordan" "alex"   "We could, but it would change the header height dynamically which might feel jumpy when navigating between rooms. Want to see a prototype?"
send_message "dm-alex-jordan" "jordan" "Yes please. Maybe we can use a fixed two-line height so it doesn't jump?"
send_message "dm-alex-jordan" "alex"   "Good idea. I'll throw something together tomorrow and send you a screenshot."
send_message "dm-alex-jordan" "jordan" "Awesome, thanks! No rush on it."
send_message "dm-alex-jordan" "alex"   "Here's the prototype — I went with a fixed two-line height. Screenshot attached. What do you think?"
send_message "dm-alex-jordan" "jordan" "That looks great. The fixed height keeps things stable and the longer names are fully readable now. Let's go with this."
send_message "dm-alex-jordan" "alex"   "Cool, I'll clean it up and submit the PR."
send_message "dm-alex-jordan" "jordan" "By the way, I've been thinking about the room avatar system. Right now all the default avatars are just the first letter of the room name on a colored background. What if we added a set of icon options?"
send_message "dm-alex-jordan" "alex"   "That could be nice. We have SF Symbols available — users could pick from a curated set of icons instead of just the letter."
send_message "dm-alex-jordan" "jordan" "Exactly. I'll mock up an icon picker this week. Keep it simple — a grid of maybe 30-40 relevant icons."

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# DM: alex <-> morgan
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "dm-alex-morgan" "morgan" "Hey Alex, just wanted to check in. How are you feeling about the workload this sprint?"
send_message "dm-alex-morgan" "alex"   "Feeling good! The room list refactor took longer than expected but it's wrapping up now. Should have time for the Teams UI integration next week."
send_message "dm-alex-morgan" "morgan" "Good to hear. Don't hesitate to push back if too much lands on your plate. Quality over speed."
send_message "dm-alex-morgan" "alex"   "Appreciate that. One thing — I'd like to spend a day or two on some tech debt in the networking layer. It's not urgent but it'll make the Teams integration cleaner."
send_message "dm-alex-morgan" "morgan" "Absolutely. Take the time. Investing in the foundation now pays off later. Just flag it in standup so the rest of the team knows."
send_message "dm-alex-morgan" "alex"   "Will do. Thanks, Morgan."
send_message "dm-alex-morgan" "morgan" "Also wanted to mention — I really liked your proposal for the mesh gradient avatars. Small touch but it makes the app feel more polished."
send_message "dm-alex-morgan" "alex"   "Thanks! It was fun to experiment with. The new SwiftUI APIs make that kind of thing surprisingly easy."
send_message "dm-alex-morgan" "morgan" "That's what I love about our stack. How's the TestFlight build looking for Friday?"
send_message "dm-alex-morgan" "alex"   "On track. All the room list changes are merged, Taylor is running the regression pass tomorrow. Barring any surprises we should be good."
send_message "dm-alex-morgan" "morgan" "Perfect. Let me know if anything comes up. I want this beta release to be really solid."
send_message "dm-alex-morgan" "alex"   "Will do. I'm feeling good about this one."

step_done

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "  Homeserver ready!"
echo ""
echo "    URL:       ${SERVER_URL}"
echo "    User:      @${SCREENSHOT_USER}:${SERVER_NAME}"
echo "    Password:  ${PASSWORD}"
echo ""
echo "  Open Relay and sign in with the credentials above."
echo ""
echo "  To stop the server:   ${RUNTIME} stop ${CONTAINER_NAME}"
echo "  To remove all data:   ${RUNTIME} rm ${CONTAINER_NAME} && ${RUNTIME} volume rm ${VOLUME_NAME}"
echo ""

