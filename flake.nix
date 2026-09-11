{
  description = "Reusable NixOS server modules and packages";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.sops-nix = {
    url = "github:Mic92/sops-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      sops-nix,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      moduleFiles = {
        default = ./modules/default.nix;
        bilibili-live-helper = ./modules/bilibili-live-helper.nix;
        bililive-recorder = ./modules/bililive-recorder.nix;
        dont-starve-together = ./modules/dont-starve-together.nix;
        minecraft-forge = ./modules/minecraft-forge.nix;
        ntfy = ./modules/ntfy.nix;
        rift-web = ./modules/rift-web.nix;
        silverbullet = ./modules/silverbullet.nix;
        ss2022 = ./modules/ss2022.nix;
        sub2api = ./modules/sub2api.nix;
        web = ./modules/web.nix;
        qq-bot = ./modules/qq-bot.nix;
      };
      example = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          sops-nix.nixosModules.sops
          moduleFiles.default
          {
            boot.isContainer = true;
            networking.hostName = "nixos-server-example";
            system.stateVersion = "26.05";
          }
        ];
      };
    in
    {
      nixosModules = moduleFiles;
      nixosConfigurations.example = example;

      packages.${system}.biliup = pkgs.callPackage ./packages/biliup.nix { };
      checks.${system} = {
        example = example.config.system.build.toplevel;
        biliup = pkgs.callPackage ./packages/biliup.nix { };
      };

      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          actionlint
          bash
          git
          nix
          nixfmt
          nixfmt-tree
          python3
          shellcheck
        ];
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
