#!/bin/bash
# =============================================================================
# update-moodle.sh — Atualizacao segura do Moodle (roda no HOST)
# https://github.com/hellanio/moodle-safe-update
#
# Feito para Moodle 5.x (docroot em code/public/, CLI em code/admin/cli/)
# rodando em Docker Compose, com codigo do core num clone git e PostgreSQL.
#
# COMANDOS
#   ./update-moodle.sh check [--to <tag>]      Pre-voo: so le, nao altera nada.
#   ./update-moodle.sh minor [--to <tag>]      Atualiza dentro da branch atual:
#                                              ponta da branch, ou uma tag fixa
#                                              (recomendado: --to v5.1.7).
#   ./update-moodle.sh major <BRANCH>          Troca de versao maior
#                                              (ex.: MOODLE_502_STABLE).
#   ./update-moodle.sh rollback <manifesto>    Volta codigo e banco ao estado
#                                              registrado antes de um update.
#
# ORDEM DE UM UPDATE (para na primeira falha)
#   Com o site no ar:
#     1. Pre-voo: containers, acesso ao git, remoto alcancavel, destino existe
#        e e mais novo na mesma linha (version.php), arquivos do core alterados, plugins sem pasta,
#        espaco em disco, upgrade ja pendente. Tambem ja baixa os commits
#        novos (so o commit de destino; git fetch nao mexe nos arquivos em uso).
#   Com o site em manutencao:
#     2. Liga a manutencao e espera o cron que ja estava rodando terminar
#        (o laco de keepalive do cron NAO para sozinho quando a manutencao liga).
#     3. Backup do banco (pg_dump formato custom) e do codigo inteiro (menos
#        .git), mais um manifesto que o comando rollback usa.
#     4. Restaura bits de permissao perdidos em arquivos do core, avanca o
#        codigo ate o destino (reset --keep), composer install se o lockfile mudou, upgrade.php.
#     5. Limpa caches, confere plugins sensiveis, confere que nao ha upgrade
#        pendente e corrige dono dos caches.
#     6. Desliga a manutencao e confere o site por HTTP.
#
# Em qualquer falha depois do passo 2: o script PARA, deixa o site em
# manutencao e imprime o comando de rollback.
#
# POR QUE NAO "UM CLIQUE": dar ao servidor web permissao de escrita sobre o
# proprio codigo e a mesma superficie de um webshell. O git roda com o MESMO
# dono dos arquivos (sudo -u #uid), nunca como root: evita o erro "dubious
# ownership" do git e nao deixa arquivo de root no meio do codigo.
# =============================================================================
set -euo pipefail

# --- Configuracao ------------------------------------------------------------
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CODE_DIR="${PROJECT_DIR}/code"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_DIR}/backups}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"            # quantos conjuntos de backup manter
COMPOSE="${COMPOSE:-docker compose}"
MOODLE_SERVICE="${MOODLE_SERVICE:-moodle}"
DB_SERVICE="${DB_SERVICE:-db}"
MOODLE_CONTAINER_PATH="${MOODLE_CONTAINER_PATH:-/var/www/moodle}"
WEB_USER="${WEB_USER:-www-data}"             # usuario do PHP dentro do container
CLI_MAX_INPUT_VARS="${CLI_MAX_INPUT_VARS:-5000}"  # a checagem de ambiente exige >= 5000
CRON_WAIT="${CRON_WAIT:-300}"                # segundos esperando o cron em curso terminar
MIN_FREE_MB="${MIN_FREE_MB:-2048}"           # folga minima alem do tamanho previsto dos backups

if [ -f "${PROJECT_DIR}/.env" ]; then
    # shellcheck disable=SC1090
    source <(grep -E '^(DB_USER|DB_NAME|SENSITIVE_PLUGINS_CSV|MOODLE_SERVICE|DB_SERVICE|MOODLE_CONTAINER_PATH|PHP_VERSION|WEB_USER|KEEP_BACKUPS|CLI_MAX_INPUT_VARS|CRON_WAIT)=' "${PROJECT_DIR}/.env") || true
fi
DB_USER="${DB_USER:-moodleuser}"
DB_NAME="${DB_NAME:-moodle}"
PHP_BIN="php${PHP_VERSION:-}"

