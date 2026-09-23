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

## Development

```bash
nix develop --accept-flake-config
./scripts/check-config.sh
nix build --accept-flake-config .#checks.x86_64-linux.example
```

Production inventory and deployment automation intentionally belong in a
separate private repository.
