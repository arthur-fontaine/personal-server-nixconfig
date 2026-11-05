# uzu's models, pinned, for `mirai server --model <directory>`. Otherwise
# mirai downloads whatever revision Trymirai's registry names at each start
# (https://sdk.trymirai.com/api/v1/fetch/models), and the revision of Oct 30,
# 2026 broke the server's: its speculator's Weaver MLP carries Hadamard
# rotation signs, which uzu loads only on GPUs with an MXU (M5 and later;
# crates/uzu-engine/src/encodable_block/weaver_layer.rs asserts otherwise), so
# mirai panicked on an M1 to M4 ("Weaver MLP does not support input Hadamard
# factors").
#
# The files of the registry's revision for the toolchain the pinned uzu runs
# (TOOLCHAIN_VERSION, crates/uzu-engine/src/utils/version.rs), without
# speculator/: uzu loads a speculator only when that folder exists
# (engine/language_model/mod.rs), and on the server it accepted no draft
# token anyway ("spec 1.00 tok/pass").
{ lib, fetchurl, runCommand }:
let
  model = { name, toolchain, repository, revision, files, encodings }:
    let
      base = "https://assets.trymirai.com/models/${toolchain}/${repository}/${revision}";
      fetched = lib.mapAttrs (file: sha256: fetchurl { url = "${base}/${file}"; inherit sha256; }) files;
    in
    # Links, not copies: the weights stay one store path of their own.
    runCommand name { passthru = { inherit toolchain repository revision; }; } ''
      mkdir -p $out
      ${lib.concatStrings (lib.mapAttrsToList (file: src: "ln -s ${src} $out/${file}\n") fetched)}
      # The chat template the registry names (its model's "encodings"), which
      # a local model reads from encoding.json (registry/local/mod.rs).
      cp ${builtins.toFile "encoding.json" (builtins.toJSON encodings)} $out/encoding.json
    '';
in
{
  "alibaba:qwen3.5:9b:mirai:mirai-m:4" = model {
    name = "uzu-qwen3.5-9b-mirai-m-4";
    toolchain = "0.17.0";
    repository = "trymirai-Qwen3.5-9B-M";
    revision = "b1b94b8c-5fc3-45cc-a68d-8fe302ffaf29";
    files = {
      "config.json" = "1mg4ayv86qza4m2yn65g5kwxq0cd7fmbxy2cns34pbpmmy5kysg1";
      "tokenizer.json" = "1r1dnwyk7snqzqkcl94jqbyx6bg6jqp29if387r3px7wcc6q79w7";
      "model.safetensors" = "11crw5jx9m1f8r5a8xwxp984dk1qz51q0qczjfph23pa7w46la7b";
    };
    encodings = [{ name = "qwen3.5"; type = "hanashi"; }];
  };
}
