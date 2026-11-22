#!/bin/bash
# User-data da EC2 do Prodcontrol (Ubuntu 24.04 LTS, x86_64) com Docker Swarm.
# Preencha as 4 variáveis abaixo antes de lançar a instância (ver README).
set -euxo pipefail
exec > >(tee -a /var/log/prodcontrol-bootstrap.log) 2>&1

AWS_REGION="us-east-2"
SECRET_ID="prodcontrol/prod/swarm"
API_DOMAINS="swarm.prodcontrol.app.br"
ACME_EMAIL="midias@prodsistem.com.br"

SETUPS_REPO="https://github.com/Team-ProdControl/prodsistem-setups.git"
SETUPS_DIR="/opt/prodcontrol/prodsistem-setups"
COSIGN_VERSION="v2.4.1"

export DEBIAN_FRONTEND=noninteractive

# --- Sistema base ---
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg jq git unzip

# --- Swap de 2 GB (folga para picos de memória) ---
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- Ajustes para o Redis (substitui o privileged do compose antigo) ---
echo 'vm.overcommit_memory=1' > /etc/sysctl.d/90-redis.conf
sysctl --system
cat > /etc/systemd/system/disable-thp.service <<'UNIT'
[Unit]
Description=Desativa Transparent Huge Pages (recomendado para Redis)
Before=docker.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
[Install]
WantedBy=multi-user.target
UNIT
systemctl enable --now disable-thp.service

# --- Docker (repositório oficial) ---
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": false
}
JSON
systemctl enable docker
systemctl restart docker

# --- AWS CLI v2 ---
if ! command -v aws >/dev/null; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip
fi

# --- SSM Agent (já vem via snap nas AMIs Ubuntu; garante que está ativo) ---
snap list amazon-ssm-agent >/dev/null 2>&1 || snap install amazon-ssm-agent --classic
systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true

# --- Cosign ---
curl -fsSL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64" -o /usr/local/bin/cosign
chmod +x /usr/local/bin/cosign

# --- Docker Swarm (nó único) ---
TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PRIVATE_IP=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
  docker swarm init --advertise-addr "$PRIVATE_IP"
fi

# --- Configuração do deploy ---
install -d -m 750 /etc/prodcontrol
cat > /etc/prodcontrol/deploy.conf <<CONF
AWS_REGION="${AWS_REGION}"
SECRET_ID="${SECRET_ID}"
API_DOMAINS="${API_DOMAINS}"
ACME_EMAIL="${ACME_EMAIL}"
STACK_NAME="prodcontrol"
# PGBOUNCER_IMAGE="pgbouncer/pgbouncer@sha256:..."   # fixar a versão de hoje
# REDIS_MAXMEMORY="768mb"
CONF
chmod 640 /etc/prodcontrol/deploy.conf

# --- Repositório de setups (stack + scripts) ---
mkdir -p /opt/prodcontrol
if [ ! -d "$SETUPS_DIR/.git" ]; then
  git clone "$SETUPS_REPO" "$SETUPS_DIR"
fi

echo "Bootstrap concluído. Próximo passo: primeiro deploy via workflow deploy-swarm.yml."
