#!/bin/bash
# server.sh - INFO1112 Assignment 2

# Settings. ASSIGNMENT_NAME and POP_MEASURE are search keys, not output values, so nothing is hardcoded.
LISTEN_PORT=1234
# readlink -f turns $0 into the full path of this file, because ncat must re-run this same script.
SCRIPT=$(readlink -f "$0")
UNIT_URL="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"
ASSIGNMENT_NAME="Assignment 2"
CSV_URL="https://dbr.abs.gov.au/processedData/csv/STE_1.csv"
POP_MEASURE="ERP_P_20"
# POIs within this many km of the query count as "neighbouring".
POI_RADIUS_KM=2
# dirname strips the filename, so the output files are saved next to the script.
JSON_FILE="$(dirname "$SCRIPT")/assignment.json"
POI_FILE="$(dirname "$SCRIPT")/poi.json"
POP_PNG="$(dirname "$SCRIPT")/population.png"

# Finds the container's IP from ifconfig instead of hardcoding it.
get_ip() {
    # grep -o prints only the match, -E allows regex; (addr:)? covers both ifconfig output styles.
    # grep -v '^127\.' drops the loopback address; head -n 1 keeps the first remaining IP.
    ifconfig | grep -oE 'inet (addr:)?[0-9.]+' | grep -oE '[0-9.]+$' | grep -v '^127\.' | head -n 1
}

# Finds the listening port from ss instead of hardcoding it.
get_port() {
    # ss flags: -l listening, -t TCP, -n numeric ports, -p show the owning process.
    # awk picks the ncat line; split($4,a,":") cuts "0.0.0.0:1234" at the colons and a[n] is the port.
    ss -ltnp 2>/dev/null | awk '/ncat/ {n=split($4,a,":"); print a[n]; exit}'
}

# The POI table (name|latitude|longitude), built in so server.sh works as a single file.
poi_data() {
    cat <<'EOF'
Sydney Opera House|-33.8568|151.2153
Sydney Harbour Bridge|-33.8523|151.2108
Circular Quay|-33.8611|151.2108
The Rocks|-33.8587|151.2090
Museum of Contemporary Art|-33.8599|151.2093
Royal Botanic Garden Sydney|-33.8642|151.2166
Sydney Tower Eye|-33.8704|151.2089
Queen Victoria Building|-33.8718|151.2067
Town Hall|-33.8731|151.2065
Darling Harbour|-33.8734|151.1988
Central Station|-33.8830|151.2063
University of Sydney|-33.8888|151.1873
Taronga Zoo|-33.8433|151.2410
Bondi Beach|-33.8908|151.2743
Manly Beach|-33.7969|151.2880
EOF
}

# The line-plot script. It is written to a temp file and run with python3 by make_plot.
# The quoted 'EOF' stops bash expanding anything inside the Python code.
plot_script() {
    cat <<'EOF'
# AI ACKNOWLEDGMENT: this plotting code was created with the help of an AI assistant (Claude)
# for INFO1112 Assignment 2, as the brief allows. The year,population data is read from the CSV by Bash
# (see handle_population in server.sh); this script only draws the line plot from that data.
import sys
import matplotlib
matplotlib.use("Agg")  # draw to a file, no display needed
import matplotlib.pyplot as plt

pairs_file, out_file = sys.argv[1], sys.argv[2]
years, pops = [], []
for line in open(pairs_file):
    line = line.strip()
    if line:
        year, pop = line.split(",")
        years.append(int(year))
        pops.append(int(pop))

plt.figure(figsize=(8, 5))
plt.plot(years, pops, marker="o")
plt.xticks(years)
plt.ticklabel_format(style="plain", axis="y")
plt.xlabel("Year")
plt.ylabel("Population")
plt.title("NSW estimated resident population")
plt.grid(True)
plt.tight_layout()
plt.savefig(out_file, dpi=100)
EOF
}

