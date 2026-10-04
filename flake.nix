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
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      moduleFiles = {
        default = ./modules/default.nix;
        astrbot = ./modules/astrbot.nix;
        bilibili-live-helper = ./modules/bilibili-live-helper.nix;
        bililive-recorder = ./modules/bililive-recorder.nix;
        ntfy = ./modules/ntfy.nix;
        ss2022 = ./modules/ss2022.nix;
        sub2api = ./modules/sub2api.nix;
        web = ./modules/web.nix;
        nonebot = ./modules/nonebot.nix;
        llbot = ./modules/llbot.nix;
      };
      example = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          sops-nix.nixosModules.sops
          moduleFiles.default
          {
            boot.isContainer = true;
            networking.hostName = "nixos-server-example";
            ssvgg.astrbot.enable = true;
            ssvgg.web.enable = true;
            ssvgg.llbot.enable = true;
            ssvgg.ntfy = {
              enable = true;
              domain = "ntfy.example.com";
            };
            system.stateVersion = "26.05";
          }
        ];
      };
    in
    {
      nixosModules = moduleFiles;
      nixosConfigurations.example = example;

      packages.${system} = {
        biliup = pkgs.callPackage ./packages/biliup.nix { };
        playwright-browsers = pkgs.callPackage ./packages/playwright-browsers.nix { };
      };
      checks.${system} = {
        example = example.config.system.build.toplevel;
        biliup = pkgs.callPackage ./packages/biliup.nix { };
        playwright-browsers = pkgs.callPackage ./packages/playwright-browsers.nix { };
      };

      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          actionlint
          bash
          git
          nix
          nixfmt
          nixfmt-tree
          nodejs
          python3
          shellcheck
        ];
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
