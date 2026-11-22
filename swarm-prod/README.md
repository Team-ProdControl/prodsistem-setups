# Prodcontrol em produção com Docker Swarm (EC2 única)

Runbook da nova infraestrutura. Os comandos foram pensados para o **AWS CloudShell**
(região `us-east-2`), mas rodam em qualquer terminal com AWS CLI v2 e `jq`.

| Arquivo | Para quê |
| --- | --- |
| `docker-stack.yml` | Stack: traefik (HTTPS), web (API, 2 réplicas), pgbouncer, redis |
| `deploy.sh` | Gera o `.env` a partir do Secrets Manager, verifica a assinatura e faz o `docker stack deploy` |
| `reset-cache.sh` | Limpa só o cache (preserva filas BullMQ, rate limit e tokens revogados) |
| `bootstrap/user-data.sh` | Prepara a EC2 Ubuntu 24.04 (Docker, Swarm, AWS CLI, SSM, Cosign) |
| `bootstrap/iam-policy.json`, `bootstrap/trust-policy.json` | Permissões da instância |

O workflow de deploy fica no repositório do backend: `.github/workflows/deploy-swarm.yml`.

> **Regra de ouro:** a instância nova usa a tag `Environment=prod-swarm`, nunca `prod`.
> Os workflows antigos (`deploy-prod.yml`, `redis.yml`) mandam comandos para toda instância
> com `Environment=prod` + `Project=prodcontrol`.

---

## Fase 0: levantamento (só leitura)

```bash
export AWS_REGION=us-east-2

# Instância atual de produção: VPC, subnet e security group
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=prodcontrol" "Name=tag:Environment,Values=prod" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{id:InstanceId,type:InstanceType,vpc:VpcId,subnet:SubnetId,sg:SecurityGroups[].GroupId}" \
  --output table

# Chaves (não os valores) do secret atual
aws secretsmanager get-secret-value --secret-id prodcontrol-prod-app-secrets \
  --query SecretString --output text | jq 'keys'

# Parâmetros atuais
aws ssm get-parameters-by-path --path /prodcontrol/prod --recursive \
  --query "Parameters[].Name" --output table

# Versão do pgbouncer que roda hoje (rodar NA instância antiga, via Session Manager)
#   docker inspect --format '{{index .RepoDigests 0}}' $(docker ps -qf name=pgbouncer)
```

No banco, confirme que cabem mais 50 conexões durante a convivência:
`SHOW max_connections;` e `SELECT count(*) FROM pg_stat_activity;`

---

## Fase 1: secret novo (independente do Terraform)

Junta o secret atual + os parâmetros do SSM num único JSON, **sem exibir os valores**.
Remove `REDIS_TOKEN` (sem Upstash).

```bash
OLD=$(aws secretsmanager get-secret-value --secret-id prodcontrol-prod-app-secrets --query SecretString --output text)
P() { aws ssm get-parameter --name "/prodcontrol/prod/$1" --query Parameter.Value --output text; }

NEW=$(jq -n --argjson old "$OLD" \
  --arg DB_HOST "$(P db/host)" --arg DB_PORT "$(P db/port)" --arg DB_USER "$(P db/user)" --arg DB "$(P db/name)" \
  --arg AWS_S3_REGION "$(P aws/s3/region)" --arg AWS_S3_BUCKET "$(P aws/s3/bucket)" \
  --arg AWS_S3_ACCESS_KEY_ID "$(P aws/s3/access_key_id)" \
  --arg AWS_SES_REGION "$(P aws/ses/region)" --arg AWS_SES_ACCESS_KEY "$(P aws/ses/access_key)" \
  --arg FROM_EMAIL "$(P email/from_email)" --arg FROM_NAME "$(P email/from_name)" \
  --arg GRAFANA_HOST "$(P grafana_host)" --arg GRAFANA_USER "$(P grafana_user)" \
  --arg CORS_ALLOWED_ORIGINS "$(P cors_allowed_origins)" \
  '$old + {DB_HOST:$DB_HOST, DB_PORT:$DB_PORT, DB_USER:$DB_USER, DB:$DB,
           AWS_S3_REGION:$AWS_S3_REGION, AWS_S3_BUCKET:$AWS_S3_BUCKET, AWS_S3_ACCESS_KEY_ID:$AWS_S3_ACCESS_KEY_ID,
           AWS_SES_REGION:$AWS_SES_REGION, AWS_SES_ACCESS_KEY:$AWS_SES_ACCESS_KEY,
           FROM_EMAIL:$FROM_EMAIL, FROM_NAME:$FROM_NAME,
           GRAFANA_HOST:$GRAFANA_HOST, GRAFANA_USER:$GRAFANA_USER,
           CORS_ALLOWED_ORIGINS:$CORS_ALLOWED_ORIGINS,
           APP_ENV:"prod"}
         | del(.REDIS_TOKEN, .REDIS_URL)')

echo "$NEW" | jq 'keys'          # confira as chaves
aws secretsmanager create-secret --name prodcontrol/prod/swarm \
  --description "Prodcontrol prod (Swarm) - gerenciado manualmente" \
  --secret-string "$NEW" --tags Key=Project,Value=prodcontrol Key=Environment,Value=prod-swarm
unset OLD NEW
```

> `APP_ENV`: hoje produção roda com `prod` (paridade mantida acima). O código só ativa logs no
> Grafana/Loki e a amostragem reduzida do Sentry com `production`. Decidir com a equipe.

---

## Fase 2: IAM, security group, EC2 e Elastic IP

