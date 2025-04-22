import lightbug.devices as devices
import lightbug.services as services
import lightbug.messages as messages
import lightbug.protocol as protocol
import lightbug.util.resilience show catch-and-restart
import lightbug.util.bitmaps show lightbug-30-30
import lightbug.util.bytes show stringify-all-bytes

import .preset-screens

import log
import monitor
import gpio

import encoding.url

import net
import net.tcp
import net.udp
import net.wifi

import system.assets
import system.firmware
import encoding.tison

import http
import dns_simple_server as dns

// TODO this should be provided to us...
SCREEN_WIDTH := 250
SCREEN_HEIGHT := 122

// Setup Lightbug device services
device := devices.ZCard
comms/services.Comms? := null
// And some state
ssid := ""
password := ""
ip := ""

isInDevelopment -> bool:
  defines := assets.decode.get "jag.defines"
    --if-present=: tison.decode it
    --if-absent=: {:}
  if defines is not Map:
    throw "defines are malformed"
  return defines.get "lb-dev" --if-absent=(:false) --if-present=(:true)

main:
  catch-and-restart "robustMain" (:: robustMain )

robustMain:
  ssid = randomSSID
  password = randomPassword
  log.info "Running with ssid $ssid and password $password"

  comms = services.Comms --device=device
  httpMsgService := services.HttpMsg device comms 
    --serve=false
    --port=80
    --custom-actions={
      "MWC Pages": {
        "WiFi": "custom:page:$(101)",
        "Spec": "custom:page:$(SPEC-PAGE)",
        "Hardware": "custom:page:$(HARDWARE-PAGE)",
        "Containers": "custom:page:$(CONTAINERS-PAGE)",
        "Shipping": "custom:page:$(SHIPPING-PAGE)",
        "Tagline": "custom:page:$(TAGLINE-PAGE)",
        "Tagline 2": "custom:page:$(TAGLINE2-PAGE)",
      }
    }
    --custom-handlers={
      "page:$(101)": (:: | writer |
        sendStartupPage comms --onlyIfNew=false
        writer.out.write "Showing WiFi page\n"
        ),
      "page:$(SPEC-PAGE)": (:: | writer |
        sendPresetPage comms SPEC-PAGE
        writer.out.write "Showing Spec page\n"
        ),
      "page:$(HARDWARE-PAGE)": (:: | writer |
        sendPresetPage comms HARDWARE-PAGE
        writer.out.write "Showing Hardware page\n"
        ),
      "page:$(CONTAINERS-PAGE)": (:: | writer |
        sendPresetPage comms CONTAINERS-PAGE
        writer.out.write "Showing Containers page\n"
        ),
      "page:$(SHIPPING-PAGE)": (:: | writer |
        sendPresetPage comms SHIPPING-PAGE
        writer.out.write "Showing Shipping page\n"
        ),
      "page:$(TAGLINE-PAGE)": (:: | writer |
        sendPresetPage comms TAGLINE-PAGE
        writer.out.write "Showing Tagline page\n"
        ),
      "page:$(TAGLINE2-PAGE)": (:: | writer |
        sendPresetPage comms TAGLINE2-PAGE
        writer.out.write "Showing Tagline 2 page\n"
        ),
      }
    --subscribe-lora=true
    --listen-and-log-all=true
    --response-message-formatter=(:: | writer msg prefix |
      // TODO it would be nice to have a default one of these provided by httpMsgService
      if msg.type == messages.LastPosition.MT:
        data := messages.LastPosition.from-data msg.data
        writer.out.write "$prefix Last position: $data\n"
      else if msg.type == messages.Status.MT:
        data := messages.Status.from-data msg.data
        writer.out.write "$prefix Status: $data\n"
      else if msg.type == messages.DeviceIds.MT:
        data := messages.DeviceIds.from-data msg.data
        writer.out.write "$prefix Device IDs: $data\n"
      else if msg.type == messages.DeviceTime.MT:
        data := messages.DeviceTime.from-data msg.data
        writer.out.write "$prefix Device time: $data\n"
      else if msg.type == messages.Temperature.MT:
        data := messages.Temperature.from-data msg.data
        writer.out.write "$prefix Temperature: $data\n"
      else if msg.type == messages.Pressure.MT:
        data := messages.Pressure.from-data msg.data
        writer.out.write "$prefix Pressure: $data\n"
      else if msg.type == messages.BatteryStatus.MT:
        data := messages.BatteryStatus.from-data msg.data
        writer.out.write "$prefix Battery status: $data\n"
      else if msg.type == messages.Heartbeat.MT:
        writer.out.write "$prefix Heartbeat\n"
      else if msg.type == 1004:
        // field 2 is the data
        bytes := msg.data.get-data 2
        ascii := msg.data.get-data-ascii 2
        writer.out.write "$prefix LORA message: ascii:$(ascii) bytes:$(stringify-all-bytes bytes --short=true --commas=false --hex=false)\n"
      else:
        msg-status := "null"
        if msg.msg-status != null:
          msg-status = protocol.Header.STATUS_MAP.get msg.msg-status
        writer.out.write "$prefix Received message ($msg-status): $(stringify-all-bytes msg.bytes-for-protocol --short=true --commas=false --hex=false)\n"
    )

  while true:
    // Get the network
    network/net.Interface? := null
    if isInDevelopment:
      network = net.open
    else:
      network = wifi.establish
        --ssid=ssid
        --password=password

    // Run the app, depending on mode
    try:
      ip = "$(network.address)"
      comms.send (messages.BuzzerControl.do-msg --duration=50 --frequency=3.0) --now=true // beep on startup
      sendStartupPage comms --onlyIfNew=false

      if isInDevelopment:
        // Just serve the HTTP server
        run_http net.open httpMsgService
      else:
        Task.group --required=2 [
          :: run_dns network,
          :: run_http network httpMsgService,
        ]
    finally:
      network.close

