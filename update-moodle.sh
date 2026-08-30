#!/bin/bash
# =============================================================================
# update-moodle.sh — Atualizacao automatizada e segura do Moodle (roda no HOST)
#
# https://github.com/hellanio/moodle-safe-update
#
# Feito para um Moodle rodando em Docker Compose com a estrutura do Moodle
# 5.x (docroot em code/public/, scripts CLI em code/admin/cli/*.php,
# operacoes git na raiz code/) e Postgres como banco.
#
# O QUE ELE FAZ (nessa ordem, parando na primeira falha):
#   1. Liga o modo de manutencao (site fica indisponivel para usuarios comuns)
#   2. Backup do banco (pg_dump comprimido)
#   3. Backup do codigo (tar.gz de code/public/, como estava ANTES do pull)
#   4. git fetch + pull --ff-only (modo "minor") OU checkout de outra branch
#      (modo "major", so quando pedido explicitamente)
#   5. composer install (so reinstala se o lockfile mudou)
#   6. admin/cli/upgrade.php --non-interactive (migracao de banco)
#   7. Limpeza de caches
#   8. Confere se os plugins listados em SENSITIVE_PLUGINS nao foram
#      sobrescritos pela atualizacao do core (ver secao abaixo)
#   9. Desliga o modo de manutencao
#
# NAO existe atualizacao de core "de um clique" no Moodle, por design de
# seguranca: dar ao processo do servidor web permissao de escrita sobre o
# proprio codigo que ele executa e a mesma superficie de ataque de um
# webshell. Este script faz, de forma auditavel e com backup automatico, o
# que precisaria ser feito manualmente de qualquer jeito: trocar o codigo
# via git (como um usuario com permissao — nunca como www-data) e rodar o
# upgrade.php.
#
# Uso:
#   ./update-moodle.sh minor                    # patch dentro da branch atual
#   ./update-moodle.sh major MOODLE_502_STABLE  # troca de branch/versao maior
#
# Ver README.md para pre-requisitos, configuracao de sudo com privilegio
# minimo, agendamento via cron e como restaurar a partir dos backups.
#
# Em caso de falha em qualquer etapa: o script PARA, MANTEM o modo de
# manutencao ativo (site protegido) e preserva os backups (banco + codigo)
# para restauracao.
# =============================================================================
set -euo pipefail

# --- Configuracao ------------------------------------------------------------
# Raiz do projeto docker-compose (onde ficam docker-compose.yml, code/ e
# backups/). Por padrao e a pasta ONDE ESTE SCRIPT ESTA — copie-o para dentro
# do seu projeto, ou exporte PROJECT_DIR antes de chamar o script se preferir
# mante-lo em outro lugar.
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CODE_DIR="${PROJECT_DIR}/code"
BACKUP_DIR="${PROJECT_DIR}/backups"
KEEP_BACKUPS="${KEEP_BACKUPS:-14}"           # quantos backups (banco + codigo) manter
COMPOSE="${COMPOSE:-docker compose}"         # use "docker-compose" se estiver no v1
MOODLE_SERVICE="${MOODLE_SERVICE:-moodle}"   # nome do servico da app no docker-compose.yml
DB_SERVICE="${DB_SERVICE:-db}"               # nome do servico do banco no docker-compose.yml
MOODLE_CONTAINER_PATH="${MOODLE_CONTAINER_PATH:-/var/www/moodle}"  # docroot DENTRO do container

# Le configuracao do .env do projeto (mesma pasta do docker-compose.yml).
# Qualquer uma destas variaveis pode ser exportada no ambiente em vez de
# colocada no .env — a env do processo tem prioridade.
if [ -f "${PROJECT_DIR}/.env" ]; then
    # shellcheck disable=SC1091
    source <(grep -E '^(DB_USER|DB_NAME|SENSITIVE_PLUGINS_CSV|MOODLE_SERVICE|DB_SERVICE|MOODLE_CONTAINER_PATH|PHP_VERSION)=' "${PROJECT_DIR}/.env") || true
fi
DB_USER="${DB_USER:-moodleuser}"
DB_NAME="${DB_NAME:-moodle}"

