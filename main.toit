import lightbug.devices as devices
import lightbug.services as services
import lightbug.messages as messages
import lightbug.util.bitmaps show lightbug3030

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

// Setup Lightbug device services
device := devices.ZCard
comms := services.Comms --device=device
httpMsgService := services.HttpMsg device.name comms --serve=false --port=80
msgPrinter := services.MsgPrinter comms

// Have some state
connected-clients := {:}

isInDevelopment -> bool:
  defines := assets.decode.get "jag.defines"
    --if-present=: tison.decode it
    --if-absent=: {:}
  if defines is not Map:
    throw "defines are malformed"
  return defines.get "lb-dev" --if-absent=(:false) --if-present=(:true)

main:
  // TODO loop around and generate a new one each time..
  ssid := randomSSID
  password := randomPassword
  log.info "Running with ssid $ssid and password $password"

  sendStartupPageAndBeep comms ssid password --onlyIfNew=false

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
    sendConnectedPageAndBeep comms --onlyIfNew=false --connectedClients=connected-clients.size

  // Normalized for what httpMsgService expects
  if resource == "index.html": resource = "/" 
  if resource == "post": resource = "/post" 
  httpMsgService.handle-http-request request writer

lastPageId := 100

sendStartupPageAndBeep comms/services.Comms ssid/string password/string --onlyIfNew=true:
  if onlyIfNew and lastPageId == 101: return
  lastPageId = 101
  comms.send (messages.BuzzerControl.doMsg --duration=50 --frequency=3.0)
  // TODO display a QR code..?
  comms.send (messages.TextPage.toMsg
      --pageId=101
      --pageTitle="Lightbug @ MWC 2025"
      --line1="Connect to the WiFi hotspot"
      --line2="to continue..."
      --line3="SSID: $ssid"
      --line4="Password: $password"
  )
  comms.send (messages.DrawBitmap.toMsg --pageId=101 --bitmapData=lightbug3030 --bitmapWidth=30 --bitmapHeight=30 --bitmapX=( SCREEN_WIDTH - 30 ) --bitmapY=0)

sendConnectedPageAndBeep comms/services.Comms --onlyIfNew=true --connectedClients/int:
  if onlyIfNew and lastPageId == 102: return
  lastPageId = 102
  connClientsLine := ""
  if connectedClients >= 1:
    connClientsLine = "Clients: $connectedClients"
  comms.send (messages.TextPage.toMsg
      --pageId=102
      --pageTitle="Lightbug @ MWC 2025"
      --line1="Use the page to interact"
      --line2="with this device"
      --line3="$connClientsLine"
  )
  comms.send (messages.DrawBitmap.toMsg --pageId=102 --bitmapData=lightbug3030 --bitmapWidth=30 --bitmapHeight=30 --bitmapX=( SCREEN_WIDTH - 30 ) --bitmapY=0)

randomSSID -> string:
  r := random 1000 9999
  return "LB-$r"
randomPassword -> string:
  r := random 1000 9999
  return "pass-$r"