# nixos-server

Reusable NixOS modules and packages for small, declaratively managed servers.
The repository contains no production inventory, host addresses, credentials,
or deployment identity.

## Use

```nix
{
  inputs.nixos-server = {
    url = "github:ooaaqq/nixos-server";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Import all service options once, then enable only the required services:

```nix
{
  imports = [ inputs.nixos-server.nixosModules.default ];

  ssvgg.web.enable = true;
  ssvgg.sub2api = {
    enable = true;
    domain = "api.example.com";
  };
  ssvgg.astrbot.enable = true;
}
```

Modules that consume credentials accept a SOPS file path from the caller. The
consumer is responsible for importing `sops-nix` and defining its recipients.

## Configuration ownership

NixOS owns service lifecycle, pinned images, host networking, persistent data
paths, secrets, and the ports required by other services. Application settings
that operators routinely change in a service WebUI remain in that service's
persistent data directory. A module must not patch a mutable application
configuration file during service startup; this can undo WebUI changes and
leave obsolete settings behind.

For LLBot, this module starts PMHQ and LLBot and provides their persistent data
directories. Protocol listeners and connector entries are managed in the
LLBot WebUI. The caller documents the expected local endpoints for dependent
services and checks those links independently. `ssvgg.llonebot.webuiPort` is
retained as the stable WebUI endpoint for SSH tunnels and health checks.

The ntfy module keeps the `inbox` anonymous read/write ACL in the NixOS ntfy
settings, alongside the server's default-deny policy. ntfy reconciles this ACL
from its configuration instead of accumulating grants through a startup hook.

When a service is decommissioned, remove its reusable module and tests here
along with the host enablement, credentials, monitoring, and operating
instructions in the private fleet repository.

## Development

```bash
nix develop --accept-flake-config
./scripts/check-config.sh
nix build --accept-flake-config .#checks.x86_64-linux.example
```

Production inventory and deployment automation intentionally belong in a
separate private repository.