```bash
cd bootstrap   # nesta pasta

# IAM role + instance profile
aws iam create-role --role-name prodcontrol-prod-swarm-role \
  --assume-role-policy-document file://trust-policy.json
aws iam attach-role-policy --role-name prodcontrol-prod-swarm-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam put-role-policy --role-name prodcontrol-prod-swarm-role \
  --policy-name prodcontrol-prod-swarm-app --policy-document file://iam-policy.json
aws iam create-instance-profile --instance-profile-name prodcontrol-prod-swarm-profile
aws iam add-role-to-instance-profile --instance-profile-name prodcontrol-prod-swarm-profile \
  --role-name prodcontrol-prod-swarm-role

# Security group: só 80 e 443 (sem SSH; acesso via Session Manager)
VPC_ID=vpc-XXXXXXXX          # da Fase 0
SUBNET_ID=subnet-XXXXXXXX    # subnet PÚBLICA da Fase 0
SG_ID=$(aws ec2 create-security-group --group-name prodcontrol-prod-swarm \
  --description "Prodcontrol Swarm - HTTP/HTTPS" --vpc-id "$VPC_ID" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
  'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}],Ipv6Ranges=[{CidrIpv6=::/0}]' \
  'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}],Ipv6Ranges=[{CidrIpv6=::/0}]'

# Se o banco tiver security group próprio, libere a porta 5432 para $SG_ID nele.

# AMI oficial Ubuntu 24.04 (Canonical)
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)

# Antes: edite ACME_EMAIL (e API_DOMAINS, se mudar) em user-data.sh
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" --instance-type t3.medium \
  --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
  --iam-instance-profile Name=prodcontrol-prod-swarm-profile \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3,Encrypted=true,DeleteOnTermination=false}' \
  --user-data file://user-data.sh \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=prodcontrol-prod-swarm},{Key=Project,Value=prodcontrol},{Key=Environment,Value=prod-swarm}]' \
    'ResourceType=volume,Tags=[{Key=Name,Value=prodcontrol-prod-swarm-root},{Key=Project,Value=prodcontrol},{Key=Backup,Value=daily}]' \
  --query "Instances[0].InstanceId" --output text)
echo "$INSTANCE_ID"

# Elastic IP
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=prodcontrol-prod-swarm}]' \
  --query AllocationId --output text)
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$EIP_ALLOC"
aws ec2 describe-addresses --allocation-ids "$EIP_ALLOC" --query "Addresses[0].PublicIp" --output text
```

Acompanhe o bootstrap pelo Session Manager: `sudo tail -f /var/log/prodcontrol-bootstrap.log`
(termina com "Bootstrap concluído"). Confira: `docker info | grep Swarm` → `active`.

### Proteções do nó único

```bash
# Auto-recovery em falha de hardware do host
aws cloudwatch put-metric-alarm --alarm-name prodcontrol-prod-swarm-recover \
  --namespace AWS/EC2 --metric-name StatusCheckFailed_System --statistic Maximum \
  --period 60 --evaluation-periods 2 --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold \
  --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
  --alarm-actions arn:aws:automate:us-east-2:ec2:recover
```

Snapshots diários: crie no console **EC2 → Lifecycle Manager** uma política para volumes com a
tag `Backup=daily`, retenção de 7 dias.

---

## Fase 3: domínio de teste e primeiro deploy

1. Route 53, zona `prodcontrol.app.br`: registro **A** `swarm.prodcontrol.app.br` → Elastic IP, TTL 300.
2. Faça o merge desta pasta no `main` do `prodsistem-setups` (a instância faz `git pull` a cada deploy).
   O user-data clona o repositório por HTTPS sem credenciais: confirme que ele continua acessível
   assim, ou ajuste o clone.
3. No GitHub do backend: **Actions → Deploy Production (Swarm) → Run workflow → deploy**.
   O certificado do Let's Encrypt é emitido no primeiro acesso HTTPS ao domínio.

Deploy manual (Session Manager), se precisar:

```bash
sudo bash /opt/prodcontrol/prodsistem-setups/swarm-prod/deploy.sh \
  665539166950.dkr.ecr.us-east-2.amazonaws.com/prodcontrol-prod@sha256:...
```

Comandos úteis na instância:

```bash
docker stack services prodcontrol
docker service logs -f prodcontrol_web
docker service ps prodcontrol_web
docker service rollback prodcontrol_web          # volta para a versão anterior
docker exec $(docker ps -qf name=prodcontrol_redis) redis-cli INFO memory | grep used_memory_human
sudo bash /opt/prodcontrol/prodsistem-setups/swarm-prod/reset-cache.sh --dry-run
```

---

## Fase 4: virada

1. Um dia antes: baixe o TTL do registro `prodcontrol.app.br` para 60 s.
2. Inclua o domínio de produção em `API_DOMAINS` (`/etc/prodcontrol/deploy.conf`), por exemplo
   `API_DOMAINS="prodcontrol.app.br,swarm.prodcontrol.app.br"`, e rode um deploy.
3. Troque o registro `prodcontrol.app.br` (hoje alias do ALB) por um **A** para o Elastic IP.
4. Rollback = voltar o registro para o alias do ALB. Mantenha a infra antiga ligada de 1 a 2 semanas.

## Fase 5: desligar a infra antiga

**Não use** a opção `destroy` do `deploy-prod.yml` sem antes tirar do state o que deve sobreviver.
O destroy apagaria o registro DNS de produção e os repositórios ECR:

```bash
terraform state rm 'aws_route53_record.api[0]'
terraform state rm 'aws_ecr_repository.prod'
# o ALB de prod tem deletion protection: desative antes do destroy
```

Depois: desativar `deploy-prod.yml` e `redis.yml`, e remover o Upstash.