# Plugins de terceiros "bundled" na MESMA arvore que o git do core rastreia,
# nos quais voce aplicou patch local direto no arquivo (ex.: um fork seu de
# um plugin popular que vive dentro de mod/<nome> em vez de instalado a
# parte). Esses SIM correm risco real de ter o patch sobrescrito num update
# do core — o script tira um hash do conteudo antes e depois do pull e avisa
# no log se mudou.
#
# Deixe vazio se nao for o seu caso — a maioria dos plugins de terceiros vive
# em pastas que o Moodle oficial nem conhece (ex.: local/meuplugin), entao
# nunca sao tocados por um "git pull" no core e nao precisam entrar aqui.
#
# Configure via .env: SENSITIVE_PLUGINS_CSV=mod/attendance,local/outro
SENSITIVE_PLUGINS=()
if [ -n "${SENSITIVE_PLUGINS_CSV:-}" ]; then
    IFS=',' read -ra SENSITIVE_PLUGINS <<< "${SENSITIVE_PLUGINS_CSV}"
fi

MODE="${1:-minor}"
TARGET_BRANCH="${2:-}"

log()  { echo "[update] $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
fail() { log "ERRO: $*"; log "Modo de manutencao PERMANECE ATIVO. Investigue antes de reativar o site."; exit 1; }

# Hash do conteudo de um diretorio (ignora dono/permissao/mtime, so reage a
# mudanca real de conteudo ou do conjunto de arquivos).
dirhash() {
    find "$1" -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
}

# Executa PHP CLI dentro do container da aplicacao, como www-data
moodle_php() {
    ${COMPOSE} -f "${PROJECT_DIR}/docker-compose.yml" exec -T "${MOODLE_SERVICE}" \
        su -s /bin/bash www-data -c "php\${PHP_VERSION:-8.3} $*"
}

# --- Validacoes iniciais ------------------------------------------------------
cd "${PROJECT_DIR}"

case "${MODE}" in
    minor) ;;
    major)
        [ -n "${TARGET_BRANCH}" ] || fail "Modo major exige a branch de destino. Ex: ./update-moodle.sh major MOODLE_502_STABLE"
        [[ "${TARGET_BRANCH}" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "Nome de branch invalido: '${TARGET_BRANCH}'"
        ;;
    *) fail "Modo invalido '${MODE}'. Use: minor | major <BRANCH>" ;;
esac

[ -f "${CODE_DIR}/public/version.php" ] || fail "Codigo do Moodle nao encontrado em ${CODE_DIR} (public/version.php ausente)."

${COMPOSE} ps --status running --services 2>/dev/null | grep -q "^${MOODLE_SERVICE}$" || fail "Container '${MOODLE_SERVICE}' nao esta rodando."
${COMPOSE} ps --status running --services 2>/dev/null | grep -q "^${DB_SERVICE}$"     || fail "Container '${DB_SERVICE}' nao esta rodando."

CURRENT_BRANCH=$(git -C "${CODE_DIR}" branch --show-current)
CURRENT_RELEASE=$(grep -oP "\\\$release\s*=\s*'[^']+'" "${CODE_DIR}/public/version.php" | head -1 | cut -d\' -f2 || echo "?")
log "Moodle atual: ${CURRENT_RELEASE} (branch ${CURRENT_BRANCH}) | modo: ${MODE}${TARGET_BRANCH:+ -> ${TARGET_BRANCH}}"

# --- 1. Modo de manutencao ----------------------------------------------------
log "Ativando modo de manutencao..."
moodle_php "${MOODLE_CONTAINER_PATH}/admin/cli/maintenance.php --enable" || fail "Nao foi possivel ativar o modo de manutencao."

# --- 2. Backup do banco --------------------------------------------------------
mkdir -p "${BACKUP_DIR}"
STAMP=$(date '+%Y%m%d-%H%M%S')
DUMP="${BACKUP_DIR}/moodle-${CURRENT_RELEASE// /_}-${STAMP}.sql.gz"
log "Gerando backup do banco em ${DUMP}..."
${COMPOSE} exec -T "${DB_SERVICE}" pg_dump -U "${DB_USER}" "${DB_NAME}" | gzip > "${DUMP}" \
    || fail "pg_dump falhou. Nada foi alterado; backup incompleto removido: $(rm -f "${DUMP}" && echo ok)"
log "Backup concluido: $(du -h "${DUMP}" | cut -f1)."

# Retencao: mantem apenas os N mais recentes
ls -1t "${BACKUP_DIR}"/moodle-*.sql.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f

# --- 2b. Backup do codigo (code/public, como esta ANTES do pull) ---------------
CODE_DUMP="${BACKUP_DIR}/code-${CURRENT_RELEASE// /_}-${STAMP}.tar.gz"
log "Gerando backup do codigo em ${CODE_DUMP}..."
tar -C "${CODE_DIR}" -czf "${CODE_DUMP}" public \
    || fail "Backup do codigo falhou. Nada foi alterado; banco ja tem backup em ${DUMP}."
log "Backup do codigo concluido: $(du -h "${CODE_DUMP}" | cut -f1)."

ls -1t "${BACKUP_DIR}"/code-*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f

# Snapshot dos plugins sensiveis ANTES do pull, para conferir depois
PRE_HASHES=()
for p in "${SENSITIVE_PLUGINS[@]}"; do
    PRE_HASHES+=("$(dirhash "${CODE_DIR}/public/${p}")")
done

# --- 3. Atualizacao do codigo (git na RAIZ do code/) ---------------------------
log "Buscando atualizacoes do repositorio oficial..."
sudo git -C "${CODE_DIR}" fetch origin --prune || fail "git fetch falhou."

if [ "${MODE}" = "minor" ]; then
    BEFORE=$(git -C "${CODE_DIR}" rev-parse HEAD)
    sudo git -C "${CODE_DIR}" pull --ff-only origin "${CURRENT_BRANCH}" || fail "git pull falhou (branch ${CURRENT_BRANCH})."
    AFTER=$(git -C "${CODE_DIR}" rev-parse HEAD)
    if [ "${BEFORE}" = "${AFTER}" ]; then
        log "Nenhuma atualizacao disponivel na ${CURRENT_BRANCH}. Desativando manutencao e saindo."
        moodle_php "${MOODLE_CONTAINER_PATH}/admin/cli/maintenance.php --disable"
        exit 0
    fi
    log "Codigo atualizado: ${BEFORE:0:8} -> ${AFTER:0:8}."
else
    log "Trocando para a branch ${TARGET_BRANCH}..."
    sudo git -C "${CODE_DIR}" checkout "${TARGET_BRANCH}" || fail "checkout da ${TARGET_BRANCH} falhou."
    sudo git -C "${CODE_DIR}" pull --ff-only origin "${TARGET_BRANCH}" || fail "git pull da ${TARGET_BRANCH} falhou."
fi

# Reaplica dono www-data no que o git trouxe (git rodou como root via sudo)
sudo chown -R www-data:www-data "${CODE_DIR}" 2>/dev/null \
    || ${COMPOSE} exec -T "${MOODLE_SERVICE}" chown -R www-data:www-data "${MOODLE_CONTAINER_PATH}"

# --- 4. Dependencias do Composer (se o lockfile mudou, reinstala) ---------------
log "Atualizando dependencias do Composer..."
${COMPOSE} exec -T "${MOODLE_SERVICE}" bash -c "cd ${MOODLE_CONTAINER_PATH} && composer install --no-dev --classmap-authoritative --no-interaction --quiet" \
    || fail "composer install falhou."

# --- 5. Upgrade do banco (CLI na raiz, nunca em public/) ------------------------
log "Executando upgrade do Moodle (non-interactive)..."
moodle_php "${MOODLE_CONTAINER_PATH}/admin/cli/upgrade.php --non-interactive" || fail "upgrade.php falhou. Backups disponiveis: banco em ${DUMP}, codigo em ${CODE_DUMP}."

# --- 6. Limpeza de caches -------------------------------------------------------
log "Limpando caches..."
moodle_php "${MOODLE_CONTAINER_PATH}/admin/cli/purge_caches.php" || log "AVISO: purge_caches falhou (nao-fatal)."

# --- 6b. Verificacao de integridade dos plugins sensiveis -----------------------
for i in "${!SENSITIVE_PLUGINS[@]}"; do
    p="${SENSITIVE_PLUGINS[$i]}"
    NEW_HASH="$(dirhash "${CODE_DIR}/public/${p}")"
    if [ "${NEW_HASH}" != "${PRE_HASHES[$i]}" ]; then
        log "AVISO: o conteudo de '${p}' MUDOU durante esta atualizacao. Isso pode indicar que o update sobrescreveu patches locais. Confira contra o seu fork antes de considerar o update finalizado — backup de codigo pre-update em ${CODE_DUMP}."
    else
        log "OK: '${p}' permaneceu inalterado (patches locais preservados)."
    fi
done

# --- 7. Desativa manutencao -----------------------------------------------------
log "Desativando modo de manutencao..."
moodle_php "${MOODLE_CONTAINER_PATH}/admin/cli/maintenance.php --disable" || fail "Site atualizado, mas falhou ao SAIR da manutencao — desative manualmente."

NEW_RELEASE=$(grep -oP "\\\$release\s*=\s*'[^']+'" "${CODE_DIR}/public/version.php" | head -1 | cut -d\' -f2 || echo "?")
log "Atualizacao concluida com sucesso: ${CURRENT_RELEASE} -> ${NEW_RELEASE}."