# Downloads the CSV and turns its year columns into "year,population" pairs. Usage: fetch_pairs <pairs_file>
# On failure it prints an error to the client (stdout) and the server (stderr) and returns 1.
fetch_pairs() {
    local pairs="$1" csv

    csv=$(mktemp) || { echo "Error: could not create temp file."; return 1; }

    # curl flags: -s silent, -S show errors, -f fail on HTTP errors, -L follow redirects, --max-time stops hanging.
    if ! curl -sS -f -L --max-time 20 "$CSV_URL" -o "$csv" 2>/dev/null || [ ! -s "$csv" ]; then
        echo "Error: could not download the population data from $CSV_URL"
        echo "Error: could not download the population data." >&2
        rm -f "$csv"
        return 1
    fi

    # tr -d strips quote marks and Windows line endings. awk -F, splits on commas, -v passes in the measure code.
    # Line 1 stores each year header (columns 4 onward); the ERP_P_20 row prints "year,value" for each non-empty cell.
    tr -d '"\r' < "$csv" | awk -F, -v code="$POP_MEASURE" '
        NR == 1 { for (i = 4; i <= NF; i++) year[i] = $i; next }
        $1 == code {
            for (i = 4; i <= NF; i++) if ($i != "") print year[i] "," $i
            exit
        }' > "$pairs"
    rm -f "$csv"

    # No pairs means the measure row was not found in the CSV.
    if [ ! -s "$pairs" ]; then
        echo "Error: no population data found for measure '$POP_MEASURE' in the CSV."
        echo "Error: no population data found for measure '$POP_MEASURE'." >&2
        return 1
    fi
}

# Draws the plot from a pairs file into POP_PNG using the embedded Python. Usage: make_plot <pairs_file>
make_plot() {
    local pairs="$1" py

    # The plot needs python3 and matplotlib in the container.
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: python3 not found. Install it with: apk add python3 py3-matplotlib"
        echo "Error: python3 not found." >&2
        return 1
    fi

    py=$(mktemp) || { echo "Error: could not create temp file."; return 1; }
    plot_script > "$py"
    rm -f "$POP_PNG"

    # The plot is only a success if python exits cleanly AND the PNG file exists and is not empty.
    if ! python3 "$py" "$pairs" "$POP_PNG" 2>/dev/null || [ ! -s "$POP_PNG" ]; then
        echo "Error: could not generate the population plot (is py3-matplotlib installed?)."
        echo "Error: plot generation failed." >&2
        rm -f "$py" "$POP_PNG"
        return 1
    fi
    rm -f "$py"
}

