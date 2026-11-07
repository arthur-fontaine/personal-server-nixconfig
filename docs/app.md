# The Hermes app

An iPhone and iPad app for Hermes (`apps/hermes-ios`): what it does and how
it is made in [its README](../apps/hermes-ios/README.md) and
[design](../apps/hermes-ios/docs/design.md); its protocol with Hermes in
[app-protocol.md](app-protocol.md).

## Delivery

With `server.hermes.app.delivery.enable` (the bootstrap's "The Hermes app"
step), the app is one app of the sideload service ([sideload.md](sideload.md)),
named `hermes`, declared in `modules/hermes/system/sideload.nix`: built from
`apps/hermes-ios` at the deployed revision, signed with your Apple Account,
installed on your devices over Wi-Fi and re-signed before it expires.

1. Before each build the current pet, which the App topic writes to
   `~/.hermes/app/pet/`, is copied in: `icon.png` (1024×1024) becomes the app
   icon (`HermesApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png`),
   `pet.json` and `spritesheet.webp` go to `Pet/`; `pet.json`'s `version` is
   recorded with the install.
2. Its settings go in as build settings, through the environment:
   `HERMES_TEAM_ID`, `HERMES_BUNDLE_ID_PREFIX`
   (`org.personal-server.hermes.<team id>` unless `bundleIdPrefix`),
   `HERMES_PAID_TEAM`, `HERMES_TG_API_ID` / `HERMES_TG_API_HASH` (the secrets
   file's `TELEGRAM_API_ID` / `_HASH`) and `HERMES_BOT_USERNAME` (the bot's,
   from Telegram's `getMe`).
3. Its devices are written to `~/.hermes/app/delivery.json` after every
   change (the App topic's `devices` state, same shape as before), and
   `hermes-app install|status|devices|run` stays the command the App topic
   calls ("reinstall"), now a shim over `sideload … hermes`. An earlier
   `delivery.json` is read once, so its devices carry over.

A free team allows 3 sideloaded apps per device: the Hermes app is one, and
takes two of the 10 App IDs a week (the app and its widgets). No push
notifications on a free team (`HERMES_PAID_TEAM=0`): the app gets news
through Telegram's own notifications.

Hermes decides when to reinstall: `sideload_install` with `app: "hermes"`
after a new pet, when you ask, or after a failed install.
