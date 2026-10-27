{ rustPlatform, fetchFromGitHub }:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "fsearch";
  version = "0.2.1";

  src = fetchFromGitHub {
    owner = "noahdunnagan";
    repo = "fsearch";
    rev = "v${finalAttrs.version}";
    hash = "sha256-mAzw7rQZ45rLINPo6WDNZ6GZf3njDdDMbxVmhrbkvJE=";
  };

  cargoLock.lockFile = "${finalAttrs.src}/Cargo.lock";

  # The tests index the build user's home.
  doCheck = false;

  meta = {
    description = "Whole-disk file search for macOS, with an MCP server for agents";
    homepage = "https://github.com/noahdunnagan/fsearch";
    mainProgram = "fsearch";
  };
})