run_dns network/net.Interface -> none:
  device_ip_address := network.address
  socket := network.udp_open --port=53
  hosts := dns.SimpleDnsServer device_ip_address  // Answer the device IP to all queries.

  try:
    while not Task.current.is_canceled:
      datagram/udp.Datagram := socket.receive
      response := hosts.lookup datagram.data
      if not response: continue
      socket.send (udp.Datagram response datagram.address)
  finally:
    socket.close

run_http network/net.Interface httpMsgService/services.HttpMsg:
  socket := network.tcp_listen 80
  server := http.Server --logger=(log.Logger log.INFO-LEVEL log.DefaultTarget) --max-tasks=10
  server.listen socket:: | request writer |
    handle_http_request request writer httpMsgService

handle_http_request request/http.RequestIncoming writer/http.ResponseWriter? httpMsgService/services.HttpMsg:
  query := url.QueryString.parse request.path
  resource := query.resource

  // Try to look like a captive portal?
  if resource == "/": resource = "index.html"
  if resource == "/hotspot-detect.html": resource = "index.html"  // Needed for iPhones.
  if resource.starts_with "/": resource = resource[1..]
  {
    // Used by Android captive portal detection.
    "generate_204": "/", 
    "gen_204": "/",
  }.get resource --if_present=:
    writer.headers.set "Location" it
    writer.write_headers 302
    return

  // Normalized for what httpMsgService expects
  if resource == "index.html": resource = "/" 
  if resource == "poll": resource = "/poll" 
  if resource == "post":
    resource = "/post" 
    lastpage-id = 0 // Just assume that this might have caused a redraw..
  httpMsgService.handle-http-request request writer

lastpage-id := 100

sendStartupPage comms/services.Comms --onlyIfNew=true:
  if onlyIfNew and lastpage-id == 101: return
  lastpage-id = 101

  // TODO display a QR code..?

  line2 := ""
  line3 := ""
  line4 := "IP: $ip"

  if isInDevelopment:
    effective := firmware.config["wifi"]
    fw-ssid/string? := effective.get wifi.CONFIG-SSID
    // fw-password/string := effective.get wifi.CONFIG-PASSWORD --if-absent=: ""
    line2 = "SSID: $fw-ssid"
    line3 = "Pass: ******" // Blank out any pre configured password
  else:
    line2 = "SSID: ssid"
    line3 = "Pass: $password"

  comms.send --now=true 
    messages.TextPage.to-msg
      --page-id=101
      --redraw-type=5 // ClearDontDraw
      --page-title="Lightbug @ Hardware Pioneers"
      --line1="Connect to the WiFi..."
      --line2=line2
      --line3=line3
      --line4=line4

  comms.send --now=true
    messages.DrawBitmap.to-msg
      --page-id=101
      --redraw-type=4 // FullRedrawWithoutClear
      --bitmap-data=lightbug-30-30
      --bitmap-width=30
      --bitmap-height=30
      --bitmap-x=( SCREEN_WIDTH - 30 )
      --bitmap-y=( SCREEN_HEIGHT - 30 )

sendPresetPage comms/services.Comms page-id/int --onlyIfNew=true:
  if onlyIfNew and lastpage-id == page-id: return
  lastpage-id = page-id
  comms.send-raw-bytes presetScreens[page-id] --flush=false // Don't flush, as these are large amounts of bytes

randomSSID -> string:
  r := random 1000 9999
  return "LB-$r"
randomPassword -> string:
  r := random 1000 9999
  return "pass-$r"