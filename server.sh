#!/bin/bash
# server.sh - INFO1112 Assignment 2
# Runs forever, waiting for client requests.

PORT=1234   # temporary: replaced by ss -ltn detection in a later commit

# Find this container's IP from ifconfig (no hardcoding)
get_ip() {
    ifconfig | grep -oE 'inet (addr:)?[0-9.]+' | grep -oE '[0-9.]+$' | grep -v '^127\.' | head -n 1
}
SERVER_IP=$(get_ip)

echo "Server is running at $SERVER_IP. Waiting for requests..."

while true; do
    request=$(nc -l "$PORT")
    echo "Received request: $request"
done