# Handles "assignment": downloads the unit page, shows the Assignment 2 rows, then builds and sends assignment.json.
handle_assignment() {
    # local keeps these variables inside this function.
    local html text wide line_no title detail topic points due_raw due_date show_no

    # mktemp makes a uniquely named temp file; the || part runs only if that fails.
    html=$(mktemp) || { echo "Error: could not create temp file."; return 1; }
    text=$(mktemp) || { rm -f "$html"; echo "Error: could not create temp file."; return 1; }
    wide=$(mktemp) || { rm -f "$html" "$text"; echo "Error: could not create temp file."; return 1; }

    # curl flags: -s silent, -S still show errors, -f fail on HTTP errors, -L follow redirects,
    # -A set a browser-like user agent, --max-time 20 stops it hanging, -o saves to the temp file.
    if ! curl -sS -f -L -A 'Mozilla/5.0' --max-time 20 "$UNIT_URL" -o "$html" 2>&1 >/dev/null; then
        # First echo goes to the client (stdout), second to the server terminal (>&2).
        echo "Error: could not download the unit page from $UNIT_URL"
        echo "Error: could not download the unit page." >&2
        rm -f "$html" "$text" "$wide"
        return 1
    fi

    # Two conversions: normal width for display (matches Figure 7), -width 400 so each table row stays on one line for parsing.
    # [ ! -s file ] is true when the file is empty, which means the conversion failed.
    if ! html2text "$html" > "$text" 2>/dev/null || [ ! -s "$text" ] \
       || ! html2text -width 400 "$html" > "$wide" 2>/dev/null || [ ! -s "$wide" ]; then
        echo "Error: could not convert the downloaded page to text."
        echo "Error: html2text conversion failed or produced no output." >&2
        rm -f "$html" "$text" "$wide"
        return 1
    fi

    # grep -n -m1 finds the first match as "line:text"; cut -d: -f1 keeps just the line number.
    show_no=$(grep -n -m1 "$ASSIGNMENT_NAME" "$text" | cut -d: -f1)
    # [ -n ] means the variable is not empty; sed -n 'X,Yp' prints lines X to Y, here the match plus two lines after it.
    if [ -n "$show_no" ]; then
        sed -n "${show_no},$((show_no + 2))p" "$text" >&2
    fi

    # Finds the row by its label in the wide text; [ -z ] means the variable is empty (row not found).
    line_no=$(grep -n -m1 "$ASSIGNMENT_NAME" "$wide" | cut -d: -f1)
    if [ -z "$line_no" ]; then
        echo "Error: '$ASSIGNMENT_NAME' was not found on the unit page."
        echo "Error: '$ASSIGNMENT_NAME' was not found on the unit page." >&2
        rm -f "$html" "$text" "$wide"
        return 1
    fi

    # The title is on the matched line; the other columns are on the line below (detail).
    title=$(sed -n "${line_no}p" "$wide" | grep -oE "$ASSIGNMENT_NAME" | head -n 1)
    detail=$(sed -n "$((line_no + 1))p" "$wide")
    # sed captures the word after " - " (as in "Programming task - Networking") and prints only that.
    topic=$(printf '%s\n' "$detail" | sed -n 's/.* - \([A-Za-z]*\).*/\1/p')
    # Finds "15%", then tr -d '%' deletes the percent sign so points is a bare number.
    points=$(printf '%s\n' "$detail" | grep -oE '[0-9]+%' | head -n 1 | tr -d '%')
    due_raw=$(printf '%s\n' "$detail" | grep -oE 'Due date: [0-9]{2} [A-Za-z]{3} [0-9]{4} at [0-9]{2}:[0-9]{2}' | head -n 1)
    # Two sed edits: remove "Due date: " and replace " at " with a space, giving the Figure 9 format.
    due_date=$(printf '%s\n' "$due_raw" | sed -e 's/^Due date: //' -e 's/ at / /')

    # Refuses to write the JSON if any field is empty or points is not a number ([[ =~ ]] is a regex test).
    if [ -z "$title" ] || [ -z "$topic" ] || [ -z "$due_date" ] || ! [[ "$points" =~ ^[0-9]+$ ]]; then
        echo "Error: could not extract all assignment details from the unit page."
        echo "Error: extraction failed (title='$title' topic='$topic' due='$due_date' points='$points')." >&2
        rm -f "$html" "$text" "$wide"
        return 1
    fi

    # printf fills each %s with a value; points has no quotes so it stays a number, as in Figure 9.
    if ! printf '{\n    "title" : "%s",\n    "topic" : "%s",\n    "due_date" : "%s",\n    "points" : %s\n}\n' \
            "$title" "$topic" "$due_date" "$points" > "$JSON_FILE"; then
        echo "Error: could not write $JSON_FILE"
        echo "Error: could not write $JSON_FILE" >&2
        rm -f "$html" "$text" "$wide"
        return 1
    fi

    # Shows the JSON on the server terminal (stderr).
    echo "----- assignment.json -----" >&2
    cat "$JSON_FILE" >&2

    # Sends the JSON to the client (stdout), then cleans up the temp files.
    cat "$JSON_FILE"
    rm -f "$html" "$text" "$wide"
}

