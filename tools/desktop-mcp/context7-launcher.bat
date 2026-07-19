@echo off
:: Launches mcp-remote for context7 with x-api-key from User env.
:: Used by Claude Desktop's claude_desktop_config.json to keep the API key
:: out of the config file. Resolves Node via fnm (no persistent PATH needed).
if "%CONTEXT7_API_KEY%"=="" (
  echo CONTEXT7_API_KEY env var not set 1>&2
  exit /b 1
)
fnm exec --using=default -- cmd /c npx -y mcp-remote https://mcp.context7.com/mcp --transport http-only --header "x-api-key:%CONTEXT7_API_KEY%"
