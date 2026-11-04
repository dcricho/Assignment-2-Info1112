#!/bin/bash
# server.sh - INFO1112 Assignment 2
# Runs forever, waiting for client requests.
# Uses ncat: it runs this script in --handle mode once per connection
# and sends whatever the handler prints back to the client.

# Port the listener is started on. The port actually in use is read back
# from `ss -ltn` below rather than assumed.
LISTEN_PORT=1234
SCRIPT=$(readlink -f "$0")

# Unit page that the "assignment" request downloads, and the name of the
# assessment row to look up on that page (a search key, not output data).
UNIT_URL="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"
ASSIGNMENT_NAME="Assignment 2"

# ABS population data (NSW) and the measure to read from it
# (ERP_P_20 = estimated resident population, total persons).
CSV_URL="https://dbr.abs.gov.au/processedData/csv/STE_1.csv"
POP_MEASURE="ERP_P_20"

# Where assignment.json is written (next to this script)
JSON_FILE="$(dirname "$SCRIPT")/assignment.json"

# Find this container's IP from ifconfig (no hardcoding)
get_ip() {
    ifconfig | grep -oE 'inet (addr:)?[0-9.]+' | grep -oE '[0-9.]+$' | grep -v '^127\.' | head -n 1
}

# Find the port ncat is listening on from ss -ltn.
# Column 4 is "address:port", so keep whatever follows the last colon.
get_port() {
    ss -ltnp 2>/dev/null | awk '/ncat/ {n=split($4,a,":"); print a[n]; exit}'
}

# Handle the "assignment" request:
#  1. curl the unit page and convert it to text with html2text
#  2. display the assignment's rows in the server terminal (stderr)
#  3. extract title, topic, due date and points from the page text
#  4. write assignment.json and send it back to the client (stdout)
# Anything printed to stdout goes back to the client.
handle_assignment() {
    local html text wide line_no title detail topic points due_raw due_date show_no

    html=$(mktemp) || { echo "Error: could not create temp file."; return 1; }
    text=$(mktemp) || { rm -f "$html"; echo "Error: could not create temp file."; return 1; }
    wide=$(mktemp) || { rm -f "$html" "$text"; echo "Error: could not create temp file."; return 1; }

    if ! curl -sS -f -L -A 'Mozilla/5.0' --max-time 20 "$UNIT_URL" -o "$html" 2>&1 >/dev/null; then
        echo "Error: could not download the unit page from $UNIT_URL"
        echo "Error: could not download the unit page." >&2
        rm -f "$html" "$text" "$wide"
        return 1
    fi

    # Normal-width text for display; wide text keeps each table row on one line
    if ! html2text "$html" > "$text" 2>/dev/null || [ ! -s "$text" ] \
       || ! html2text -width 400 "$html" > "$wide" 2>/dev/null || [ ! -s "$wide" ]; then
        echo "Error: could not convert the downloaded page to text."
        echo "Error: html2text conversion failed or produced no output." >&2
        rm -f "$html" "$text" "$wide"
        return 1
    fi

    # Display only this assignment's rows (as in Figure 7): the line that
    # contains the assignment name plus the two lines after it.
    show_no=$(grep -n -m1 "$ASSIGNMENT_NAME" "$text" | cut -d: -f1)
    if [ -n "$show_no" ]; then
        sed -n "${show_no},$((show_no + 2))p" "$text" >&2
    fi

    # Find the row for this assignment; its other columns are on the next line
    line_no=$(grep -n -m1 "$ASSIGNMENT_NAME" "$wide" | cut -d: -f1)
    if [ -z "$line_no" ]; then
        echo "Error: '$ASSIGNMENT_NAME' was not found on the unit page."
        echo "Error: '$ASSIGNMENT_NAME' was not found on the unit page." >&2
        rm -f "$html" "$text" "$wide"
        return 1
    fi

    title=$(sed -n "${line_no}p" "$wide" | grep -oE "$ASSIGNMENT_NAME" | head -n 1)
    detail=$(sed -n "$((line_no + 1))p" "$wide")
    topic=$(printf '%s\n' "$detail" | sed -n 's/.* - \([A-Za-z]*\).*/\1/p')
    points=$(printf '%s\n' "$detail" | grep -oE '[0-9]+%' | head -n 1 | tr -d '%')
    due_raw=$(printf '%s\n' "$detail" | grep -oE 'Due date: [0-9]{2} [A-Za-z]{3} [0-9]{4} at [0-9]{2}:[0-9]{2}' | head -n 1)
    due_date=$(printf '%s\n' "$due_raw" | sed -e 's/^Due date: //' -e 's/ at / /')

    if [ -z "$title" ] || [ -z "$topic" ] || [ -z "$due_date" ] || ! [[ "$points" =~ ^[0-9]+$ ]]; then
        echo "Error: could not extract all assignment details from the unit page."
        echo "Error: extraction failed (title='$title' topic='$topic' due='$due_date' points='$points')." >&2
        rm -f "$html" "$text" "$wide"
        return 1
    fi

    if ! printf '{\n    "title" : "%s",\n    "topic" : "%s",\n    "due_date" : "%s",\n    "points" : %s\n}\n' \
            "$title" "$topic" "$due_date" "$points" > "$JSON_FILE"; then
        echo "Error: could not write $JSON_FILE"
        echo "Error: could not write $JSON_FILE" >&2
        rm -f "$html" "$text" "$wide"
        return 1
    fi

    echo "----- assignment.json -----" >&2
    cat "$JSON_FILE" >&2

    # Send the JSON file back to the client
    cat "$JSON_FILE"
    rm -f "$html" "$text" "$wide"
}

