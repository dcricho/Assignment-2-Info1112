#!/bin/bash
# server.sh - INFO1112 Assignment 2
# Runs forever, waiting for client requests.
# Uses ncat: it runs this script in --handle mode once per connection
# and sends whatever the handler prints back to the client.

# Port the listener is started on. The port actually in use is read back
# from `ss -ltn` below rather than assumed.
LISTEN_PORT=1234
SCRIPT=$(readlink -f "$0")

# Unit page that the "assignment" request downloads
UNIT_URL="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"

# Find this container's IP from ifconfig (no hardcoding)
get_ip() {
    ifconfig | grep -oE 'inet (addr:)?[0-9.]+' | grep -oE '[0-9.]+$' | grep -v '^127\.' | head -n 1
}

# Find the port ncat is listening on from ss -ltn.
# Column 4 is "address:port", so keep whatever follows the last colon.
get_port() {
    ss -ltnp 2>/dev/null | awk '/ncat/ {n=split($4,a,":"); print a[n]; exit}'
}

# Handle the "assignment" request: curl the unit page, convert the HTML to
# text with html2text, and display it in the server terminal (stderr).
# Anything printed to stdout goes back to the client.
handle_assignment() {
    local html text
    html=$(mktemp) || { echo "Error: could not create temp file."; return 1; }
    text=$(mktemp) || { rm -f "$html"; echo "Error: could not create temp file."; return 1; }

    if ! curl -sS -f -L -A 'Mozilla/5.0' --max-time 20 "$UNIT_URL" -o "$html" 2>&1 >/dev/null; then
        echo "Error: could not download the unit page from $UNIT_URL"
        echo "Error: could not download the unit page." >&2
        rm -f "$html" "$text"
        return 1
    fi

    if ! html2text "$html" > "$text" 2>/dev/null || [ ! -s "$text" ]; then
        echo "Error: could not convert the downloaded page to text."
        echo "Error: html2text conversion failed or produced no output." >&2
        rm -f "$html" "$text"
        return 1
    fi

    echo "----- Assignment information (from $UNIT_URL) -----" >&2
    cat "$text" >&2
    echo "----- End of assignment information -----" >&2

    echo "assignment page downloaded and converted (see server terminal)"
    rm -f "$html" "$text"
}

# Runs once per client connection. stdin/stdout are the client's socket:
# the reply goes to stdout (back to the client), logs go to stderr (terminal).
handle_request() {
    local request client_ip
    read -r request
    request=$(printf '%s' "$request" | tr -d '\r')

    client_ip=${NCAT_REMOTE_ADDR:-unknown}
    echo "Request from client IP: $client_ip" >&2
    echo "Received request: $request" >&2

    case "$request" in
        assignment|asssignment)
            handle_assignment
            ;;
        population)
            echo "population request received (not implemented yet)"
            ;;
        *)
            echo "Error: unknown request '$request'. Valid requests: assignment, population"
            ;;
    esac
}

# Handler mode: ncat starts us with --handle for each connection
if [ "$1" = "--handle" ]; then
    handle_request
    exit 0
fi

# ---- Server mode ----
if ! command -v ncat >/dev/null 2>&1; then
    echo "Error: ncat not found. Install it with: apk add nmap-ncat" >&2
    exit 1
fi

SERVER_IP=$(get_ip)

ncat -l -k -p "$LISTEN_PORT" --sh-exec "bash $SCRIPT --handle" &
NCAT_PID=$!
trap 'kill "$NCAT_PID" 2>/dev/null' EXIT INT TERM
sleep 1

if ! kill -0 "$NCAT_PID" 2>/dev/null; then
    echo "Error: could not start listener on port $LISTEN_PORT (already in use?)." >&2
    exit 1
fi

SERVER_PORT=$(get_port)

if [ -z "$SERVER_IP" ] || [ -z "$SERVER_PORT" ]; then
    echo "Error: could not detect server IP or port." >&2
    exit 1
fi

echo "Server is running at $SERVER_IP:$SERVER_PORT. Waiting for requests..."

# Keep running until stopped
wait "$NCAT_PID"