# Keeps the Command Line Tools and Xcode at their latest release on each
# activation, with nothing to type.
#
# Xcode comes from the App Store, not xcodes (as the administrator's own Mac
# does): Apple's developer downloads want a password and a two-factor code for
# each new session, and xcodes cannot keep its login over SSH (the keychain is
# locked), so every rebuild would ask. The App Store is already signed in, in
# Hermes' session (scripts/bootstrap/apple.sh), and mas installs from it
# without asking, as for HomeClaw (scripts/bootstrap/integrations/homekit.sh).
# Its automatic updates are off (quiet.nix): this updates it instead.
# Last in the activation: no step here waits on it, and Xcode is a few GB.
{ config, lib, pkgs, ... }:
let
  hermes = config.server.hermes;
  # https://apps.apple.com/app/xcode/id497799835
  xcodeId = "497799835";
  xcode = "/Applications/Xcode.app";
in
{
  system.activationScripts.postActivation.text = lib.mkAfter ''
    (
      echo "checking Command Line Tools..." >&2
      installed_clt=$(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null \
        | awk '/^version:/ { split($2, v, "."); print v[1] "." v[2] }')
      # softwareupdate lists the Command Line Tools only while this file exists.
      placeholder=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
      touch "$placeholder"
      clt_label=$(softwareupdate --list 2>/dev/null \
        | sed -n 's/^\* Label: \(Command Line Tools for Xcode .*[^[:space:]]\)[[:space:]]*$/\1/p' \
        | sort -V | tail -1)
      rm -f "$placeholder"
      if [ -n "$clt_label" ]; then
        clt_version=$(printf '%s' "$clt_label" | sed 's/.*Xcode \([0-9.]*\).*/\1/')
        newest=$(printf '%s\n' "$installed_clt" "$clt_version" | sort -V | tail -1)
        if [ "$newest" != "$installed_clt" ]; then
          echo "installing $clt_label..." >&2
          softwareupdate --install "$clt_label" \
            || echo "warning: could not install $clt_label" >&2
        fi
      fi

      echo "checking Xcode..." >&2
      if ${if hermes.enable then "launchctl print gui/${toString hermes.uid} >/dev/null 2>&1" else "false"}; then
        # mas installs as root for the App Store account of SUDO_UID: Hermes'.
        mas() {
          launchctl asuser ${toString hermes.uid} env SUDO_UID=${toString hermes.uid} SUDO_GID=${toString hermes.gid} \
            SUDO_USER=${hermes.user} HOME=${hermes.home} ${lib.getExe pkgs.mas} "$@"
        }
        if [ ! -d ${xcode} ]; then
          echo "installing Xcode from the App Store (a few GB, this takes a while)..." >&2
          mas get ${xcodeId} || echo "warning: could not install Xcode; is the App Store signed in, in Hermes' session?" >&2
        else
          mas update ${xcodeId} || echo "warning: could not update Xcode" >&2
        fi
      else
        echo "Xcode: waiting for Hermes' session (its App Store account); the next rebuild installs it" >&2
      fi

      if [ -d ${xcode} ]; then
        if [ "$(xcode-select -p 2>/dev/null)" != ${xcode}/Contents/Developer ]; then
          echo "selecting ${xcode}..." >&2
          xcode-select -s ${xcode} || echo "warning: could not select ${xcode}" >&2
        fi
        # Again after each update: a new Xcode has a new license and new first-launch packages.
        xcodebuild -license check >/dev/null 2>&1 || xcodebuild -license accept || true
        xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || xcodebuild -runFirstLaunch \
          || echo "warning: Xcode's first launch failed" >&2
      fi
    )
  '';
}
