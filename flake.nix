{
  description = "Reusable NixOS server modules and packages";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.sops-nix = {
    url = "github:Mic92/sops-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.i915-sriov-dkms = {
    url = "github:strongtz/i915-sriov-dkms/2026.09.16";
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
        astrbot = ./modules/astrbot.nix;
        bilibili-live-helper = ./modules/bilibili-live-helper.nix;
        bililive-recorder = ./modules/bililive-recorder.nix;
        dont-starve-together = ./modules/dont-starve-together.nix;
        minecraft-forge = ./modules/minecraft-forge.nix;
        ntfy = ./modules/ntfy.nix;
        harp-web = ./modules/harp-web.nix;
        silverbullet = ./modules/silverbullet.nix;
        ss2022 = ./modules/ss2022.nix;
        sub2api = ./modules/sub2api.nix;
        web = ./modules/web.nix;
        qq-bot = ./modules/qq-bot.nix;
        llonebot = ./modules/llonebot.nix;
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
            ssvgg.astrbot.enable = true;
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
        playwright-browsers-1_63 = pkgs.callPackage ./packages/playwright-browsers-1.63.nix { };
      };
      checks.${system} = {
        example = example.config.system.build.toplevel;
        llonebot-config =
          pkgs.runCommand "llonebot-config-smoke"
            {
              nativeBuildInputs = [ pkgs.jq ];
            }
            ''
              set -euo pipefail

              args=(
                --arg milkyToken ""
                --arg onebotToken "test-token"
                --arg satoriToken ""
                --argjson webuiPort 3080
                --argjson milkyPort 3010
                --argjson satoriPort 5600
                --argjson onebotWsPort 3001
                --argjson onebotReverseWsUrls '["ws://127.0.0.1:6199/ws","ws://127.0.0.1:8788/onebot"]'
              )
              jq_filter=${./modules/llonebot-config.jq}
              input='{"ob11":{"connect":[{"type":"http","enable":false,"port":2999},{"type":"ws-reverse","enable":false,"url":"ws://127.0.0.1:6199/ws","token":"old-token"}]}}'
              first="$(printf '%s\n' "$input" | jq -c "''${args[@]}" --from-file "$jq_filter")"
              second="$(printf '%s\n' "$first" | jq -c "''${args[@]}" --from-file "$jq_filter")"

              printf '%s\n' "$second" | jq -e '
                .ob11.enable
                and ([.ob11.connect[] | select(.type == "ws")] | length == 1)
                and ([.ob11.connect[] | select(.type == "http")] | length == 1)
                and ([.ob11.connect[] | select(.type == "ws-reverse")] | length == 2)
                and ([.ob11.connect[] | select(.type == "ws-reverse" and .url == "ws://127.0.0.1:6199/ws") | select(.enable and .token == "test-token")] | length == 1)
                and ([.ob11.connect[] | select(.type == "ws-reverse" and .url == "ws://127.0.0.1:8788/onebot")] | length == 1)
              ' >/dev/null
              touch "$out"
            '';
        biliup = pkgs.callPackage ./packages/biliup.nix { };
        playwright-browsers-1_63 = pkgs.callPackage ./packages/playwright-browsers-1.63.nix { };
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
