import lightbug.devices as devices
import lightbug.services as services
import lightbug.messages as messages
import lightbug.util.bitmaps show lightbug3030

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
    "Spec": 101,
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
httpMsgService := services.HttpMsg device.name comms --serve=false --port=80 --custom-actions=custom-actions
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
    updateStartupPageClients comms --onlyIfNew=false --connectedClients=connected-clients.size

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
  if resource == "post": resource = "/post" 
  httpMsgService.handle-http-request request writer
  lastPageId = 0 // Just assume that this might have caused a redraw..

lastPageId := 100

sendStartupPage comms/services.Comms --onlyIfNew=true:
  if onlyIfNew and lastPageId == 101: return
  lastPageId = 101
  // TODO display a QR code..?
  comms.send (messages.TextPage.toMsg
      --pageId=101
      --pageTitle="Lightbug @ MWC 2025"
      --line1="Connect to the WiFi hotspot:"
      --line2="$ssid / $password"
  ) --now=true
  comms.send (messages.DrawBitmap.toMsg --pageId=101 --bitmapData=lightbug3030 --bitmapWidth=30 --bitmapHeight=30 --bitmapX=( SCREEN_WIDTH - 30 ) --bitmapY=0) --now=true

updateStartupPageClients comms/services.Comms --onlyIfNew=true --connectedClients/int:
  if lastPageId != 101: return // only update 101 page if it is the last one
  connClientsLine := ""
  if connectedClients >= 1:
    connClientsLine = "Clients: $connectedClients"
  comms.send (messages.TextPage.toMsg
      --pageId=101
      --pageTitle="Lightbug @ MWC 2025"
      --line3="$connClientsLine"
  ) --now=true
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