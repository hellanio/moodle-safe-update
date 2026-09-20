#!/bin/bash
# =============================================================================
# backup-moodle.sh — Backup diario do Moodle (roda no HOST)
# https://github.com/hellanio/moodle-safe-update
#
# Companheiro do update-moodle.sh. Aquele tira UM backup antes de mexer no
# core; este e a rotina de todo dia, e sabe RESTAURAR.
#
# Feito para Moodle 5.x (docroot em code/public/, CLI em code/admin/cli/)
# rodando em Docker Compose, com PostgreSQL.
#
# COMANDOS
#   ./backup-moodle.sh run                  Tira um backup. E o comando do cron.
#   ./backup-moodle.sh list                 Lista os conjuntos guardados.
#   ./backup-moodle.sh verify [<manifesto>] Restaura o dump num banco descartavel
#                                           e confere contra o que foi gravado no
#                                           backup. NAO toca no site. Sem argumento,
#                                           verifica o backup mais recente.
#   ./backup-moodle.sh restore <manifesto>  Restauracao de verdade. Pede confirmacao.
#   ./backup-moodle.sh prune                So aplica a retencao.
#
# O QUE ENTRA NO BACKUP
#   - Banco: pg_dump formato custom (-Fc), comprimido. Consistente sozinho:
#     o Postgres tira um snapshot MVCC, entao NAO e preciso tirar o site do ar.
#   - moodledata: snapshot com rsync --link-dest do backup anterior. Como o
#     filedir do Moodle e imutavel (arquivo nomeado pelo hash do conteudo), o
#     que nao mudou vira hardlink e custa zero byte. Um snapshot diario de um
#     moodledata de 50 GB ocupa so o que entrou naquele dia.
#   - Codigo: tar.gz da arvore (sem .git). Inclui o config.php e os plugins,
#     que e o que o git do core nao guarda.
#
#   Caches, temp, trashdir e sessoes ficam de fora: sao regeneraveis e so
#   engordariam o backup e a restauracao. O muc/ FICA (guarda a configuracao
#   dos armazenamentos de cache, nao os dados).
#
# ORDEM, E POR QUE ELA IMPORTA
#   O banco e copiado ANTES dos arquivos. O Moodle nunca apaga um arquivo do
#   filedir na hora (vai para o trashdir e so o cron remove depois), entao todo
#   arquivo citado pelo dump ainda existe quando o rsync passa. Na ordem
#   inversa, um arquivo enviado no meio do backup entraria no banco e ficaria
#   fora da copia — e viraria um anexo quebrado na restauracao.
#
# RESTAURACAO SEM PONTO SEM VOLTA
#   Nada e sobrescrito no lugar. O banco e restaurado num banco NOVO e so
#   depois os nomes sao trocados (o antigo fica guardado como
#   <banco>_pre_restore_<data>); o moodledata atual e movido para o lado antes
#   de o snapshot entrar. Se a restauracao der errado, os dois voltam com um
#   rename. (Restaurar POR CIMA com pg_restore --clean --single-transaction em
#   um Moodle real estoura max_locks_per_transaction: sao milhares de tabelas.)
#
# CONFIGURACAO (env ou .env do projeto)
#   BACKUP_DIR        onde guardar            (padrao: <projeto>/backups)
#   KEEP_DAILY        diarios a manter        (padrao: 7)
#   KEEP_WEEKLY       semanais a manter       (padrao: 4)
#   WEEKLY_DOW        dia do semanal, 1=seg   (padrao: 7 = domingo)
#   BACKUP_REMOTE     destino rsync fora do host, ex.: user@host:/backups/moodle
#   BACKUP_REMOTE_OPTS  opcoes extras do rsync remoto (ex.: -e 'ssh -p 2222')
#   MIN_FREE_MB       folga minima em disco   (padrao: 5120)
#   HTTP_WAIT         espera o site voltar, s  (padrao: 180)
#   DB_PREFIX         prefixo das tabelas     (padrao: mdl_)
#
# UM BACKUP QUE NUNCA FOI RESTAURADO NAO E UM BACKUP.
# Rode `verify` no cron tambem. Ele prova o dump sem tocar no site.
#
# CRON SUGERIDO (diario as 3h, e verificacao as 4h)
#   0 3 * * * /opt/moodle-docker/backup-moodle.sh run    >> /var/log/moodle-backup.log 2>&1
#   0 4 * * * /opt/moodle-docker/backup-moodle.sh verify >> /var/log/moodle-backup.log 2>&1
# =============================================================================
set -euo pipefail

