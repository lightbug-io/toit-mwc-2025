import lightbug.devices as devices
import lightbug.services as services
import lightbug.messages as messages
import lightbug.protocol as protocol
import lightbug.util.resilience show catchAndRestart
import lightbug.util.bitmaps show lightbug3030
import lightbug.util.bytes show stringifyAllBytes

import .preset-screens

import log
import monitor

import encoding.url

import net
import net.tcp
import net.udp
import net.wifi

import system.assets
import encoding.tison

import http
import dns_simple_server as dns

// TODO this should be provided to us...
SCREEN_WIDTH := 250
SCREEN_HEIGHT := 122

custom-actions := {
  "MWC Pages": {
    "WiFi": 101,
    "Spec": SPEC-PAGE,
    "Hardware": HARDWARE-PAGE,
    "Containers": CONTAINERS-PAGE,
    "Shipping": SHIPPING-PAGE,
    "Tagline": TAGLINE-PAGE,
  },
}

// Setup Lightbug device services
device := devices.ZCard
comms := services.Comms --device=device
httpMsgService := services.HttpMsg device comms --serve=false --port=80 --custom-actions=custom-actions --response-message-formatter=(:: | writer msg prefix |
  // TODO it would be nice to have a default one of these provided by httpMsgService
  if msg.type == messages.LastPosition.MT:
    data := messages.LastPosition.fromData msg.data
    writer.out.write "$prefix Last position: $data\n"
  else if msg.type == messages.Status.MT:
    data := messages.Status.fromData msg.data
    writer.out.write "$prefix Status: $data\n"
  else if msg.type == messages.DeviceIds.MT:
    data := messages.DeviceIds.fromData msg.data
    writer.out.write "$prefix Device IDs: $data\n"
  else if msg.type == messages.DeviceTime.MT:
    data := messages.DeviceTime.fromData msg.data
    writer.out.write "$prefix Device time: $data\n"
  else if msg.type == messages.Temperature.MT:
    data := messages.Temperature.fromData msg.data
    writer.out.write "$prefix Temperature: $data\n"
  else if msg.type == messages.Pressure.MT:
    data := messages.Pressure.fromData msg.data
    writer.out.write "$prefix Pressure: $data\n"
  else if msg.type == messages.BatteryStatus.MT:
    data := messages.BatteryStatus.fromData msg.data
    writer.out.write "$prefix Battery status: $data\n"
  else if msg.type == messages.Heartbeat.MT:
    writer.out.write "$prefix Heartbeat\n"
  else if msg.type == 1004:
    // field 2 is the data
    bytes := msg.data.getData 2
    ascii := msg.data.getDataAscii 2
    writer.out.write "$prefix LORA message: ascii:$(ascii) bytes:$(stringifyAllBytes bytes --short=true --commas=false --hex=false)\n"
  else:
    msgStatus := "null"
    if msg.msgStatus != null:
      msgStatus = protocol.Header.STATUS_MAP.get msg.msgStatus
    writer.out.write "$prefix Received message ($msgStatus): $(stringifyAllBytes msg.bytesForProtocol --short=true --commas=false --hex=false)\n"
)
msgPrinter := services.MsgPrinter comms

// Have some state
connected-clients := {:}
ssid := ""
password := ""

isInDevelopment -> bool:
  defines := assets.decode.get "jag.defines"
    --if-present=: tison.decode it
    --if-absent=: {:}
  if defines is not Map:
    throw "defines are malformed"
  return defines.get "lb-dev" --if-absent=(:false) --if-present=(:true)

