# The same template for a user, with agenix-extras' home-manager module
# (added to every user by flake.nix through home-manager.sharedModules).
{ config, pkgs, ... }:
{
  imports = [ ./module.nix ];

  home.stateVersion = "25.11";

  age.identityPaths = [ "${config.home.homeDirectory}/.ssh/id_ed25519" ];

  # Rendered to ${XDG_RUNTIME_DIR}/agenix-extras/app.toml; restarted when it
  # changes.
  age.templates."app.toml".restartUnits = [ "demo-api.service" ];

  systemd.user.services.demo-api = {
    Unit.Description = "Demo API consuming an agenix-extras template";
    # systemd expands the ${XDG_RUNTIME_DIR} in the path.
    Service.ExecStart = "${pkgs.coreutils}/bin/cat ${config.age.templates."app.toml".path}";
    Install.WantedBy = [ "default.target" ];
  };
}