# --- Configuracao ------------------------------------------------------------
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CODE_DIR="${CODE_DIR:-${PROJECT_DIR}/code}"
DATA_DIR="${DATA_DIR:-${PROJECT_DIR}/moodledata}"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_DIR}/backups}"
COMPOSE="${COMPOSE:-docker compose}"
MOODLE_SERVICE="${MOODLE_SERVICE:-moodle}"
DB_SERVICE="${DB_SERVICE:-db}"
MOODLE_CONTAINER_PATH="${MOODLE_CONTAINER_PATH:-/var/www/moodle}"
WEB_USER="${WEB_USER:-www-data}"
CLI_MAX_INPUT_VARS="${CLI_MAX_INPUT_VARS:-5000}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
WEEKLY_DOW="${WEEKLY_DOW:-7}"
MIN_FREE_MB="${MIN_FREE_MB:-5120}"
HTTP_WAIT="${HTTP_WAIT:-180}"   # quanto esperar o site voltar depois de uma restauracao

if [ -f "${PROJECT_DIR}/.env" ]; then
    # shellcheck disable=SC1090
    source <(grep -E '^(DB_USER|DB_NAME|MOODLE_SERVICE|DB_SERVICE|MOODLE_CONTAINER_PATH|PHP_VERSION|WEB_USER|DB_PREFIX|BACKUP_DIR|BACKUP_REMOTE|BACKUP_REMOTE_OPTS|KEEP_DAILY|KEEP_WEEKLY|WEEKLY_DOW|CLI_MAX_INPUT_VARS)=' "${PROJECT_DIR}/.env") || true
fi
DB_USER="${DB_USER:-moodleuser}"
DB_NAME="${DB_NAME:-moodle}"
DB_PREFIX="${DB_PREFIX:-mdl_}"
PHP_BIN="php${PHP_VERSION:-}"
BACKUP_REMOTE="${BACKUP_REMOTE:-}"
BACKUP_REMOTE_OPTS="${BACKUP_REMOTE_OPTS:-}"

# Diretorios do dataroot que nao entram: regeneraveis. `muc` NAO esta aqui de
# proposito (guarda a configuracao dos caches, nao os dados).
DATA_EXCLUDES=(cache localcache temp trashdir sessions lock)

# --- Argumentos --------------------------------------------------------------
CMD="${1:-}"; shift || true
MANIFEST_IN="${1:-}"
RESTORE_DB=1; RESTORE_DATA=1; RESTORE_CODE=1
case "${CMD}" in
    run|list|prune) ;;
    verify) ;;
    restore)
        shift || true
        while [ $# -gt 0 ]; do
            case "$1" in
                --db-only)  RESTORE_DATA=0; RESTORE_CODE=0 ;;
                --no-data)  RESTORE_DATA=0 ;;
                --no-code)  RESTORE_CODE=0 ;;
                *) echo "Argumento desconhecido: $1" >&2; exit 64 ;;
            esac
            shift
        done ;;
    *) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac

# --- Utilitarios ---------------------------------------------------------------
STAMP=$(date '+%Y%m%d-%H%M%S')
DAYSTAMP=$(date '+%Y%m%d')
STEP_T0=$(date +%s)
declare -a TIMINGS=()
declare -a WARNINGS=()

