#!/bin/bash
# server.sh - INFO1112 Assignment 2
# Runs forever, waiting for client requests.

PORT=1234   # temporary: replaced by ss -ltn detection in a later commit

echo "Server is running. Waiting for requests..."

while true; do
    request=$(nc -l "$PORT")
    echo "Received request: $request"
done