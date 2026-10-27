# The machine's own settings. Each feature (hermes, uzu, ...) declares its
# options in its own folder, under `server.<feature>`.
{ ... }:
{
  imports = [
    ./admin.nix
    ./energy.nix
  ];
}