log()  { echo "[backup] $(date '+%H:%M:%S') $*"; }
warn() { WARNINGS+=("$*"); log "AVISO: $*"; }
step() {
    local now; now=$(date +%s)
    if [ -n "${CURRENT_STEP:-}" ]; then TIMINGS+=("$(( now - STEP_T0 ))s  ${CURRENT_STEP}"); fi
    CURRENT_STEP="$*"; STEP_T0=${now}
    log "== ${CURRENT_STEP}"
}
fail() { log "ERRO: $*"; exit 1; }
summary() {
    local now; now=$(date +%s)
    [ -n "${CURRENT_STEP:-}" ] && TIMINGS+=("$(( now - STEP_T0 ))s  ${CURRENT_STEP}")
    log "Tempo por etapa:"
    for t in "${TIMINGS[@]}"; do log "  ${t}"; done
    if [ ${#WARNINGS[@]} -gt 0 ]; then
        log "Avisos desta execucao:"
        for w in "${WARNINGS[@]}"; do log "  ! ${w}"; done
    fi
}

dc()          { ${COMPOSE} -f "${PROJECT_DIR}/docker-compose.yml" "$@"; }
moodle_php()  { dc exec -T -u root "${MOODLE_SERVICE}" su -s /bin/bash "${WEB_USER}" -c "${PHP_BIN} -d max_input_vars=${CLI_MAX_INPUT_VARS} $*"; }
moodle_cli()  { moodle_php "${MOODLE_CONTAINER_PATH}/admin/cli/$*"; }
in_app()      { dc exec -T -u root "${MOODLE_SERVICE}" bash -c "$*"; }
psql_db()     { dc exec -T "${DB_SERVICE}" psql -U "${DB_USER}" -d "$1" -v ON_ERROR_STOP=1 -Atc "$2" | tr -d '\r'; }
human()       { sudo -n du -sh "$1" 2>/dev/null | cut -f1; }

fix_cache_owner() {
    in_app "d=\$(grep -oP \"dataroot\\s*=\\s*'\\K[^']+\" ${MOODLE_CONTAINER_PATH}/config.php); for s in cache localcache temp; do [ -d \"\$d/\$s\" ] && find \"\$d/\$s\" ! -user ${WEB_USER} -exec chown ${WEB_USER}:${WEB_USER} {} + ; done; true"
}

# Espera o site VOLTAR A SERVIR, com paciencia.
#
# Depois de um `docker start`, o entrypoint reaplica permissoes na arvore inteira
# do codigo antes de subir o nginx — dezenas de segundos numa instalacao real. O
# `docker exec` responde muito antes disso, entao esperar por ele da falso
# negativo: a restauracao estava correta e o script dizia que o site nao subiu.
#
# (O `|| echo 000` que existia aqui grudava no valor de %{http_code} e imprimia
# "000000", escondendo que o problema era de espera, nao de codigo HTTP.)
wait_for_http() {
    local url code deadline
    url=$(moodle_php "-r 'define(\"CLI_SCRIPT\",1); require \"${MOODLE_CONTAINER_PATH}/config.php\"; echo \$CFG->wwwroot;'" 2>/dev/null | tail -1)
    [ -n "${url}" ] || { log "Nao consegui ler o wwwroot para conferir o site."; return 1; }
    deadline=$(( $(date +%s) + HTTP_WAIT ))
    while :; do
        code=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "${url}/login/index.php" 2>/dev/null) || code=""
        [ "${code}" = 200 ] && { log "HTTP ${url}/login/index.php -> 200"; return 0; }
        [ "$(date +%s)" -ge "${deadline}" ] && break
        sleep 5
    done
    log "HTTP ${url}/login/index.php -> ${code:-sem resposta} depois de ${HTTP_WAIT}s."
    return 1
}

# Numeros que provam que o dump nao veio truncado. Gravados no manifesto e
# conferidos depois pelo `verify`, no banco restaurado.
census() {
    local db="$1"
    psql_db "${db}" "SELECT (SELECT count(*) FROM information_schema.tables WHERE table_schema='public')
                          ||'|'|| (SELECT count(*) FROM ${DB_PREFIX}user)
                          ||'|'|| (SELECT count(*) FROM ${DB_PREFIX}course)
                          ||'|'|| (SELECT coalesce(max(value),'?') FROM ${DB_PREFIX}config WHERE name='version')"
}

newest_manifest() { ls -1t "${BACKUP_DIR}"/manifest-*.env 2>/dev/null | head -1; }

load_manifest() {
    local m="$1"
    [ -n "${m}" ] || fail "Informe o manifesto (ou use 'list' para ver os disponiveis)."
    [ -f "${m}" ] || fail "Manifesto nao encontrado: ${m}"
    # shellcheck disable=SC1090
    source "${m}"
    [ -n "${BK_STAMP:-}" ] || fail "Manifesto invalido (sem BK_STAMP): ${m}"
}

# --- Pre-voo -------------------------------------------------------------------
preflight() {
    step "Pre-voo"
    command -v rsync >/dev/null || fail "rsync nao encontrado no host."
    sudo -n true 2>/dev/null || fail "Este script precisa de sudo sem senha (le moodledata, que e do usuario do servidor web)."
    dc ps --status running --services 2>/dev/null | grep -qx "${DB_SERVICE}" \
        || fail "Servico '${DB_SERVICE}' nao esta rodando."
    dc exec -T "${DB_SERVICE}" pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null \
        || fail "Banco nao responde (pg_isready)."
    [ -d "${DATA_DIR}" ] || fail "moodledata nao encontrado em ${DATA_DIR}."
    [ -d "${CODE_DIR}" ] || fail "codigo nao encontrado em ${CODE_DIR}."

    mkdir -p "${BACKUP_DIR}/data"
    # O backup guarda o config.php (com a senha do banco) e todo dado de usuario.
    chmod 700 "${BACKUP_DIR}" 2>/dev/null || true

    local free_mb; free_mb=$(df -Pm "${BACKUP_DIR}" | awk 'NR==2{print $4}')
    [ "${free_mb}" -ge "${MIN_FREE_MB}" ] \
        || fail "Só ${free_mb} MB livres em ${BACKUP_DIR}; o minimo configurado e ${MIN_FREE_MB} MB."
    log "Disco livre: ${free_mb} MB. Banco: $(psql_db "${DB_NAME}" "SELECT pg_size_pretty(pg_database_size('${DB_NAME}'))")."
}

# --- Backup --------------------------------------------------------------------
do_run() {
    preflight

    local db_dump="${BACKUP_DIR}/db-${STAMP}.dump"
    local code_tar="${BACKUP_DIR}/code-${STAMP}.tar.gz"
    local data_snap="${BACKUP_DIR}/data/${STAMP}"
    local manifest="${BACKUP_DIR}/manifest-${STAMP}.env"
    local census_before; census_before=$(census "${DB_NAME}")

    # 1) BANCO PRIMEIRO. Ver "ORDEM, E POR QUE ELA IMPORTA" no cabecalho.
    step "Banco (pg_dump -Fc)"
    dc exec -T "${DB_SERVICE}" pg_dump -U "${DB_USER}" -Fc -Z 6 "${DB_NAME}" > "${db_dump}" \
        || { rm -f "${db_dump}"; fail "pg_dump falhou."; }
    chmod 600 "${db_dump}"
    log "Banco: $(human "${db_dump}") (${db_dump##*/})"

    # 2) moodledata incremental por hardlink contra o snapshot anterior.
    step "moodledata (rsync --link-dest)"
    local link_args=() previous
    previous=$(ls -1d "${BACKUP_DIR}"/data/*/ 2>/dev/null | sort | tail -1 || true)
    if [ -n "${previous}" ]; then
        link_args=(--link-dest="${previous%/}")
        log "Incremental contra $(basename "${previous%/}")."
    else
        log "Primeiro snapshot: copia completa."
    fi
    local excl=()
    for e in "${DATA_EXCLUDES[@]}"; do excl+=(--exclude="/${e}/"); done
    sudo -n rsync -a --delete "${link_args[@]}" "${excl[@]}" \
        "${DATA_DIR}/" "${data_snap}/" || fail "rsync do moodledata falhou."
    log "moodledata: $(human "${data_snap}") neste snapshot; $(human "${BACKUP_DIR}/data") somando todos (hardlink nao conta duas vezes)."

    # 3) Codigo (inclui config.php e os plugins, que o git do core nao guarda).
    step "Codigo (tar.gz, sem .git)"
    # shellcheck disable=SC2024
    sudo -n tar -C "${CODE_DIR}" --exclude=./.git -czf - . > "${code_tar}" \
        || { rm -f "${code_tar}"; fail "Backup do codigo falhou."; }
    chmod 600 "${code_tar}"
    log "Codigo: $(human "${code_tar}") (${code_tar##*/})"

    # 4) Manifesto.
    step "Manifesto"
    local release; release=$(grep -oP "\\\$release\s*=\s*'\K[^']+" "${CODE_DIR}/public/version.php" 2>/dev/null | head -1 || echo '?')
    cat > "${manifest}" <<EOF
# Backup ${STAMP} — restaure com: ./backup-moodle.sh restore ${manifest}
BK_STAMP=${STAMP}
BK_DAY=${DAYSTAMP}
BK_DOW=$(date '+%u')
BK_RELEASE='${release}'
BK_DB_NAME=${DB_NAME}
BK_DB_DUMP=${db_dump}
BK_CODE_TAR=${code_tar}
BK_DATA_SNAP=${data_snap}
# Censo do banco no momento do dump: tabelas|usuarios|cursos|version.
# O 'verify' restaura o dump e confere contra estes numeros.
BK_CENSUS='${census_before}'
EOF
    chmod 600 "${manifest}"
    log "Manifesto: ${manifest##*/}  (censo ${census_before})"

    do_prune
    copy_remote "${manifest}"

    step "Fim"
    summary
    log "Backup ${STAMP} concluido. Confira com: ${BASH_SOURCE[0]} verify ${manifest}"
}

