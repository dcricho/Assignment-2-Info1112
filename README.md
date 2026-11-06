# INFO1112 Assignment 2

`server.sh` is a Bash server that runs inside an Alpine Docker container and answers requests from clients over TCP. It finds its own IP (`ifconfig`) and listening port (`ss -ltn`) instead of hardcoding them.

## Setup

Create the container (from the host):

    docker run -it --name myserver -p 1234:1234 alpine sh

Install the required packages inside the container:

    apk add bash curl html2text net-tools iproute2 nmap-ncat netcat-openbsd python3 py3-matplotlib

`ncat` (package `nmap-ncat`) is required: the server uses it so each connection can be answered. `python3` and `py3-matplotlib` are only needed for the population plot.

## Run

Copy the script into the container and start it:

    docker cp server.sh myserver:/server.sh
    docker exec -it myserver bash /server.sh

On Git Bash for Windows, use `bash //server.sh` or prefix the command with `MSYS_NO_PATHCONV=1`. Make sure `server.sh` has LF line endings.

## Requests

Send these from a client, using the IP printed by the server:

    echo assignment | nc 172.17.0.2 1234
    echo population | nc 172.17.0.2 1234
    echo population.png | nc 172.17.0.2 1234 > population.png
    echo "poi Sydney Opera House" | nc 172.17.0.2 1234
    echo "poi -33.8688,151.2093" | nc 172.17.0.2 1234

- `assignment`: curls the unit page, converts it with `html2text`, shows the Assignment 2 rows on the server, and returns `assignment.json` (title, topic, due date, points), all extracted from the page.
- `population`: downloads `STE_1.csv`, reads the year and population pairs with Bash, and prints the latest NSW population. It also builds `population.png`.
- `population.png`: returns the plot image bytes (save them with `> population.png`).
- `poi <name or lat,lon>`: returns a JSON list of neighbouring POIs.

Each request shows `Connection received on <client ip> <port>` on the server. Failures (download, conversion, missing data) print an error message.

## Test cases

- **(a) Server not running:** with the server stopped, `nc` fails to connect and returns a non-zero exit code. See the Test A screenshot in `screenshots/`.
- **(b) Busy server:** while a request from one IP is being handled, a second request from the same IP is rejected, using a per-IP lock directory. A request from a different IP is still served. See the Test B screenshot in `screenshots/`.
- **Environment setup:** `screenshots/Server Screenshot.png` and `screenshots/Client Screenshot.png` show the `nc` connection between container and host.

## Assumptions

- The brief does not define "neighbouring POIs". I used a built-in table of 15 Sydney POIs and treat any POI within 2 km (haversine distance) as a neighbour. A query is either a POI name or `lat,lon`.
- The brief asks for `population.png` to be sent back. Raw image bytes would corrupt the terminal output, so the image is sent on a separate `population.png` request, and the `population` reply tells the client this.
- `ss -ltn` can only show a port once something is listening, so the server starts the listener on port 1234 first and then reads the port back with `ss -ltnp`.
- `ncat` is needed because it runs the handler per connection and returns its output to the client. An earlier attempt with plain `nc` and a named pipe logged requests but never replied, and I did not find the cause.

## AI acknowledgment

The Python plotting code embedded in `server.sh` (`plot_script`) was created with the help of an AI assistant (Claude), as the brief allows. The year and population data is read from the CSV by Bash, and Python only draws the line plot.