main:
  // TODO loop around and generate a new one each time?
  ssid = randomSSID
  password = randomPassword
  log.info "Running with ssid $ssid and password $password"

  comms.send (messages.BuzzerControl.doMsg --duration=50 --frequency=3.0) --now=true // beep on startup
  sendStartupPage comms --onlyIfNew=false

  in := comms.inbox "lb/mwc" --size=10
  task:: catchAndRestart "" (::
    while true:
      msg := in.receive
      // LORA and heartbeats
      if msg.type == 1004 or msg.type == messages.Heartbeat.MT:
        httpMsgService.queue-messages-for-polling msg
  )

  if isInDevelopment:
    // Just serve the HTTP server
    run_http net.open httpMsgService
  else:
    // Start the access point loop
    while true:
      network_ap := wifi.establish
          --ssid=ssid
          --password=password
      try:
        Task.group --required=2 [
          :: run_dns network_ap,
          :: run_http network_ap httpMsgService,
        ]
      finally:
        network_ap.close

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
  server := http.Server --logger=(log.Logger log.INFO-LEVEL log.DefaultTarget) --max-tasks=25
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
  
  // Record connected clients, and update page on new clients :D
  connClients := connected-clients.size
  connected-clients[request.connection_.socket_.peer-address.ip] = true
  if connected-clients.size > connClients:
    log.info "New client: $request.connection_.socket_.peer-address.ip"
    updateStartupPageClients comms

  if resource == "custom":
    body := request.body.read-all
    bodyS := body.to-string
    writer.headers.set "Content-Type" "text/plain"
    writer.write_headers 200
    if bodyS == "101":
      sendStartupPage comms --onlyIfNew=false
    if bodyS == "$SPEC-PAGE" or bodyS == "$HARDWARE-PAGE" or bodyS == "$CONTAINERS-PAGE" or bodyS == "$SHIPPING-PAGE" or bodyS == "$TAGLINE-PAGE":
      sendPresetPage comms (int.parse bodyS)
      writer.out.write "Received preset page request for $bodyS\n"
    writer.close
      
    return // custom but unknown


  // Normalized for what httpMsgService expects
  if resource == "index.html": resource = "/" 
  if resource == "poll": resource = "/poll" 
  if resource == "post":
    resource = "/post" 
    lastPageId = 0 // Just assume that this might have caused a redraw..
  httpMsgService.handle-http-request request writer

lastPageId := 100

sendStartupPage comms/services.Comms --onlyIfNew=true:
  if onlyIfNew and lastPageId == 101: return
  lastPageId = 101
  // TODO display a QR code..?
  line3 := ""
  if connected-clients.size >= 1:
    line3 = "Clients: $connected-clients.size"
  comms.send (messages.TextPage.toMsg
      --pageId=101
      --pageTitle="Lightbug @ MWC 2025"
      --line1="Connect to the WiFi hotspot:"
      --line2="$ssid / $password"
  ) --now=true
  comms.send (messages.DrawBitmap.toMsg --pageId=101 --bitmapData=lightbug3030 --bitmapWidth=30 --bitmapHeight=30 --bitmapX=( SCREEN_WIDTH - 30 ) --bitmapY=0) --now=true

updateStartupPageClients comms/services.Comms:
  if lastPageId != 101: return // only update 101 page if it is the last one
  connClientsLine := ""
  if connected-clients.size >= 1:
    connClientsLine = "Clients: $connected-clients.size"
  comms.send (messages.TextPage.toMsg --pageId=101 --line3="$connClientsLine" ) --now=true // only update line 3
  comms.send (messages.DrawBitmap.toMsg --pageId=101 --bitmapData=lightbug3030 --bitmapWidth=30 --bitmapHeight=30 --bitmapX=( SCREEN_WIDTH - 30 ) --bitmapY=0) --now=true

sendPresetPage comms/services.Comms pageId/int --onlyIfNew=true:
  if onlyIfNew and lastPageId == pageId: return
  lastPageId = pageId
  comms.sendRawBytes presetScreens[pageId] --flush=false // Don't flush, as these are large ammounts of bytes

randomSSID -> string:
  r := random 1000 9999
  return "LB-$r"
randomPassword -> string:
  r := random 1000 9999
  return "pass-$r"