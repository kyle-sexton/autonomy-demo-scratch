@echo off
:: Launches mcp-remote for ref.tools with x-ref-api-key from User env.
:: Used by Claude Desktop's claude_desktop_config.json to keep the API key
:: out of the config file. Resolves Node via fnm (no persistent PATH needed).
if "%REF_API_KEY%"=="" (
  echo REF_API_KEY env var not set 1>&2
  exit /b 1
)
fnm exec --using=default -- cmd /c npx -y mcp-remote https://api.ref.tools/mcp --transport http-only --header "x-ref-api-key:%REF_API_KEY%"
