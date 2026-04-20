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

# Associative arrays for tokens and room IDs
declare -A TOKENS
declare -A ROOMS
declare -A SPACES

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
    echo "txn_${TXN_ID}"
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
            \"visibility\": \"private\"
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
            \"invite\": [\"@${other}:${SERVER_NAME}\"]
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

# Send a text message to a room.
# Usage: send_message <room_key> <sender_username> <body>
send_message() {
    local room_key="$1"
    local sender="$2"
    local body="$3"
    local room_id="${ROOMS[$room_key]:-${SPACES[$room_key]:-}}"
    local token="${TOKENS[$sender]}"
    local txn
    txn=$(next_txn)

    # Escape the body for JSON
    local escaped_body
    escaped_body=$(echo -n "$body" | jq -Rs '.')

    curl -s -X PUT "${SERVER_URL}/_matrix/client/v3/rooms/${room_id}/send/m.room.message/${txn}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"msgtype\": \"m.text\", \"body\": ${escaped_body}}" >/dev/null
}

# Send a notice (bot-style message) to a room.
# Usage: send_notice <room_key> <sender_username> <body>
send_notice() {
    local room_key="$1"
    local sender="$2"
    local body="$3"
    local room_id="${ROOMS[$room_key]:-${SPACES[$room_key]:-}}"
    local token="${TOKENS[$sender]}"
    local txn
    txn=$(next_txn)

    local escaped_body
    escaped_body=$(echo -n "$body" | jq -Rs '.')

    curl -s -X PUT "${SERVER_URL}/_matrix/client/v3/rooms/${room_id}/send/m.room.message/${txn}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"msgtype\": \"m.notice\", \"body\": ${escaped_body}}" >/dev/null
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

if "$RUNTIME" inspect "$CONTAINER_NAME" &>/dev/null; then
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

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# DM: alex <-> morgan
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

send_message "dm-alex-morgan" "morgan" "Hey Alex, just wanted to check in. How are you feeling about the workload this sprint?"
send_message "dm-alex-morgan" "alex"   "Feeling good! The room list refactor took longer than expected but it's wrapping up now. Should have time for the Teams UI integration next week."
send_message "dm-alex-morgan" "morgan" "Good to hear. Don't hesitate to push back if too much lands on your plate. Quality over speed."
send_message "dm-alex-morgan" "alex"   "Appreciate that. One thing — I'd like to spend a day or two on some tech debt in the networking layer. It's not urgent but it'll make the Teams integration cleaner."
send_message "dm-alex-morgan" "morgan" "Absolutely. Take the time. Investing in the foundation now pays off later. Just flag it in standup so the rest of the team knows."
send_message "dm-alex-morgan" "alex"   "Will do. Thanks, Morgan."

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
echo "  To remove all data:   ${RUNTIME} rm -v ${CONTAINER_NAME} && ${RUNTIME} volume rm ${VOLUME_NAME}"
echo ""