# Handle the "population" request:
#  1. download STE_1.csv with curl
#  2. read the year headers and the total-population row, building
#     "year,population" pairs (empty cells are skipped)
#  3. display the latest year's NSW population (server terminal and client)
handle_population() {
    local csv pairs latest year pop

    csv=$(mktemp) || { echo "Error: could not create temp file."; return 1; }
    pairs=$(mktemp) || { rm -f "$csv"; echo "Error: could not create temp file."; return 1; }

    if ! curl -sS -f -L --max-time 20 "$CSV_URL" -o "$csv" 2>/dev/null || [ ! -s "$csv" ]; then
        echo "Error: could not download the population data from $CSV_URL"
        echo "Error: could not download the population data." >&2
        rm -f "$csv" "$pairs"
        return 1
    fi

    # Row 1 holds the years (from column 4 on); the measure row holds the values
    tr -d '"\r' < "$csv" | awk -F, -v code="$POP_MEASURE" '
        NR == 1 { for (i = 4; i <= NF; i++) year[i] = $i; next }
        $1 == code {
            for (i = 4; i <= NF; i++) if ($i != "") print year[i] "," $i
            exit
        }' > "$pairs"

    if [ ! -s "$pairs" ]; then
        echo "Error: no population data found for measure '$POP_MEASURE' in the CSV."
        echo "Error: no population data found for measure '$POP_MEASURE'." >&2
        rm -f "$csv" "$pairs"
        return 1
    fi

    latest=$(tail -n 1 "$pairs")
    year=${latest%%,*}
    pop=${latest##*,}

    if ! [[ "$year" =~ ^[0-9]{4}$ ]] || ! [[ "$pop" =~ ^[0-9]+$ ]]; then
        echo "Error: could not read the latest population figure (got '$latest')."
        echo "Error: could not read the latest population figure (got '$latest')." >&2
        rm -f "$csv" "$pairs"
        return 1
    fi

    echo "Latest NSW population ($year): $pop" >&2
    echo "Latest NSW population ($year): $pop"
    rm -f "$csv" "$pairs"
}

# Runs once per client connection. stdin/stdout are the client's socket:
# the reply goes to stdout (back to the client), logs go to stderr (terminal).
handle_request() {
    local request
    read -r request
    request=$(printf '%s' "$request" | tr -d '\r')

    echo "Connection received on ${NCAT_REMOTE_ADDR:-unknown} ${NCAT_REMOTE_PORT:-unknown}" >&2
    echo "Received request: $request" >&2

    case "$request" in
        assignment|asssignment)
            handle_assignment
            ;;
        population)
            handle_population
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