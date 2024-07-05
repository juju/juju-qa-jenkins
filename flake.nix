{
  description = "juju qa jenkins job builder shell";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";
  };

  outputs = { self, nixpkgs, ... } @ inputs:
    let
      forAllSystems = inputs.nixpkgs.lib.genAttrs [
        "aarch64-linux"
        "x86_64-linux"
        "aarch64-darwin"
      ];
    in
    {
      devShells = forAllSystems (system: {
        default =
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
          pkgs.mkShell {
            name = "juju-qa-jenkins";
            # Enable experimental features without having to specify the argument
            NIX_CONFIG = "experimental-features = nix-command flakes";
            nativeBuildInputs = with pkgs; [
              coreutils
              findutils
              gnumake
              gnused
              gnugrep
              zsh
              go
              python3
              shellcheck
            ];
            shellHook = ''
              exec zsh
            '';
          };
      });
    };
}
