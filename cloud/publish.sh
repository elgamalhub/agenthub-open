#!/usr/bin/env bash
# AgentHub - publish a reachable tunnel URL to the shared ntfy topic.
# Cloudflare quick tunnels can hand out a hostname that is not ready yet, and
# Ollama rejects foreign Host headers. Both are handled here: use cloudflared's
# documented --http-host-header, force IPv4, wait for the edge, and only publish
# after a real health probe succeeds.
set -uo pipefail

ID="${1:-open}"
PORT="${2:-11434}"
TOPIC='agenthub-cloud-7f3a91c2'
TRIES="${3:-10}"

notify() {
  curl -fsS -X POST "https://ntfy.sh/$TOPIC" \
    -H 'Tag: status' --data-binary "$1" > /dev/null 2>&1 || true
}

publish() {
  curl -fsS -X POST "https://ntfy.sh/$TOPIC" \
    -H 'Tag: url' --data-binary "cloud|$ID|$1" > /dev/null 2>&1 || true
}

url_ok() {
  local u="$1" code p
  for p in /api/tags /v1/models /health; do
    code=$(curl --ipv4 -sS -o /dev/null -w '%{http_code}' --max-time 15 "$u$p" 2>/dev/null || true)
    if [[ "$code" =~ ^2 ]]; then
      echo "$p $code"
      return 0
    fi
  done
  echo "last=$code"
  return 1
}

log_tail() {
  tail -n 6 tunnel.log 2>/dev/null | tr '\n' ' ' | cut -c1-300
}

notify "cloud-diagnostic|$ID|publish start (port $PORT)"

for attempt in $(seq 1 "$TRIES"); do
  : > tunnel.log
  # --http-host-header is Cloudflare's documented fix for Ollama's 403 on
  # tunneled requests. It sets the origin Host, it does not spoof TLS/SNI.
  nohup cloudflared tunnel --url "http://127.0.0.1:$PORT" \
    --http-host-header "localhost:$PORT" \
    --edge-ip-version 4 --protocol http2 --no-autoupdate \
    > tunnel.log 2>&1 &
  pid=$!

  url=""
  for _ in $(seq 1 90); do
    url=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' tunnel.log | head -n1 || true)
    [ -n "$url" ] && break
    if ! kill -0 "$pid" 2>/dev/null; then
      notify "cloud-diagnostic|$ID|cloudflared exited early: $(log_tail)"
      break
    fi
    sleep 1
  done

  if [ -n "$url" ]; then
    # The URL is printed before Cloudflare's edge route is ready.
    sleep 20
    if ! kill -0 "$pid" 2>/dev/null; then
      notify "cloud-diagnostic|$ID|tunnel died before probe: $(log_tail)"
    else
      probe=$(url_ok "$url")
      if [ $? -eq 0 ]; then
        publish "$url"
        echo "LIVE: $url ($probe)"
        notify "cloud-diagnostic|$ID|live after $attempt attempt(s): $probe"
        exit 0
      fi
      notify "cloud-diagnostic|$ID|attempt $attempt: $url unreachable ($probe); $(log_tail)"
      echo "attempt $attempt: $url unreachable ($probe)"
    fi
  else
    notify "cloud-diagnostic|$ID|attempt $attempt: no cloudflared URL; $(log_tail)"
    echo "attempt $attempt: no cloudflared URL"
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  sleep 3
done

notify "cloud-diagnostic|$ID|no reachable URL after $TRIES attempts"
echo "no reachable tunnel URL after $TRIES attempts"
exit 1
