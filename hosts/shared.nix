{
  # The old M1 Pro.
  Personal-Server = {
    system = "aarch64-darwin";
    username = "arthur-fontaine";
    # homeDirectory defaults to /Users/<username> when omitted.

    # SSH keys and other per-machine values live in the git-ignored
    # hosts/local.nix, which scripts/bootstrap-macos.sh writes.
  };
}
