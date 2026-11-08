# Keeps the Command Line Tools and Xcode at their latest release, as the
# administrator's own Mac does (arthur-fontaine/nixconfig,
# modules/darwin/core/xcode.nix), with xcodes from Nix instead of Homebrew.
#
# Xcode comes from Apple's developer downloads, which need an Apple Account.
# xcodes keeps the account's two-factor trust in the administrator's cookies,
# but not its sign-in, and cannot keep the password over SSH (the login
# keychain is locked there): the bootstrap's xcode section keeps it in
# `credentialsFile`, root only, so a rebuild downloads a new Xcode unattended.
# A two-factor code is asked only when Apple wants a new one, and only with a
# terminal to type it in; otherwise Xcode waits for the next rebuild.
{ config, lib, pkgs, ... }:
let
  cfg = config.server.xcode;
  admin = config.server.admin;
  # Where xcodes keeps its archives (XcodesKit Path+.swift, xcodesApplicationSupport).
  archives = "${admin.home}/Library/Application Support/com.robotsandpencils.xcodes";
in
{
  options.server.xcode = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the latest Xcode with xcodes at each activation (the Command Line Tools are updated either way).";
    };
    credentialsFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/xcodes.env";
      description = ''
        XCODES_USERNAME= and XCODES_PASSWORD= lines, root only, written by the
        bootstrap's xcode section. Not Hermes' secrets file: Hermes reads that
        one, and has no use for the Apple Account's password.
      '';
    };
  };

  config = {
    environment.systemPackages = lib.mkIf cfg.enable [ pkgs.xcodes ];

    # Last in the activation: no step here waits on it, and installing Xcode
    # takes a while.
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
              || echo "warning: could not install $clt_label; run: sudo softwareupdate --install '$clt_label'" >&2
          fi
        fi
      ${lib.optionalString cfg.enable ''

        echo "checking Xcode..." >&2
        if [ -r ${cfg.credentialsFile} ]; then
          XCODES_USERNAME=$(sed -n 's/^XCODES_USERNAME=//p' ${cfg.credentialsFile} | head -n 1)
          XCODES_PASSWORD=$(sed -n 's/^XCODES_PASSWORD=//p' ${cfg.credentialsFile} | head -n 1)
          export XCODES_USERNAME XCODES_PASSWORD
        fi
        # As the administrator, whose cookies keep the two-factor trust. The
        # password goes through the environment, never on a command line (ps).
        # No aria2: with it, Xcode's download gets Apple's Unauthorized page
        # (xcodes 2.1.0), which xcodes then keeps as the archive.
        run_xcodes() {
          sudo --preserve-env=XCODES_USERNAME,XCODES_PASSWORD -u ${admin.user} -H ${lib.getExe pkgs.xcodes} "$@"
        }
        # Such an error page, or any download cut short, would be reused as
        # the archive by the next install, which then fails to unpack it.
        if [ -d "${archives}" ]; then
          find "${archives}" -maxdepth 1 -name '*.xip' -size -100M -delete
        fi
        latest_xcode=$(run_xcodes update 2>/dev/null </dev/null | grep -E '^[0-9.]+ \(' | tail -1 | awk '{ print $1 }')
        if [ -n "$latest_xcode" ] && ! run_xcodes installed 2>/dev/null </dev/null | grep -q "^$latest_xcode ("; then
          if [ -t 0 ]; then
            echo "installing Xcode $latest_xcode (a two-factor code is asked only if Apple wants one)..." >&2
            run_xcodes install "$latest_xcode" --no-aria2 --no-superuser --experimental-unxip --empty-trash \
              || echo "warning: could not install Xcode $latest_xcode" >&2
          elif [ -n "''${XCODES_PASSWORD:-}" ]; then
            echo "installing Xcode $latest_xcode..." >&2
            run_xcodes install "$latest_xcode" --no-aria2 --no-superuser --experimental-unxip --empty-trash </dev/null \
              || echo "warning: could not install Xcode $latest_xcode; if Apple wants a two-factor code, run sudo server-rebuild in a terminal" >&2
          else
            echo "Xcode $latest_xcode: no Apple Account to download it (bootstrap-macos.sh xcode); skipped" >&2
          fi
        fi
        xcode_path=""
        if [ -n "$latest_xcode" ]; then
          xcode_path=$(run_xcodes installed 2>/dev/null </dev/null | awk -F'\t' -v v="$latest_xcode" 'index($1, v " (") == 1 { print $NF }')
        fi
        # Without the latest version (no Apple session to look it up, or its
        # install failed), an Xcode already installed is still better than the
        # Command Line Tools alone: sideload and xcodebuild need one selected.
        if [ -z "$xcode_path" ]; then
          case "$(xcode-select -p 2>/dev/null)" in
            */Xcode*.app/Contents/Developer) ;;
            *)
              xcode_path=$(
                {
                  run_xcodes installed 2>/dev/null </dev/null | awk -F'\t' '{ split($1, v, " "); print v[1] "\t" $NF }'
                  for app in /Applications/Xcode*.app; do
                    [ -d "$app" ] || continue
                    printf '%s\t%s\n' "$(/usr/bin/defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 0)" "$app"
                  done
                } | sort -V -k1,1 | tail -n 1 | cut -f 2
              )
              [ -n "$xcode_path" ] || echo "warning: no Xcode installed to select; the Command Line Tools stay selected" >&2
              ;;
          esac
        fi
        if [ -n "$xcode_path" ] && [ "$(xcode-select -p 2>/dev/null)" != "$xcode_path/Contents/Developer" ]; then
          echo "selecting $xcode_path..." >&2
          xcode-select -s "$xcode_path" \
            && xcodebuild -license accept \
            && xcodebuild -runFirstLaunch \
            || echo "warning: could not select $xcode_path; run: sudo xcode-select -s $xcode_path" >&2
        fi
      ''}
      )
    '';
  };
}
