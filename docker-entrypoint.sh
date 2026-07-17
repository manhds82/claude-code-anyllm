#!/usr/bin/env bash
# docker-entrypoint.sh — generates litellm_config.yaml and starts the proxy.
# All configuration comes from environment variables.
set -e

BASE_URL="${BASE_URL:-https://api.groq.com/openai/v1}"
MODEL="${MODEL:-llama-3.3-70b-versatile}"
PORT="${PORT:-4000}"
CLAUDE_ALIAS="claude-sonnet-4-6"

if [ -z "${LLM_API_KEY:-}" ]; then
  printf '\033[31m[X]\033[0m LLM_API_KEY is not set.\n'
  printf '    Pass it with:  -e LLM_API_KEY=your-key\n'
  exit 1
fi

mkdir -p config
cat > config/litellm_config.yaml <<EOF
model_list:
  - model_name: ${CLAUDE_ALIAS}
    litellm_params:
      model: openai/${MODEL}
      api_base: ${BASE_URL}
      api_key: os.environ/LLM_API_KEY

litellm_settings:
  cache: true
  cache_params:
    type: "local"
    ttl: 3600
EOF

printf '\033[32m[OK]\033[0m Proxy config written (model=%s base=%s port=%s)\n' "$MODEL" "$BASE_URL" "$PORT"
exec litellm --config config/litellm_config.yaml --port "$PORT"
