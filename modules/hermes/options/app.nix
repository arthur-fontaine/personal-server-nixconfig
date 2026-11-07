# Hermes' side of the owner's iOS app (docs/app.md): the App topic, pets,
# big files, pushes. Building and installing the app itself is
# server.hermes.app.delivery (modules/hermes/app-delivery), apart.
{ lib, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
in
{
  options.server.hermes.app = {
    enable = mkEnableOption ''
      the app_topic plugin: the hidden "App" topic of the Telegram DM the app
      reads (state, questions, notifications' spoken text, stats, the pet),
      the pet and big-file tools. Needs BotFather's Threaded Mode, as the
      sub-chats do'';

    images = {
      provider = mkOption {
        type = types.nullOr (types.enum [ "openrouter" "openai" "custom" ]);
        default = null;
        description = ''
          Where pets are drawn (Hermes' image generation, which needs a model
          that takes reference images): OpenRouter, OpenAI, or any
          OpenAI-compatible API at `baseUrl` ("custom"). null: no
          `pet_generate`. The bootstrap's App section asks.
        '';
      };
      model = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "openai/gpt-image-2";
        description = "The image model; null keeps Hermes' default for the provider.";
      };
      baseUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "https://images.example.com/v1";
        description = "The API's address, for provider \"custom\" (its /images/generations and /images/edits).";
      };
      keyEnv = mkOption {
        type = types.str;
        default = "APP_IMAGES_API_KEY";
        description = ''
          The variable of the secrets file holding the custom API's key
          (OpenRouter and OpenAI use OPENROUTER_API_KEY and OPENAI_API_KEY).
        '';
      };
    };

    apns = {
      enable = mkEnableOption ''
        pushes to the app through APNs: notifications and Live Activity
        updates while the app is not running. A paid Apple Developer team
        only; the .p8 key goes in the secrets file as APNS_KEY'';
      keyId = mkOption { type = types.str; default = ""; description = "The APNs key's id."; };
      teamId = mkOption { type = types.str; default = ""; description = "The Apple Developer team id."; };
      bundleId = mkOption { type = types.str; default = ""; description = "The app's bundle id (the push topic)."; };
    };

    swisstransferTokenEnv = mkOption {
      type = types.str;
      default = "INFOMANIAK_TOKEN";
      description = "The secrets file's variable with an Infomaniak API token, for SwissTransfer links (optional).";
    };
  };
}
