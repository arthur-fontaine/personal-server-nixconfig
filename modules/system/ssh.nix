# Remote administration, with keys only.
{ config, lib, ... }:
{
  options.server.ssh.authorizedKeys = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Public keys allowed to log in as the administrator.";
    example = [ "ssh-ed25519 AAAA... laptop" ];
  };

  config = {
    services.openssh = {
      enable = true;
      extraConfig = ''
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitRootLogin no
      '';
    };

    users.users.${config.server.admin.user}.openssh.authorizedKeys.keys = config.server.ssh.authorizedKeys;
  };
}