# Plugins "bundled" na arvore do core com patch local (ex.: um fork seu que
# vive em mod/<nome>). O script tira um hash antes e depois e avisa se mudou.
SENSITIVE_PLUGINS=()
if [ -n "${SENSITIVE_PLUGINS_CSV:-}" ]; then
    IFS=',' read -ra SENSITIVE_PLUGINS <<< "${SENSITIVE_PLUGINS_CSV}"
fi

# --- Argumentos --------------------------------------------------------------
CMD="${1:-}"; shift || true
TARGET_TAG=""; TARGET_BRANCH=""; MANIFEST_IN=""
case "${CMD}" in
    check|minor)
        while [ $# -gt 0 ]; do
            case "$1" in
                --to) TARGET_TAG="${2:-}"; shift 2 ;;
                *) echo "Argumento desconhecido: $1" >&2; exit 64 ;;
            esac
        done ;;
    major) TARGET_BRANCH="${1:-}" ;;
    rollback) MANIFEST_IN="${1:-}" ;;
    *) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac

# --- Utilitarios ---------------------------------------------------------------
STAMP=$(date '+%Y%m%d-%H%M%S')
STEP_T0=$(date +%s)
declare -a TIMINGS=()
MAINTENANCE_ON=0

log()  { echo "[update] $(date '+%H:%M:%S') $*"; }
step() {
    local now; now=$(date +%s)
    if [ -n "${CURRENT_STEP:-}" ]; then TIMINGS+=("$(( now - STEP_T0 ))s  ${CURRENT_STEP}"); fi
    CURRENT_STEP="$*"; STEP_T0=${now}
    log "== ${CURRENT_STEP}"
}
fail() {
    log "ERRO: $*"
    if [ "${MAINTENANCE_ON}" = 1 ]; then
        log "O site CONTINUA EM MANUTENCAO. Investigue ou volte com:"
        [ -n "${MANIFEST:-}" ] && log "  ./update-moodle.sh rollback ${MANIFEST}"
    fi
    exit 1
}
# Tudo o que for escrito na tela tambem vai para o log deste update.
start_log() {
    mkdir -p "${BACKUP_DIR}"
    LOG_FILE="${BACKUP_DIR}/update-${STAMP}.log"
    exec > >(tee -a "${LOG_FILE}") 2>&1
}
summary() {
    local now; now=$(date +%s)
    [ -n "${CURRENT_STEP:-}" ] && TIMINGS+=("$(( now - STEP_T0 ))s  ${CURRENT_STEP}")
    log "Tempo por etapa:"
    for t in "${TIMINGS[@]}"; do log "  ${t}"; done
    log "Log completo: ${LOG_FILE:-(sem log)}"
}

dc()          { ${COMPOSE} -f "${PROJECT_DIR}/docker-compose.yml" "$@"; }
# PHP CLI como o usuario do servidor web, dentro do container.
moodle_php()  { dc exec -T -u root "${MOODLE_SERVICE}" su -s /bin/bash "${WEB_USER}" -c "${PHP_BIN} -d max_input_vars=${CLI_MAX_INPUT_VARS} $*"; }
moodle_cli()  { moodle_php "${MOODLE_CONTAINER_PATH}/admin/cli/$*"; }
in_app()      { dc exec -T -u root "${MOODLE_SERVICE}" bash -c "$*"; }
# git com o mesmo dono dos arquivos (nunca root).
CODE_UID=$(stat -c '%u' "${CODE_DIR}" 2>/dev/null || echo 0)
code_git()    { sudo -n -u "#${CODE_UID}" git -C "${CODE_DIR}" "$@"; }
psql_db()     { dc exec -T "${DB_SERVICE}" psql -U "${DB_USER}" -d "$1" -v ON_ERROR_STOP=1 -Atc "$2" | tr -d '\r'; }
version_num() { grep -oP "^\\\$version\s*=\s*\K[0-9.]+" | head -1; }
branch_num()  { grep -oP "^\\\$branch\s*=\s*'\K[0-9]+" | head -1; }
release_of()  { grep -oP "\\\$release\s*=\s*'\K[^']+" "$1" | head -1; }
release_at()  { code_git show "$1:public/version.php" 2>/dev/null | grep -oP "\\\$release\s*=\s*'\K[^']+" | head -1; }
safe_name()   { echo "$1" | sed -e 's/+/plus/g' -e 's/[^A-Za-z0-9._-]\{1,\}/_/g' -e 's/_$//'; }
dirhash()     { sudo -n find "$1" -type f -print0 2>/dev/null | sort -z | sudo -n xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1; }

