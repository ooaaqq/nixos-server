{
  description = "Reusable NixOS server modules and packages";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.sops-nix = {
    url = "github:Mic92/sops-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.i915-sriov-dkms = {
    url = "github:strongtz/i915-sriov-dkms/2026.02.09";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      sops-nix,
      i915-sriov-dkms,
      ...
    }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
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
        i915-sriov =
          { config, ... }:
          {
            imports = [ i915-sriov-dkms.nixosModules.default ];
            options.ssvgg.i915Sriov = {
              enable = lib.mkEnableOption "patched Intel i915 SR-IOV driver";
              deviceId = lib.mkOption {
                type = lib.types.str;
                default = "a7a0";
              };
            };
            config = lib.mkIf config.ssvgg.i915Sriov.enable {
              boot.extraModulePackages = [ config.boot.kernelPackages.i915-sriov ];
              boot.kernelModules = [ "i915" ];
              boot.kernelParams = [
                "intel_iommu=on"
                "i915.enable_guc=3"
                "i915.force_probe=${config.ssvgg.i915Sriov.deviceId}"
                "module_blacklist=xe"
              ];
            };
          };
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

      packages.${system} = {
        biliup = pkgs.callPackage ./packages/biliup.nix { };
        playwright-browsers-1_62 = pkgs.callPackage ./packages/playwright-browsers-1.62.nix { };
      };
      checks.${system} = {
        example = example.config.system.build.toplevel;
        biliup = pkgs.callPackage ./packages/biliup.nix { };
        playwright-browsers-1_62 = pkgs.callPackage ./packages/playwright-browsers-1.62.nix { };
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
