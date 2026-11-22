#!/usr/bin/env bash
# Deploy do Prodcontrol no Docker Swarm (roda na EC2, como root, via SSM).
#
# Uso:  deploy.sh <imagem por digest>
#   ex: deploy.sh 665539166950.dkr.ecr.us-east-2.amazonaws.com/prodcontrol-prod@sha256:abc...
#
# Configuração em /etc/prodcontrol/deploy.conf (criado pelo user-data):
#   AWS_REGION, SECRET_ID, API_DOMAINS (separados por vírgula), ACME_EMAIL,
#   STACK_NAME (opcional), PGBOUNCER_IMAGE (opcional), REDIS_MAXMEMORY (opcional)
# Chave pública do Cosign em /etc/prodcontrol/cosign.pub
set -euo pipefail

IMAGE_REF="${1:?informe a imagem: repo@sha256:...}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE=/etc/prodcontrol/deploy.conf
COSIGN_PUB=/etc/prodcontrol/cosign.pub
ENV_FILE="$SCRIPT_DIR/.env"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { echo "ERRO: $*" >&2; exit 1; }

[ -f "$CONF_FILE" ] || fail "$CONF_FILE não encontrado"
# shellcheck disable=SC1090
source "$CONF_FILE"
: "${AWS_REGION:?}" "${SECRET_ID:?}" "${API_DOMAINS:?}" "${ACME_EMAIL:?}"
STACK_NAME="${STACK_NAME:-prodcontrol}"

[[ "$IMAGE_REF" == *@sha256:* ]] || fail "use a imagem por digest (repo@sha256:...), não por tag"
REGISTRY="${IMAGE_REF%%/*}"

log "1/6 Lendo secrets de $SECRET_ID"
SECRET_JSON="$(aws secretsmanager get-secret-value --region "$AWS_REGION" \
  --secret-id "$SECRET_ID" --query SecretString --output text)" || fail "não consegui ler o secret"

# Infra nova não usa Upstash: REDIS_URL/REDIS_TOKEN nunca entram no .env
umask 077
jq -r 'del(.REDIS_URL, .REDIS_TOKEN) | to_entries[] | "\(.key)=\(.value)"' <<<"$SECRET_JSON" > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Variáveis interpoladas no docker-stack.yml (o stack deploy não lê o .env sozinho)
for k in DB_HOST DB_PORT DB_USER DB_PASSWORD; do
  v="$(jq -r --arg k "$k" '.[$k] // empty' <<<"$SECRET_JSON")"
  [ -n "$v" ] || fail "chave $k ausente no secret"
  export "$k=$v"
done
unset SECRET_JSON

RULE=""
IFS=',' read -ra DOMAINS <<<"$API_DOMAINS"
for d in "${DOMAINS[@]}"; do
  d="$(echo "$d" | xargs)"
  [ -n "$d" ] || continue
  RULE="${RULE:+$RULE || }Host(\`$d\`)"
done
export TRAEFIK_HOST_RULE="$RULE" ACME_EMAIL WEB_IMAGE="$IMAGE_REF"
[ -n "${PGBOUNCER_IMAGE:-}" ] && export PGBOUNCER_IMAGE
[ -n "${REDIS_MAXMEMORY:-}" ] && export REDIS_MAXMEMORY

log "2/6 Login no ECR ($REGISTRY)"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null

log "3/6 Verificando assinatura Cosign"
if [ -s "$COSIGN_PUB" ]; then
  cosign verify --key "$COSIGN_PUB" "$IMAGE_REF" >/dev/null || fail "assinatura inválida para $IMAGE_REF"
  log "assinatura OK"
else
  fail "$COSIGN_PUB ausente: deploy bloqueado sem verificação de assinatura"
fi

log "4/6 Baixando imagem"
docker pull -q "$IMAGE_REF" >/dev/null

log "5/6 docker stack deploy ($STACK_NAME)"
cd "$SCRIPT_DIR"
docker stack deploy --with-registry-auth --prune --detach=false \
  -c docker-stack.yml "$STACK_NAME"

log "6/6 Verificando saúde"
FIRST_DOMAIN="$(echo "${DOMAINS[0]}" | xargs)"
for _ in $(seq 1 30); do
  REPLICAS="$(docker service ls --filter "name=${STACK_NAME}_web" --format '{{.Replicas}}')"
  if [[ "$REPLICAS" =~ ^([0-9]+)/([0-9]+) ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] \
     && curl -fsSk --max-time 5 --resolve "$FIRST_DOMAIN:443:127.0.0.1" \
          "https://$FIRST_DOMAIN/api/health" >/dev/null; then
    log "web saudável ($REPLICAS) e respondendo via traefik"
    docker image prune -af --filter "until=168h" >/dev/null || true
    log "Deploy concluído: $IMAGE_REF"
    exit 0
  fi
  sleep 10
done

echo "Deploy não ficou saudável em 5 min. Estado atual:" >&2
docker service ps --no-trunc "${STACK_NAME}_web" | head -20 >&2 || true
log "Executando rollback do serviço web"
docker service rollback "${STACK_NAME}_web" || true
exit 1
