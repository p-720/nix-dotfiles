{ config, lib, pkgs, ... }:

let
  jinaApiKeyFile = /home/andrew/Dropbox/jina_api_key;
  jinaApiKey = if builtins.pathExists jinaApiKeyFile then
    lib.removeSuffix "\n" (builtins.readFile jinaApiKeyFile)
  else
    "";
in {
  home.file.".config/mcp/mcp.json".text = lib.generators.toJSON { } {
    mcpServers = {
      exa = { url = "https://mcp.exa.ai/mcp"; };
      playwright = { command = "playwright-mcp"; };
    } // lib.optionalAttrs (builtins.pathExists jinaApiKeyFile) {
      jina-mcp-server = {
        url = "https://mcp.jina.ai/v1";
        headers = { Authorization = "Bearer ${jinaApiKey}"; };
      };
    };
  };
}
