# No first-login questions (Apple ID, Touch ID, Siri, Screen Time, appearance,
# privacy...) for an account nobody sits at, now or after a macOS update: mark
# each Setup Assistant pane as seen, for the running macOS version, which only
# the machine knows, hence an activation step rather than a Nix default.
{ lib, ... }:
let
  seen = [
    "DidSeeAccessibility"
    "DidSeeActivationLock"
    "DidSeeAppearanceSetup"
    "DidSeeApplePaySetup"
    "DidSeeAppStore"
    "DidSeeAvatarSetup"
    "DidSeeCloudSetup"
    "DidSeeiCloudLoginForStorageServices"
    "DidSeeIntelligence"
    "DidSeeLockdownMode"
    "DidSeePrivacy"
    "DidSeeScreenTime"
    "DidSeeSiriSetup"
    "DidSeeSyncSetup"
    "DidSeeSyncSetup2"
    "DidSeeTermsOfAddress"
    "DidSeeTouchIDSetup"
    "DidSeeTrueTonePrivacy"
    "DidSeeWalletSetup"
  ];
in
{
  home.activation.skipSetupAssistant = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    version="$(/usr/bin/sw_vers -productVersion)"
    build="$(/usr/bin/sw_vers -buildVersion)"
    domain=com.apple.SetupAssistant
    ${lib.concatMapStringsSep "\n" (key: "run /usr/bin/defaults write $domain ${key} -bool true") seen}
    # Liquid Glass' tint is GlassTintUpsell; "Welcome to Mac" shows only
    # before another pane, so it goes with them.
    for key in LastSeenCloudProductVersion LastSeenDiagnosticsProductVersion LastSeenSiriProductVersion \
      LastSeenIntelligenceProductVersion LastSeenSyncProductVersion LastSeeniCloudStorageServicesProductVersion \
      LastSeenGlassTintUpsellProductVersion LastSeenAgeRangeSelectionProductVersion \
      DidSeeNewFeaturesProductVersion LastPrivacyBundleVersion; do
      run /usr/bin/defaults write $domain "$key" -string "$version"
    done
    run /usr/bin/defaults write $domain LastSeenBuddyBuildVersion -string "$build"
    run /usr/bin/defaults write $domain MiniBuddyShouldLaunchToResumeSetup -bool false
    run /usr/bin/defaults write $domain SkipFirstLoginOptimization -bool true
  '';
}