maintenance_on() {
    moodle_cli "maintenance.php --enable" >/dev/null || fail "Nao foi possivel ligar a manutencao."
    MAINTENANCE_ON=1
    log "Manutencao LIGADA."
}
maintenance_off() {
    moodle_cli "maintenance.php --disable" >/dev/null || fail "Falhou ao desligar a manutencao; desligue manualmente."
    MAINTENANCE_ON=0
    log "Manutencao DESLIGADA."
}

# O keepalive do cron roda tarefas por minutos depois que a manutencao liga.
# SIGTERM pede saida graciosa (o Moodle termina a tarefa atual e sai).
stop_running_cron() {
    local pattern='^/usr/bin/php[0-9.]* .*admin/cli/cron\.php'
    if in_app "pgrep -f '${pattern}' >/dev/null"; then
        log "Cron em execucao: pedindo saida graciosa (SIGTERM) e esperando ate ${CRON_WAIT}s..."
        in_app "pkill -TERM -f '${pattern}'" || true
        local waited=0
        while in_app "pgrep -f '${pattern}' >/dev/null"; do
            sleep 5; waited=$(( waited + 5 ))
            [ "${waited}" -ge "${CRON_WAIT}" ] && return 1
        done
        log "Cron terminou em ${waited}s."
    else
        log "Nenhum cron em execucao."
    fi
}

fix_cache_owner() {
    in_app "d=\$(grep -oP \"dataroot\\s*=\\s*'\\K[^']+\" ${MOODLE_CONTAINER_PATH}/config.php); for s in cache localcache temp; do [ -d \"\$d/\$s\" ] && find \"\$d/\$s\" ! -user ${WEB_USER} -exec chown ${WEB_USER}:${WEB_USER} {} + ; done; true"
}

http_check() {
    local url code
    url=$(moodle_php "-r 'define(\"CLI_SCRIPT\",1); require \"${MOODLE_CONTAINER_PATH}/config.php\"; echo \$CFG->wwwroot;'" 2>/dev/null | tail -1)
    code=$(curl -sk -o /dev/null -m 30 -w '%{http_code}' "${url}/login/index.php" || echo 000)
    log "HTTP ${url}/login/index.php -> ${code}"
    [ "${code}" = 200 ]
}

# Plugins registrados no banco sem pasta no disco travam o upgrade.
plugins_missing() {
    moodle_php "-r 'define(\"CLI_SCRIPT\",1); require \"${MOODLE_CONTAINER_PATH}/config.php\"; \$m=[]; foreach (core_plugin_manager::instance()->get_plugins() as \$t=>\$ps) foreach (\$ps as \$p) if (\$p->get_status()===core_plugin_manager::PLUGIN_STATUS_MISSING) \$m[]=\$p->component; echo implode(\",\",\$m);'" 2>/dev/null | tail -1
}