# --- Copia fora do host ---------------------------------------------------------
copy_remote() {
    step "Copia para fora do host"
    if [ -z "${BACKUP_REMOTE}" ]; then
        warn "BACKUP_REMOTE nao configurado: o backup esta SO neste host. Backup no mesmo disco nao protege contra a falha mais comum, que e o disco. Configure BACKUP_REMOTE no .env (ex.: BACKUP_REMOTE=user@host:/backups/moodle)."
        return 0
    fi
    # shellcheck disable=SC2086
    if sudo -n rsync -a --delete ${BACKUP_REMOTE_OPTS} "${BACKUP_DIR}/" "${BACKUP_REMOTE%/}/"; then
        log "Enviado para ${BACKUP_REMOTE}."
    else
        warn "A copia para ${BACKUP_REMOTE} FALHOU. O backup local ficou de pe, mas fora do host nao ha copia desta execucao."
    fi
}

# --- Retencao -------------------------------------------------------------------
do_prune() {
    step "Retencao (${KEEP_DAILY} diarios + ${KEEP_WEEKLY} semanais)"
    local all keep=() m
    all=$(ls -1t "${BACKUP_DIR}"/manifest-*.env 2>/dev/null || true)
    [ -n "${all}" ] || { log "Nada a podar."; return 0; }

    # Os KEEP_DAILY mais recentes ficam, sempre.
    while IFS= read -r m; do keep+=("${m}"); done < <(echo "${all}" | head -n "${KEEP_DAILY}")

    # Alem deles, os KEEP_WEEKLY mais recentes tirados no dia da semana escolhido.
    local weekly=0
    while IFS= read -r m; do
        [ "${weekly}" -ge "${KEEP_WEEKLY}" ] && break
        local dow; dow=$(grep -oP '^BK_DOW=\K.*' "${m}" 2>/dev/null || echo 0)
        if [ "${dow}" = "${WEEKLY_DOW}" ] && ! printf '%s\n' "${keep[@]}" | grep -qxF "${m}"; then
            keep+=("${m}"); weekly=$(( weekly + 1 ))
        fi
    done < <(echo "${all}")

    local removed=0
    while IFS= read -r m; do
        printf '%s\n' "${keep[@]}" | grep -qxF "${m}" && continue
        # shellcheck disable=SC1090
        ( source "${m}"
          rm -f "${BK_DB_DUMP}" "${BK_CODE_TAR}"
          [ -n "${BK_DATA_SNAP:-}" ] && sudo -n rm -rf "${BK_DATA_SNAP}"
          rm -f "${m}" ) || warn "Falha ao remover o conjunto ${m##*/}"
        removed=$(( removed + 1 ))
        log "Removido: ${m##*/}"
    done < <(echo "${all}")
    log "Mantidos ${#keep[@]} conjunto(s); removidos ${removed}."
}