# Handles "population": gets the year,population pairs, reports the latest, and builds population.png on the server.
handle_population() {
    local pairs latest year pop

    pairs=$(mktemp) || { echo "Error: could not create temp file."; return 1; }

    # Download and parse the CSV; fetch_pairs prints its own errors.
    if ! fetch_pairs "$pairs"; then
        rm -f "$pairs"
        return 1
    fi

    # tail -n 1 takes the last (latest) pair; %%,* keeps what is before the comma (year), ##*, keeps what is after (population).
    latest=$(tail -n 1 "$pairs")
    year=${latest%%,*}
    pop=${latest##*,}

    # Checks the year is 4 digits and the population is a number.
    if ! [[ "$year" =~ ^[0-9]{4}$ ]] || ! [[ "$pop" =~ ^[0-9]+$ ]]; then
        echo "Error: could not read the latest population figure (got '$latest')."
        echo "Error: could not read the latest population figure (got '$latest')." >&2
        rm -f "$pairs"
        return 1
    fi

    # Shows the result on the server terminal, then sends it to the client.
    echo "Latest NSW population ($year): $pop" >&2
    echo "Latest NSW population ($year): $pop"

    # Builds the plot; if it fails, make_plot has already printed the error.
    if make_plot "$pairs"; then
        echo "Plot saved on the server as $POP_PNG" >&2
        echo "Plot generated. Send the request 'population.png' to receive the image."
    fi
    rm -f "$pairs"
}

# Handles "population.png": rebuilds the plot and sends the raw PNG bytes to the client (save with: nc ... > population.png).
handle_population_png() {
    local pairs

    pairs=$(mktemp) || { echo "Error: could not create temp file."; return 1; }

    if ! fetch_pairs "$pairs" || ! make_plot "$pairs"; then
        rm -f "$pairs"
        return 1
    fi

    echo "Sending $POP_PNG to the client" >&2
    # stdout goes to the client, so cat sends the image bytes.
    cat "$POP_PNG"
    rm -f "$pairs"
}

# Handles "poi <name>" or "poi <lat>,<lon>": returns a JSON list of POIs within POI_RADIUS_KM.
handle_poi() {
    local query="$1" data coords lat lon self="" re neighbours

    # Removes quotes and backslashes so the query cannot break the JSON.
    query=${query//[\"\\]/}
    if [ -z "$query" ]; then
        echo "Error: no POI given. Usage: poi <name> or poi <lat>,<lon>"
        return 1
    fi

    data=$(mktemp) || { echo "Error: could not create temp file."; return 1; }
    poi_data > "$data"

    # Coordinates look like -33.86,151.21; anything else is treated as a POI name.
    re='^-?[0-9]+(\.[0-9]+)?, *-?[0-9]+(\.[0-9]+)?$'
    if [[ "$query" =~ $re ]]; then
        lat=${query%%,*}
        lon=${query##*,}
        lon=${lon// /}
    else
        # Case-insensitive exact name match; prints "lat lon" for the first hit.
        coords=$(awk -F'|' -v q="$query" 'tolower($1) == tolower(q) {print $2 " " $3; exit}' "$data")
        if [ -z "$coords" ]; then
            echo "Error: POI '$query' not found. Known POIs: $(cut -d'|' -f1 "$data" | tr '\n' ',' | sed 's/,$//')"
            echo "Error: POI '$query' not found." >&2
            rm -f "$data"
            return 1
        fi
        lat=${coords% *}
        lon=${coords#* }
        # A named POI is not its own neighbour.
        self=$query
    fi

    # awk computes the haversine distance (km) to every POI and prints one JSON object per neighbour within the radius.
    neighbours=$(awk -F'|' -v lat="$lat" -v lon="$lon" -v r="$POI_RADIUS_KM" -v self="$self" '
        BEGIN { pi = atan2(0, -1) }
        {
            if (self != "" && tolower($1) == tolower(self)) next
            dlat = ($2 - lat) * pi / 180
            dlon = ($3 - lon) * pi / 180
            a = sin(dlat / 2) ^ 2 + cos(lat * pi / 180) * cos($2 * pi / 180) * sin(dlon / 2) ^ 2
            d = 6371 * 2 * atan2(sqrt(a), sqrt(1 - a))
            if (d <= r) printf "%s        {\"name\" : \"%s\", \"distance_km\" : %.2f}", (n++ ? ",\n" : ""), $1, d
        }' "$data")

    # Writes the JSON file; an empty list is still valid JSON.
    if ! printf '{\n    "query" : "%s",\n    "latitude" : %s,\n    "longitude" : %s,\n    "radius_km" : %s,\n    "neighbours" : [\n%s\n    ]\n}\n' \
            "$query" "$lat" "$lon" "$POI_RADIUS_KM" "$neighbours" > "$POI_FILE"; then
        echo "Error: could not write $POI_FILE"
        echo "Error: could not write $POI_FILE" >&2
        rm -f "$data"
        return 1
    fi

    # Shows the JSON on the server terminal, sends it to the client, then cleans up.
    echo "----- poi.json -----" >&2
    cat "$POI_FILE" >&2
    cat "$POI_FILE"
    rm -f "$data"
}

# Runs once per client connection: reads the request, logs who connected, rejects a repeat request from a busy IP, and calls the matching handler.
handle_request() {
    local request
    # read -r reads one line from the client's socket; -r stops backslashes being treated as escapes.
    read -r request
    # Removes carriage returns that Windows clients can append, which would stop the case below matching.
    request=$(printf '%s' "$request" | tr -d '\r')

    # NCAT_REMOTE_ADDR and NCAT_REMOTE_PORT are set by ncat for each connection; :-unknown is a fallback.
    echo "Connection received on ${NCAT_REMOTE_ADDR:-unknown} ${NCAT_REMOTE_PORT:-unknown}" >&2
    echo "Received request: $request" >&2

    # One lock directory per client IP. mkdir is atomic and fails if the directory already exists,
    # which means this IP already has a request being handled, so the new one is rejected.
    # LOCK_DIR is deliberately not local, so the exit trap below can still see it.
    LOCK_DIR="/tmp/server_busy_${NCAT_REMOTE_ADDR:-unknown}"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "Error: a request from ${NCAT_REMOTE_ADDR:-unknown} is already being handled. Request rejected."
        echo "Rejected request from ${NCAT_REMOTE_ADDR:-unknown}: previous request still in progress." >&2
        return 1
    fi
    # Removes the lock when this handler process exits, however it exits.
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

    # case routes the request; "asssignment" (three s's) is accepted because the brief's example spells it that way.
    case "$request" in
        assignment|asssignment)
            handle_assignment
            ;;
        population)
            handle_population
            ;;
        # The plot image itself, sent as raw bytes.
        population.png)
            handle_population_png
            ;;
        # "poi <name or lat,lon>": ${request#* } strips everything up to the first space, leaving the argument.
        poi\ *|POI\ *)
            handle_poi "${request#* }"
            ;;
        # Default branch: any other request gets an error listing the valid ones.
        *)
            echo "Error: unknown request '$request'. Valid requests: assignment, population, population.png, poi <name or lat,lon>"
            ;;
    esac
}

# ncat re-runs this script with --handle for each connection; this handles one request and exits.
if [ "$1" = "--handle" ]; then
    handle_request
    exit 0
fi

# Server mode starts here. command -v checks ncat is installed; ! negates it, so this runs when it is missing.
if ! command -v ncat >/dev/null 2>&1; then
    echo "Error: ncat not found. Install it with: apk add nmap-ncat" >&2
    exit 1
fi

# Clears any lock directories left over from a previous run, so a crash cannot block clients.
rm -rf /tmp/server_busy_* 2>/dev/null

SERVER_IP=$(get_ip)

# ncat flags: -l listen, -k keep listening after each client leaves, -p the port,
# --sh-exec runs the handler for each connection, & runs ncat in the background.
ncat -l -k -p "$LISTEN_PORT" --sh-exec "bash $SCRIPT --handle" &
# $! is the process ID of the background job we just started.
NCAT_PID=$!
# On exit, Ctrl+C (INT) or termination, kill ncat too so port 1234 is freed.
trap 'kill "$NCAT_PID" 2>/dev/null' EXIT INT TERM
# Gives ncat a second to start before we check on it.
sleep 1

# kill -0 sends no signal; it only tests that ncat is still alive (it dies at once if the port is in use).
if ! kill -0 "$NCAT_PID" 2>/dev/null; then
    echo "Error: could not start listener on port $LISTEN_PORT (already in use?)." >&2
    exit 1
fi

# Reads the real port back from ss now that ncat is listening.
SERVER_PORT=$(get_port)

# Stops with an error if either the IP or the port could not be found.
if [ -z "$SERVER_IP" ] || [ -z "$SERVER_PORT" ]; then
    echo "Error: could not detect server IP or port." >&2
    exit 1
fi

echo "The server is running at $SERVER_IP, port=$SERVER_PORT"

# Keeps the script alive for as long as ncat runs; with -k this is what makes the server run forever.
wait "$NCAT_PID"