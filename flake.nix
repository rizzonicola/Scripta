{
  description = "Scripta Flutter development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/5adc50831c259f87faeb09ddf930d43597197473";

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems
          (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            flutter344
            git
            curl
            unzip
            which
            pkg-config
            cmake
            ninja
            clang
            gtk3
            gtk3.dev
            libsecret
            libsecret.dev
            sqlite
            xz
            libGL
          ];

          shellHook = ''
            echo "Scripta dev shell (Flutter 3.44)"
            echo "Run: flutter pub get && flutter analyze && flutter test"
          '';
        };
      });
    };
}
