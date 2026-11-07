# Hermes' side of the owner's iOS app (../plugins/app_topic, docs/app.md):
# the plugin, its settings, and the Hermes settings it rests on (image
# generation for pets, STT and TTS for call mode). Listed in plugins.enabled
# by memory.nix, which holds that list.
{ lib, pkgs, server, hostName, ... }:
let
  cfg = server.hermes.app;
  images = cfg.images;
  call = cfg.call;
  # Hermes' image plugins (plugins/image_gen): "custom" is its OpenAI one
  # pointed elsewhere (image_gen.openai.base_url / key_env, website/docs/
  # user-guide/features/image-generation.md, "OpenAI-compatible endpoints").
  imageProvider = if images.provider == "custom" then "openai" else images.provider;
  imageSettings =
    { provider = imageProvider; }
    // lib.optionalAttrs (images.provider == "openrouter" && images.model != null) { model = images.model; }
    // lib.optionalAttrs (images.provider != "openrouter") {
      openai = lib.filterAttrs (_: v: v != null) {
        model = images.model;
        base_url = if images.provider == "custom" then images.baseUrl else null;
        key_env = if images.provider == "custom" then images.keyEnv else null;
      };
    };
in
lib.mkIf cfg.enable {
  assertions = [
    {
      assertion = images.provider != "custom" || images.baseUrl != null;
      message = "server.hermes.app.images.provider = \"custom\" needs server.hermes.app.images.baseUrl.";
    }
  ];

  services.hermes-agent = {
    extraPlugins = [
      (pkgs.runCommand "hermes-plugin-app-topic" { } ''
        cp -R ${../plugins/app_topic} $out
      '')
    ];
    hermesHomeFiles."app_topic/config.json" = builtins.toJSON {
      chain = [ { inherit (server.hermes.model) provider; model = server.hermes.model.name; } ]
        ++ map (f: { inherit (f) provider model; }) server.hermes.fallbacks;
      delivery_cli = "hermes-app";
      pets.enable = images.provider != null;
      big_files.swisstransfer_token_env = cfg.swisstransferTokenEnv;
      call = {
        inherit (call) enable port;
        bind = "0.0.0.0";
        public_url = call.publicUrl;
        lan_host = "${hostName}.local";
        ffmpeg = lib.getExe pkgs.ffmpeg-headless;
      };
      apns = {
        inherit (cfg.apns) enable;
        key_id = cfg.apns.keyId;
        team_id = cfg.apns.teamId;
        bundle_id = cfg.apns.bundleId;
        key_env = "APNS_KEY";
      };
    };

    settings = {
      # A call turns what the owner says into a main-chat turn (PluginContext.inject_message).
      plugins.entries.app_topic.allow_gateway_injection = true;
    }
    // lib.optionalAttrs (images.provider != null) { image_gen = imageSettings; }
    // lib.optionalAttrs call.enable {
      # Hermes' default hint is "en" (tts.md, "stt"): the owner may speak any language.
      stt = { provider = call.stt; language = ""; }
        // lib.optionalAttrs (call.sttModel != null) { ${call.stt}.model = call.sttModel; };
      tts = { provider = call.tts; }
        // lib.optionalAttrs (call.voice != null) {
          ${call.tts}.${if call.tts == "elevenlabs" then "voice_id" else "voice"} = call.voice;
        };
    };
  };
}