# --- Lista ----------------------------------------------------------------------
do_list() {
    local m found=0
    printf '%-18s %-10s %-9s %-9s %s\n' 'CARIMBO' 'RELEASE' 'BANCO' 'CODIGO' 'CENSO (tab|usr|cur|version)'
    while IFS= read -r m; do
        [ -f "${m}" ] || continue
        # shellcheck disable=SC1090
        ( source "${m}"
          printf '%-18s %-10s %-9s %-9s %s\n' "${BK_STAMP}" "${BK_RELEASE%% (*}" \
            "$(du -h "${BK_DB_DUMP}" 2>/dev/null | cut -f1 || echo '-')" \
            "$(du -h "${BK_CODE_TAR}" 2>/dev/null | cut -f1 || echo '-')" \
            "${BK_CENSUS:-?}" )
        found=1
    done < <(ls -1t "${BACKUP_DIR}"/manifest-*.env 2>/dev/null)
    [ "${found}" = 1 ] || echo "Nenhum backup em ${BACKUP_DIR}."
    [ -n "${BACKUP_REMOTE}" ] && echo "Copia fora do host: ${BACKUP_REMOTE}" || echo "Copia fora do host: NAO CONFIGURADA (BACKUP_REMOTE)"
}

# --- Verificacao ----------------------------------------------------------------
# Restaura o dump num banco descartavel e compara com o censo gravado no
# backup. Nao toca no banco em uso: da para rodar no cron, com o site no ar.
do_verify() {
    local m="${MANIFEST_IN}"
    [ -n "${m}" ] || m=$(newest_manifest)
    load_manifest "${m}"
    step "Verificando ${BK_STAMP}"

    [ -f "${BK_DB_DUMP}" ] || fail "Dump ausente: ${BK_DB_DUMP}"
    [ -d "${BK_DATA_SNAP}" ] || warn "Snapshot de moodledata ausente: ${BK_DATA_SNAP}"
    [ -f "${BK_CODE_TAR}" ] || warn "Tar do codigo ausente: ${BK_CODE_TAR}"

    local testdb="${DB_NAME}_verify_${STAMP//-/_}"
    psql_db postgres "CREATE DATABASE \"${testdb}\" TEMPLATE template0" >/dev/null \
        || fail "Nao consegui criar ${testdb} (o usuario do banco precisa de CREATEDB)."
    # A partir daqui, o banco de teste some aconteca o que acontecer.
    trap 'psql_db postgres "DROP DATABASE IF EXISTS \"'"${testdb}"'\"" >/dev/null 2>&1 || true' EXIT

    if ! dc exec -T "${DB_SERVICE}" pg_restore -U "${DB_USER}" -d "${testdb}" --no-owner --exit-on-error < "${BK_DB_DUMP}"; then
        fail "pg_restore falhou: este dump NAO restaura. Trate como backup perdido."
    fi

    local now; now=$(census "${testdb}")
    log "censo gravado no backup : ${BK_CENSUS}"
    log "censo do dump restaurado: ${now}"
    [ "${now}" = "${BK_CENSUS}" ] || fail "O dump restaurou, mas o censo NAO bate. Dump suspeito."

    # O tar precisa estar integro tambem — um .gz truncado so aparece ao ler.
    if [ -f "${BK_CODE_TAR}" ]; then
        gzip -t "${BK_CODE_TAR}" || fail "O tar.gz do codigo esta corrompido."
        tar -tzf "${BK_CODE_TAR}" ./public/version.php >/dev/null 2>&1 \
            || warn "version.php nao encontrado dentro do tar do codigo."
    fi
    # O filedir e o que sustenta todo anexo do site.
    if [ -d "${BK_DATA_SNAP}/filedir" ]; then
        log "moodledata: $(sudo -n find "${BK_DATA_SNAP}/filedir" -type f 2>/dev/null | wc -l) arquivo(s) no filedir."
    fi

    step "Fim"
    summary
    log "BACKUP ${BK_STAMP} VERIFICADO: o dump restaura e o conteudo bate."
}

