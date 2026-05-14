# Reusable example template module. Pass in the two `.age` files; the module
# declares the secrets and a template that references them.
#
# Imported both by the NixOS example (example/configuration.nix) and by the
# templates VM test (tests/templates.nix). Each consumer separately attaches
# its own `restartUnits` / `reloadUnits` — the system-vs-user distinction is
# theirs to make.
{
  apiToken,
  dbPassword,
}:

{
  config,
  ...
}:

{
  age.secrets.api-token.file = apiToken;
  age.secrets.db-password.file = dbPassword;

  age.templates."app.toml".content = ''
    [api]
    token = "${config.age.placeholder.api-token}"

    [db]
    password = "${config.age.placeholder.db-password}"
  '';
}
