{
  # The old M1 Pro.
  Personal-Server = {
    system = "aarch64-darwin";
    username = "arthur-fontaine";
    # homeDirectory defaults to /Users/<username> when omitted.

    # SSH accepts keys only: list yours before the first switch, or nobody can
    # log in remotely.
    # server.ssh.authorizedKeys = [ "ssh-ed25519 AAAA... laptop" ];
  };
}
