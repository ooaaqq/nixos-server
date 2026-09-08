{ config, lib, ... }:

let
  cfg = config.ssvgg.web;
in
{
  options.ssvgg.web.enable = lib.mkEnableOption "the shared public Caddy edge";

  config = lib.mkIf cfg.enable {
    services.caddy.enable = true;
    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
