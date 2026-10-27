{ username, homeDirectory, hostName, nixconfigDir, ... }:
{
  home.username = username;
  home.homeDirectory = homeDirectory;
  home.stateVersion = "25.05";

  home.sessionVariables = {
    NIXCONFIG_REPO_DIR = nixconfigDir;
    NIXCONFIG_HOST = hostName;
  };

  programs.home-manager.enable = true;
}
