# home-manager example: same shared template, restart wired to a *user* unit.
#
# This is imported from example/configuration.nix under
# `home-manager.users.demo` to show both modules wired together. The
# `mbsync.service` reference is illustrative — the agenix-extras HM module
# does not enable mbsync itself, it just plants an X-Restart-Triggers on the
# unit if one happens to be defined.
{
  config,
  agenix-extras,
  ...
}:

{
  imports = [
    (import ./module.nix {
      apiToken = "${agenix-extras}/tests/secrets/api-token.age";
      dbPassword = "${agenix-extras}/tests/secrets/db-password.age";
    })
  ];

  age.identityPaths = [ "${config.home.homeDirectory}/.ssh/id_ed25519" ];

  # When the secrets backing app.toml change, restart the user-level mbsync
  # systemd unit. Only user units are valid here.
  age.templates."app.toml".restartUnits = [ "mbsync.service" ];
}
