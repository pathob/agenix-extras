# Reusable example module: defines two secrets and a template that uses both.
# The NixOS configuration (configuration.nix) and the home-manager one
# (home.nix) both import it and attach their own units, system or user ones.
# tests/templates.nix imports it too, so the example is the fixture the test
# runs against.
{
  config,
  ...
}:

{
  age.secrets.api-token.file = ../tests/secrets/api-token.age;
  age.secrets.db-password.file = ../tests/secrets/db-password.age;

  age.templates."app.toml".content = ''
    [api]
    token = "${config.age.placeholder.api-token}"

    [db]
    password = "${config.age.placeholder.db-password}"
  '';
}
