#!/usr/bin/env bash
# AgentHub - publish a reachable tunnel URL to the shared ntfy topic.
# Cloudflare quick tunnels sometimes return an empty 403 on a random hostname.
# Do not publish until a real health probe succeeds; retry with a fresh hostname.
set -uo pipefail

ID="${1:-open}"
PORT="${2:-11434}"
TOPIC='agenthub-cloud-7f3a91c2'
TRIES="${3:-8}"

notify() {
  curl -fsS -X POST "https://ntfy.sh/$TOPIC" \
    -H 'Tag: status' --data-binary "$1" > /dev/null 2>&1 || true
}

publish() {
  curl -fsS -X POST "https://ntfy.sh/$TOPIC" \
    -H 'Tag: url' --data-binary "cloud|$ID|$1" > /dev/null 2>&1 || true
}

# Ollama exposes both its native tags endpoint and OpenAI-compatible models.
# Accept either so a working backend is never rejected by a wrong probe path.
url_ok() {
  local u="$1" code p
  for p in /api/tags /v1/models /health; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "$u$p" 2>/dev/null || true)
    if [[ "$code" =~ ^2 ]]; then
      echo "$p $code"
      return 0
    fi
  done
  echo "last=$code"
  return 1
}

notify "cloud-diagnostic|$ID|publish start (port $PORT)"

for attempt in $(seq 1 "$TRIES"); do
  : > tunnel.log
  nohup cloudflared tunnel --url "http://127.0.0.1:$PORT" > tunnel.log 2>&1 &
  pid=$!

  url=""
  for _ in $(seq 1 90); do
    url=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' tunnel.log | head -n1 || true)
    [ -n "$url" ] && break
    sleep 1
  done

  if [ -n "$url" ]; then
    probe=$(url_ok "$url")
    if [ $? -eq 0 ]; then
      publish "$url"
      echo "LIVE: $url ($probe)"
      notify "cloud-diagnostic|$ID|live after $attempt attempt(s): $probe"
      exit 0
    fi
    notify "cloud-diagnostic|$ID|attempt $attempt: $url unreachable ($probe); retrying"
    echo "attempt $attempt: $url unreachable ($probe)"
  else
    notify "cloud-diagnostic|$ID|attempt $attempt: no cloudflared URL; retrying"
    echo "attempt $attempt: no cloudflared URL"
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  sleep 3
done

notify "cloud-diagnostic|$ID|no reachable URL after $TRIES attempts"
echo "no reachable tunnel URL after $TRIES attempts"
exit 1
