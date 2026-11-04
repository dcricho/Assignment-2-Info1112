# INFO1112 Assignment 2

A Bash server (`server.sh`) that runs inside an Alpine Docker container and answers requests from clients over TCP.

## Setup

Create the container (from the host):

    docker run -it --name myserver -p 1234:1234 alpine sh

Install the required packages inside the container:

    apk add bash curl html2text net-tools iproute2 nmap-ncat netcat-openbsd python3 py3-matplotlib jq

Note: `ncat` (package `nmap-ncat`) is used so the server can send replies back to clients.

## Run

Copy the script into the container and start it:

    docker cp server.sh myserver:/server.sh
    docker exec -it myserver bash /server.sh

On Git Bash for Windows, use `bash //server.sh` or prefix the command with `MSYS_NO_PATHCONV=1`.

## Testing

From another container (use the IP printed by the server on startup):

    docker run --rm alpine sh -c "echo assignment | nc -w 2 172.17.0.2 1234"
    docker run --rm alpine sh -c "echo population | nc -w 2 172.17.0.2 1234"

## Status

- Server detects its own IP (ifconfig) and listening port (ss -ltn)
- Shows the client IP on every request
- Replies to `assignment` and `population` (placeholders so far)