# --- Restauracao ----------------------------------------------------------------
do_restore() {
    load_manifest "${MANIFEST_IN}"

    cat <<EOF

  RESTAURACAO — backup ${BK_STAMP} (release ${BK_RELEASE:-?})
    banco      : $([ "${RESTORE_DB}" = 1 ] && echo "SIM  <- ${BK_DB_DUMP##*/}" || echo nao)
    moodledata : $([ "${RESTORE_DATA}" = 1 ] && echo "SIM  <- ${BK_DATA_SNAP##*/}" || echo nao)
    codigo     : $([ "${RESTORE_CODE}" = 1 ] && echo "SIM  <- ${BK_CODE_TAR##*/}" || echo nao)

  Tudo o que entrou no site DEPOIS de ${BK_STAMP} se perde.
  O estado atual nao e apagado: fica guardado ao lado, com sufixo _pre_restore_.
  O site sai do ar durante a operacao.

EOF
    read -r -p "  Digite RESTAURAR para seguir: " confirm
    [ "${confirm}" = "RESTAURAR" ] || fail "Cancelado."

    preflight
    local kept_db="" kept_data=""

    step "Parando o site"
    dc stop "${MOODLE_SERVICE}" >/dev/null || fail "Nao consegui parar ${MOODLE_SERVICE}."

    if [ "${RESTORE_DB}" = 1 ]; then
        step "Banco (restaura num banco novo e troca os nomes no fim)"
        local newdb="${DB_NAME}_rs_${STAMP//-/_}" meta enc coll ctype owner
        kept_db="${DB_NAME}_pre_restore_${STAMP//-/_}"
        meta=$(psql_db postgres "select pg_encoding_to_char(encoding)||'|'||datcollate||'|'||datctype||'|'||pg_get_userbyid(datdba) from pg_database where datname='${DB_NAME}'")
        IFS='|' read -r enc coll ctype owner <<< "${meta}"
        [ -n "${owner}" ] || fail "Nao consegui ler o banco ${DB_NAME}."
        psql_db postgres "CREATE DATABASE \"${newdb}\" WITH TEMPLATE template0 ENCODING '${enc}' LC_COLLATE '${coll}' LC_CTYPE '${ctype}' OWNER \"${owner}\"" >/dev/null \
            || fail "Nao consegui criar ${newdb} (o usuario do banco precisa de CREATEDB)."
        if ! dc exec -T "${DB_SERVICE}" pg_restore -U "${DB_USER}" -d "${newdb}" --no-owner --exit-on-error < "${BK_DB_DUMP}"; then
            psql_db postgres "DROP DATABASE IF EXISTS \"${newdb}\"" >/dev/null || true
            dc start "${MOODLE_SERVICE}" >/dev/null || true
            fail "pg_restore falhou. O banco em uso NAO foi alterado e o site voltou."
        fi
        psql_db postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('${DB_NAME}','${newdb}') AND pid <> pg_backend_pid()" >/dev/null || true
        psql_db postgres "ALTER DATABASE \"${DB_NAME}\" RENAME TO \"${kept_db}\"" >/dev/null || fail "Nao consegui renomear o banco atual."
        psql_db postgres "ALTER DATABASE \"${newdb}\" RENAME TO \"${DB_NAME}\"" >/dev/null \
            || { psql_db postgres "ALTER DATABASE \"${kept_db}\" RENAME TO \"${DB_NAME}\"" >/dev/null; fail "Troca de nomes falhou; banco original devolvido."; }
        log "Banco restaurado. O de antes ficou como ${kept_db}."
    fi

    if [ "${RESTORE_DATA}" = 1 ]; then
        step "moodledata (move o atual para o lado e copia o snapshot)"
        [ -d "${BK_DATA_SNAP}" ] || fail "Snapshot ausente: ${BK_DATA_SNAP}"
        kept_data="${DATA_DIR}_pre_restore_${STAMP}"
        sudo -n mv "${DATA_DIR}" "${kept_data}" || fail "Nao consegui mover o moodledata atual."
        sudo -n mkdir -p "${DATA_DIR}"
        sudo -n chown --reference="${kept_data}" "${DATA_DIR}"
        sudo -n chmod --reference="${kept_data}" "${DATA_DIR}"
        sudo -n rsync -a "${BK_DATA_SNAP}/" "${DATA_DIR}/" || fail "rsync do snapshot falhou. O moodledata anterior esta em ${kept_data}."
        # Os diretorios excluidos do backup sao regeneraveis, mas precisam existir.
        for e in "${DATA_EXCLUDES[@]}"; do
            sudo -n mkdir -p "${DATA_DIR}/${e}"
            sudo -n chown --reference="${DATA_DIR}" "${DATA_DIR}/${e}"
        done
        log "moodledata restaurado. O de antes ficou em ${kept_data}."
    fi

    if [ "${RESTORE_CODE}" = 1 ]; then
        step "Codigo"
        [ -f "${BK_CODE_TAR}" ] || fail "Tar do codigo ausente: ${BK_CODE_TAR}"
        sudo -n tar -C "${CODE_DIR}" -xzf "${BK_CODE_TAR}" || fail "Restauracao do codigo falhou."
        log "Codigo restaurado de ${BK_CODE_TAR##*/}."
    fi

    step "Subindo o site"
    dc start "${MOODLE_SERVICE}" >/dev/null || fail "Nao consegui subir ${MOODLE_SERVICE}."
    local waited=0
    until dc exec -T "${MOODLE_SERVICE}" true 2>/dev/null; do
        sleep 2; waited=$(( waited + 2 ))
        [ "${waited}" -ge 120 ] && fail "O container nao ficou pronto em 120s."
    done
    wait_for_http || warn "A pagina de login nao respondeu 200 em ${HTTP_WAIT}s. Confira antes de apagar o que ficou guardado."
    fix_cache_owner || true
    moodle_cli "purge_caches.php" >/dev/null || warn "purge_caches falhou."
    moodle_cli "upgrade.php --is-pending" >/dev/null 2>&1 \
        || warn "O Moodle pede upgrade: o codigo e o banco restaurados nao batem. Rode admin/cli/upgrade.php."

    step "Fim"
    summary
    log "Restauracao do backup ${BK_STAMP} concluida."
    log "Depois de conferir o site, apague o que ficou guardado:"
    [ -n "${kept_db}" ]   && log "  ${COMPOSE} exec ${DB_SERVICE} dropdb -U ${DB_USER} ${kept_db}"
    [ -n "${kept_data}" ] && log "  sudo rm -rf ${kept_data}"
}

# --- Principal -----------------------------------------------------------------
case "${CMD}" in
    run)     do_run ;;
    list)    do_list ;;
    verify)  do_verify ;;
    restore) do_restore ;;
    prune)   do_prune; summary ;;
esac