# --- Pre-voo -------------------------------------------------------------------
TARGET_REF=""; TARGET_DESC=""; MODE_ONLY_FILES=""
preflight() {
    step "Pre-voo (site no ar)"
    [ -f "${CODE_DIR}/public/version.php" ] || fail "Codigo do Moodle nao encontrado em ${CODE_DIR}."
    dc ps --status running --services 2>/dev/null | grep -qx "${MOODLE_SERVICE}" || fail "Container '${MOODLE_SERVICE}' parado."
    dc ps --status running --services 2>/dev/null | grep -qx "${DB_SERVICE}"     || fail "Container '${DB_SERVICE}' parado."
    command -v curl >/dev/null || fail "curl nao encontrado no host."

    # git com o dono dos arquivos
    code_git rev-parse --git-dir >/dev/null 2>&1 \
        || fail "git nao acessa ${CODE_DIR} como uid ${CODE_UID}. Precisa de sudo sem senha para 'sudo -u #${CODE_UID} git'."
    BRANCH=$(code_git branch --show-current)
    [ -n "${BRANCH}" ] || fail "O clone esta em HEAD solto; volte para uma branch antes (git checkout MOODLE_5xx_STABLE)."
    BEFORE=$(code_git rev-parse HEAD)
    RELEASE_BEFORE=$(release_of "${CODE_DIR}/public/version.php")
    log "Instalado: ${RELEASE_BEFORE} (branch ${BRANCH}, commit ${BEFORE:0:10})"

    # remoto e commits novos (fetch nao toca nos arquivos em uso)
    code_git ls-remote --exit-code origin HEAD >/dev/null 2>&1 || fail "Remoto 'origin' inalcancavel (rede, VPN ou proxy?)."
    # Clone raso (--depth): sem limite, buscar uma tag traz o historico INTEIRO do Moodle (~600 MB,
    # minutos), porque os merges trazem ramos antigos que o corte raso nao alcanca. E o historico nem
    # e necessario: o codigo vai direto para o commit de destino (reset --keep) e a seguranca contra
    # voltar versao vem do version.php, nao da ancestralidade do git. Busca so o commit de destino.
    FETCH_OPTS=(--quiet)
    if [ "$(code_git rev-parse --is-shallow-repository)" = true ]; then
        FETCH_OPTS+=(--depth=1)
    fi
    if [ "${CMD}" = major ]; then
        TARGET_REF="refs/heads/${TARGET_BRANCH}"
    elif [ -n "${TARGET_TAG}" ]; then
        [[ "${TARGET_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Tag invalida '${TARGET_TAG}' (esperado vX.Y.Z)."
        code_git fetch "${FETCH_OPTS[@]}" --no-tags origin "+refs/tags/${TARGET_TAG}:refs/tags/${TARGET_TAG}" \
            || fail "Tag ${TARGET_TAG} nao existe no remoto."
        TARGET_REF="refs/tags/${TARGET_TAG}"
    else
        code_git fetch "${FETCH_OPTS[@]}" origin "${BRANCH}" || fail "git fetch da ${BRANCH} falhou."
        TARGET_REF="refs/remotes/origin/${BRANCH}"
    fi
    TARGET=$(code_git rev-parse "${TARGET_REF}^{commit}")
    TARGET_DESC="$(release_at "${TARGET}") (${TARGET:0:10})"
    if [ "${TARGET}" = "${BEFORE}" ]; then
        log "Ja esta no destino ${TARGET_DESC}. Nada a fazer."
        return 2
    fi
    # Seguranca sem depender do historico: o destino precisa ser da mesma linha (minor) e mais novo.
    local vb vt bb bt
    vb=$(version_num < "${CODE_DIR}/public/version.php"); bb=$(branch_num < "${CODE_DIR}/public/version.php")
    vt=$(code_git show "${TARGET}:public/version.php" | version_num); bt=$(code_git show "${TARGET}:public/version.php" | branch_num)
    [ -n "${vt}" ] && [ -n "${bt}" ] || fail "Nao consegui ler o version.php do destino."
    if [ "${CMD}" = major ]; then
        [ "${bt}" -gt "${bb}" ] || fail "O destino (branch ${bt}) nao e uma versao maior que a instalada (${bb})."
    else
        [ "${bt}" = "${bb}" ] || fail "O destino e de outra linha (branch ${bt}, instalada ${bb}). Use o comando major."
    fi
    awk -v a="${vt}" -v b="${vb}" 'BEGIN { exit !(a + 0 > b + 0) }' \
        || fail "O destino ${TARGET_DESC} (versao ${vt}) nao e mais novo que o instalado (${vb})."
    log "Destino: ${TARGET_DESC} · versao ${vb} -> ${vt}"

    # arquivos rastreados alterados: so permissao e aceitavel (sera restaurada)
    local changed content
    changed=$(code_git status --porcelain --untracked-files=no | awk '{print $2}')
    if [ -n "${changed}" ]; then
        content=$(code_git -c core.fileMode=false status --porcelain --untracked-files=no | awk '{print $2}')
        [ -z "${content}" ] || fail "Arquivos do core com CONTEUDO alterado (patch local?): $(echo "${content}" | tr '\n' ' '). Salve o patch e restaure antes."
        MODE_ONLY_FILES="${changed}"
        log "AVISO: $(echo "${changed}" | wc -l) arquivo(s) do core so com permissao alterada; serao restaurados: $(echo "${changed}" | tr '\n' ' ')"
    fi

    # plugins sem pasta e upgrade ja pendente
    local missing; missing=$(plugins_missing)
    [ -z "${missing}" ] || fail "Plugins registrados sem pasta no disco (travariam o upgrade): ${missing}"
    if ! moodle_cli "upgrade.php --is-pending" >/dev/null 2>&1; then
        fail "Ja existe upgrade pendente ANTES da troca de codigo. Resolva isso primeiro (Administracao > Notificacoes)."
    fi

    # espaco: banco + codigo + folga
    local dbmb codemb freemb
    dbmb=$(dc exec -T "${DB_SERVICE}" psql -U "${DB_USER}" -d "${DB_NAME}" -Atc "select pg_database_size(current_database())/1048576" | tr -d '\r')
    codemb=$(sudo -n du -sm --exclude=.git "${CODE_DIR}" | cut -f1)
    freemb=$(df -Pm "${BACKUP_DIR%/*}" | awk 'NR==2{print $4}')
    log "Banco ${dbmb} MB · codigo ${codemb} MB · livre ${freemb} MB"
    [ "${freemb}" -gt $(( dbmb + codemb + MIN_FREE_MB )) ] || fail "Pouco espaco livre para os backups."

    # composer: preserva dependencias de desenvolvimento se ja estao instaladas
    COMPOSER_DEV_FLAG="--no-dev"
    [ -d "${CODE_DIR}/vendor/phpunit" ] && COMPOSER_DEV_FLAG=""
    log "Pre-voo OK."
    return 0
}

# --- Backup --------------------------------------------------------------------
backup() {
    step "Backup do banco e do codigo"
    mkdir -p "${BACKUP_DIR}"
    local tag; tag="$(safe_name "${RELEASE_BEFORE}")-${STAMP}"
    DB_DUMP="${BACKUP_DIR}/db-${tag}.dump"
    CODE_TAR="${BACKUP_DIR}/code-${tag}.tar.gz"
    MANIFEST="${BACKUP_DIR}/manifest-${tag}.env"

    dc exec -T "${DB_SERVICE}" pg_dump -U "${DB_USER}" -Fc -Z 6 "${DB_NAME}" > "${DB_DUMP}" \
        || { rm -f "${DB_DUMP}"; fail "pg_dump falhou."; }
    log "Banco: $(du -h "${DB_DUMP}" | cut -f1) (${DB_DUMP##*/})"

    # root le o codigo inteiro; o arquivo e gravado pelo usuario que rodou o script (de proposito).
    # shellcheck disable=SC2024
    sudo -n tar -C "${CODE_DIR}" --exclude=./.git -czf - . > "${CODE_TAR}" \
        || { rm -f "${CODE_TAR}"; fail "Backup do codigo falhou."; }
    log "Codigo: $(du -h "${CODE_TAR}" | cut -f1) (${CODE_TAR##*/})"

    cat > "${MANIFEST}" <<EOF
# Manifesto do update ${STAMP} — usado por: ./update-moodle.sh rollback <este arquivo>
UPDATE_STAMP=${STAMP}
RELEASE_BEFORE='${RELEASE_BEFORE}'
BRANCH=${BRANCH}
COMMIT_BEFORE=${BEFORE}
TARGET='${TARGET_DESC}'
COMMIT_TARGET=${TARGET}
DB_DUMP=${DB_DUMP}
CODE_TAR=${CODE_TAR}
EOF
    log "Manifesto: ${MANIFEST}"
    # Uma ref para o commit de antes: o gc do git nunca o apaga enquanto o backup existir.
    code_git update-ref "refs/moodle-safe-update/before-${STAMP}" "${BEFORE}" || fail "Nao consegui marcar o commit de antes."

    # retencao: conjuntos mais antigos alem de KEEP_BACKUPS
    local old
    for old in $(ls -1t "${BACKUP_DIR}"/manifest-*.env 2>/dev/null | tail -n +$(( KEEP_BACKUPS + 1 ))); do
        # shellcheck disable=SC1090
        ( source "${old}"; rm -f "${DB_DUMP}" "${CODE_TAR}" "${old}"; code_git update-ref -d "refs/moodle-safe-update/before-${UPDATE_STAMP}" 2>/dev/null || true ) \
            && log "Retencao: removido ${old##*/}"
    done
}

# --- Update --------------------------------------------------------------------
do_update() {
    local pre=()
    for p in "${SENSITIVE_PLUGINS[@]}"; do pre+=("$(dirhash "${CODE_DIR}/public/${p}")"); done

    step "Manutencao e cron"
    maintenance_on
    stop_running_cron || { maintenance_off; fail "O cron nao terminou em ${CRON_WAIT}s. Nada foi alterado; tente de novo."; }

    backup

    step "Troca do codigo"
    if [ -n "${MODE_ONLY_FILES}" ]; then
        # shellcheck disable=SC2086
        code_git checkout -- ${MODE_ONLY_FILES} || fail "Nao consegui restaurar as permissoes dos arquivos do core."
        log "Permissoes restauradas em $(echo "${MODE_ONLY_FILES}" | wc -l) arquivo(s)."
    fi
    # reset --keep leva a branch e os arquivos ao destino sem precisar de historico (clone raso) e
    # recusa se isso fosse apagar alteracao local; plugins nao rastreados nao sao tocados.
    if [ "${CMD}" = major ]; then
        code_git checkout --quiet -B "${TARGET_BRANCH}" "${TARGET}" || fail "checkout da ${TARGET_BRANCH} falhou."
    else
        code_git reset --quiet --keep "${TARGET}" || fail "Troca do git para ${TARGET_DESC} falhou."
    fi
    RELEASE_AFTER=$(release_of "${CODE_DIR}/public/version.php")
    log "Codigo agora em ${RELEASE_AFTER} (${TARGET:0:10})."

    if ! code_git diff --quiet "${BEFORE}" "${TARGET}" -- composer.json composer.lock; then
        step "Dependencias (composer.lock mudou)"
        dc exec -T -u "${WEB_USER}" -e COMPOSER_HOME=/tmp/composer "${MOODLE_SERVICE}" \
            bash -c "cd ${MOODLE_CONTAINER_PATH} && composer install ${COMPOSER_DEV_FLAG} --classmap-authoritative --no-interaction --quiet" \
            || fail "composer install falhou."
    else
        log "composer.lock igual: dependencias mantidas."
    fi

    step "upgrade.php"
    moodle_cli "upgrade.php --non-interactive" || fail "upgrade.php falhou."

    step "Caches e conferencias"
    moodle_cli "purge_caches.php" || log "AVISO: purge_caches falhou (nao fatal)."
    fix_cache_owner || log "AVISO: nao consegui conferir o dono dos caches."
    moodle_cli "upgrade.php --is-pending" >/dev/null 2>&1 || fail "Ainda ha upgrade pendente depois do upgrade.php."
    local missing; missing=$(plugins_missing)
    [ -z "${missing}" ] || fail "Plugins sem pasta depois da troca: ${missing}"
    for i in "${!SENSITIVE_PLUGINS[@]}"; do
        if [ "$(dirhash "${CODE_DIR}/public/${SENSITIVE_PLUGINS[$i]}")" != "${pre[$i]}" ]; then
            log "AVISO: '${SENSITIVE_PLUGINS[$i]}' MUDOU nesta atualizacao. Confira contra o seu fork."
        else
            log "OK: '${SENSITIVE_PLUGINS[$i]}' intacto."
        fi
    done

    step "Volta ao ar"
    maintenance_off
    http_check || log "AVISO: a pagina de login nao respondeu 200. Confira o site agora."
    log "Atualizado: ${RELEASE_BEFORE} -> ${RELEASE_AFTER}."
}

# --- Rollback ------------------------------------------------------------------
do_rollback() {
    [ -f "${MANIFEST_IN}" ] || fail "Manifesto nao encontrado: ${MANIFEST_IN}"
    # shellcheck disable=SC1090
    source "${MANIFEST_IN}"
    MANIFEST="${MANIFEST_IN}"
    [ -f "${DB_DUMP}" ] && [ -f "${CODE_TAR}" ] || fail "Backups citados no manifesto nao existem."
    log "Rollback para ${RELEASE_BEFORE} (commit ${COMMIT_BEFORE:0:10}) usando ${MANIFEST_IN##*/}"

    step "Manutencao e cron"
    maintenance_on
    stop_running_cron || log "AVISO: cron ainda rodando apos ${CRON_WAIT}s; seguindo mesmo assim."

    step "Codigo"
    code_git checkout --quiet "${BRANCH}" 2>/dev/null || true
    code_git reset --keep "${COMMIT_BEFORE}" || fail "git reset para ${COMMIT_BEFORE:0:10} falhou."
    sudo -n -u "#${CODE_UID}" tar -C "${CODE_DIR}" -xzf "${CODE_TAR}" || fail "Restauracao do codigo falhou."
    log "Codigo: $(release_of "${CODE_DIR}/public/version.php")"

    step "Banco (restaura num banco novo e troca os nomes no fim)"
    # Nao restaurar POR CIMA do banco em uso: um pg_restore --clean em transacao unica derruba
    # centenas de tabelas de uma vez e estoura max_locks_per_transaction; sem transacao unica, uma
    # falha no meio deixa um banco pela metade. Aqui o banco atual so e tocado quando a copia
    # restaurada esta completa, e fica guardado com outro nome.
    local restoredb="${DB_NAME}_rb_${STAMP//-/_}" keepdb="${DB_NAME}_pre_rollback_${STAMP//-/_}" meta
    meta=$(psql_db postgres "select pg_encoding_to_char(encoding)||'|'||datcollate||'|'||datctype||'|'||pg_get_userbyid(datdba) from pg_database where datname='${DB_NAME}'")
    IFS='|' read -r enc coll ctype owner <<< "${meta}"
    [ -n "${owner}" ] || fail "Nao consegui ler o banco ${DB_NAME}."
    psql_db postgres "CREATE DATABASE \"${restoredb}\" WITH TEMPLATE template0 ENCODING '${enc}' LC_COLLATE '${coll}' LC_CTYPE '${ctype}' OWNER \"${owner}\"" >/dev/null \
        || fail "Nao consegui criar o banco temporario ${restoredb} (o usuario precisa de CREATEDB)."
    if ! dc exec -T "${DB_SERVICE}" pg_restore -U "${DB_USER}" -d "${restoredb}" --no-owner --exit-on-error < "${DB_DUMP}"; then
        psql_db postgres "DROP DATABASE IF EXISTS \"${restoredb}\"" >/dev/null || true
        fail "pg_restore falhou. O banco em uso NAO foi alterado."
    fi
    log "Copia restaurada em ${restoredb}. Trocando os nomes..."
    psql_db postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('${DB_NAME}','${restoredb}') AND pid <> pg_backend_pid()" >/dev/null || true
    psql_db postgres "ALTER DATABASE \"${DB_NAME}\" RENAME TO \"${keepdb}\"" >/dev/null || fail "Nao consegui renomear o banco atual."
    psql_db postgres "ALTER DATABASE \"${restoredb}\" RENAME TO \"${DB_NAME}\"" >/dev/null \
        || { psql_db postgres "ALTER DATABASE \"${keepdb}\" RENAME TO \"${DB_NAME}\"" >/dev/null; fail "Troca de nomes falhou; banco original devolvido."; }
    log "Banco restaurado. O banco de antes do rollback ficou como ${keepdb}."
    log "  Depois de conferir, apague com: ${COMPOSE} exec ${DB_SERVICE} dropdb -U ${DB_USER} ${keepdb}"

    step "Caches e volta ao ar"
    moodle_cli "purge_caches.php" || true
    fix_cache_owner || true
    moodle_cli "upgrade.php --is-pending" >/dev/null 2>&1 || fail "Depois do rollback o Moodle pede upgrade: codigo e banco nao batem."
    maintenance_off
    http_check || log "AVISO: a pagina de login nao respondeu 200."
    log "Rollback concluido."
}

# --- Principal -----------------------------------------------------------------
cd "${PROJECT_DIR}"
exec 9>"${BACKUP_DIR%/}/.update.lock" 2>/dev/null || { mkdir -p "${BACKUP_DIR}"; exec 9>"${BACKUP_DIR%/}/.update.lock"; }
flock -n 9 || { echo "Outro update-moodle.sh esta rodando." >&2; exit 75; }

case "${CMD}" in
    check)
        rc=0; preflight || rc=$?
        [ "${rc}" -eq 2 ] && exit 0
        log "Nada foi alterado."
        ;;
    minor|major)
        if [ "${CMD}" = major ]; then
            [[ "${TARGET_BRANCH}" =~ ^MOODLE_[0-9]+_STABLE$ ]] || { echo "Uso: $0 major MOODLE_5xx_STABLE" >&2; exit 64; }
            code_git fetch --quiet origin "+refs/heads/${TARGET_BRANCH}:refs/heads/${TARGET_BRANCH}" || { echo "Branch ${TARGET_BRANCH} inexistente." >&2; exit 1; }
        fi
        start_log
        rc=0; preflight || rc=$?
        if [ "${rc}" -eq 2 ]; then summary; exit 0; fi
        do_update
        summary
        ;;
    rollback)
        start_log
        do_rollback
        summary
        ;;
esac
