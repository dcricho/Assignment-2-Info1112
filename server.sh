#!/bin/bash
# server.sh - INFO1112 Assignment 2
# Runs forever, waiting for client requests.

# Port the listener is started on. The port actually used is read back
# from `ss -ltn` below rather than assumed.
LISTEN_PORT=1234

# Temp file that captures nc's connection info (printed to stderr by -v)
NC_INFO=/tmp/nc_info.$$
trap 'rm -f "$NC_INFO"' EXIT

# Find this container's IP from ifconfig (no hardcoding)
get_ip() {
    ifconfig | grep -oE 'inet (addr:)?[0-9.]+' | grep -oE '[0-9.]+$' | grep -v '^127\.' | head -n 1
}

# Find the listening TCP port from ss -ltn.
# Column 4 is "address:port", so keep whatever follows the last colon.
get_port() {
    ss -ltn | awk 'NR>1 {n=split($4,a,":"); print a[n]; exit}'
}

# Extract the client's IP from nc's "Connection received on <ip> <port>" line
get_client_ip() {
    grep -i 'connection' "$NC_INFO" | grep -oE '[0-9]+(\.[0-9]+){3}' | head -n 1
}

SERVER_IP=$(get_ip)

# ss only shows ports that are already listening, so start a short-lived
# probe listener, read the port back from ss, then stop the probe.
nc -l "$LISTEN_PORT" >/dev/null 2>&1 &
PROBE_PID=$!
sleep 1
SERVER_PORT=$(get_port)
kill "$PROBE_PID" 2>/dev/null
wait "$PROBE_PID" 2>/dev/null

if [ -z "$SERVER_IP" ] || [ -z "$SERVER_PORT" ]; then
    echo "Error: could not detect server IP or port." >&2
    exit 1
fi

echo "Server is running at $SERVER_IP:$SERVER_PORT. Waiting for requests..."

while true; do
    : > "$NC_INFO"
    request=$(nc -v -l "$SERVER_PORT" 2>"$NC_INFO" | tr -d '\r')
    client_ip=$(get_client_ip)
    if [ -z "$client_ip" ]; then
        client_ip="unknown"
    fi
    echo "Request from client IP: $client_ip"
    echo "Received request: $request"
done