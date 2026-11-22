#!/usr/bin/env bash
# Limpa APENAS o cache da aplicação no redis do stack.
# Preserva: filas BullMQ (bull:*), rate limit (*ratelimit*) e tokens revogados (*:black-list-token:*).
# Substitui o workflow redis.yml, que fazia FLUSHALL (e apagaria as filas).
#
# Uso: reset-cache.sh [--dry-run]
set -euo pipefail
STACK_NAME="${STACK_NAME:-prodcontrol}"
DRY_RUN="${1:-}"

CID="$(docker ps -q --filter "label=com.docker.swarm.service.name=${STACK_NAME}_redis" | head -1)"
[ -n "$CID" ] || { echo "container do redis não encontrado" >&2; exit 1; }

KEYS_FILE="$(mktemp)"
trap 'rm -f "$KEYS_FILE"' EXIT

echo "Chaves antes: $(docker exec "$CID" redis-cli DBSIZE)"
docker exec "$CID" redis-cli --scan --count 1000 \
  | grep -vE '^bull:|ratelimit|:black-list-token:' > "$KEYS_FILE" || true
echo "Chaves de cache encontradas: $(wc -l < "$KEYS_FILE")"

if [ "$DRY_RUN" = "--dry-run" ]; then
  head -50 "$KEYS_FILE"
  echo "(dry-run: nada foi apagado)"
  exit 0
fi

if [ -s "$KEYS_FILE" ]; then
  xargs -r -d '\n' -n 500 docker exec -i "$CID" redis-cli UNLINK < "$KEYS_FILE" >/dev/null
fi
echo "Chaves depois: $(docker exec "$CID" redis-cli DBSIZE)"
