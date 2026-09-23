.webui = (.webui // {})
| .webui.enable = true
| .webui.host = "0.0.0.0"
| .webui.port = $webuiPort
| .milky = (.milky // {})
| .milky.enable = true
| .milky.reportSelfMessage = false
| .milky.http = (.milky.http // {})
| .milky.http.host = "127.0.0.1"
| .milky.http.port = $milkyPort
| .milky.http.prefix = ""
| .milky.http.accessToken = $milkyToken
| .milky.webhook = (.milky.webhook // {urls: [], accessToken: ""})
| .satori = (.satori // {})
| .satori.enable = true
| .satori.host = "127.0.0.1"
| .satori.port = $satoriPort
| .satori.token = $satoriToken
| .ob11 = (.ob11 // {})
| .ob11.enable = true
| (.ob11.connect | if type == "array" then . else [] end) as $connections
| .ob11.connect = (
    $connections
    | if any(.[]; .type == "ws") then
        map(if .type == "ws" then
          . + {
            enable: true,
            host: "127.0.0.1",
            port: $onebotWsPort,
            token: $onebotToken,
            messageFormat: "array",
            reportSelfMessage: false,
            reportOfflineMessage: false
          }
        else . end)
      else . + [{
        type: "ws",
        enable: true,
        host: "127.0.0.1",
        port: $onebotWsPort,
        heartInterval: 60000,
        token: $onebotToken,
        messageFormat: "array",
        reportSelfMessage: false,
        reportOfflineMessage: false,
        debug: false
      }]
      end
    | reduce $onebotReverseWsUrls[] as $url (. ;
        if any(.[]; .type == "ws-reverse" and .url == $url) then
          map(if .type == "ws-reverse" and .url == $url then
            . + {
              enable: true,
              url: $url,
              heartInterval: 60000,
              token: $onebotToken,
              messageFormat: "array",
              reportSelfMessage: false,
              reportOfflineMessage: false,
              debug: false
            }
          else . end)
        else . + [{
          type: "ws-reverse",
          enable: true,
          url: $url,
          heartInterval: 60000,
          token: $onebotToken,
          messageFormat: "array",
          reportSelfMessage: false,
          reportOfflineMessage: false,
          debug: false
        }]
        end
      )
  )
