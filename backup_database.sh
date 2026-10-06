#!/usr/bin/env bash
# =============================================================================
#  Backup de Base de Datos (Manjaro / Debian)
#  Uso:
#     ./backup_database.sh              -> ejecuta el respaldo una vez
#     ./backup_database.sh --install    -> instala el timer/cron
#     ./backup_database.sh --uninstall  -> elimina el timer/cron
#     ./backup_database.sh --status     -> muestra estado y últimos dumps
# =============================================================================

# -------------------------------
#  CONFIGURACIÓN (EDITAR AQUÍ)
# -------------------------------

# Nombre(s) de base(s) de datos a respaldar
DB_NAMES=("evidencias")

# Motor: mysql | mariadb | postgresql
DB_ENGINE="mysql"

# Conexión
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_USER="ezequiel"

# Password:
#   - Recomendado: déjala vacía ("") y usa ~/.my.cnf
#   - Si la pones aquí, queda en texto plano
DB_PASSWORD="ezequiel2002"

# Carpeta raíz de respaldos
BACKUP_ROOT="$HOME/backups/sistema-evidencias"

# Subcarpeta para los dumps
BACKUP_DIR="$BACKUP_ROOT/database"

# Prefijo
BACKUP_PREFIX="db_backup"

# Cuántos dumps conservar por BD (0 = infinito)
KEEP_BACKUPS=7

# Ejecución automática
AUTO_EXECUTE=true

# Intervalo (systemd / cron)
INTERVAL_SYSTEMD="daily"
INTERVAL_CRON="0 4 * * *"
SYSTEMD_ON_CALENDAR=""

# Nombre del servicio (distinto al de storage)
SERVICE_NAME="laravel-database-backup"

# Log
LOG_FILE="$BACKUP_ROOT/backup_database.log"

# -------------------------------
#  ENTORNO
# -------------------------------
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    if [[ -n "${LOG_FILE:-}" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        echo "$msg" >> "$LOG_FILE"
    fi
}

die() { log "ERROR: $*"; exit 1; }

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

# -------------------------------
#  DUMP
# -------------------------------
dump_mysql_like() {
    local db="$1"
    local out_file="$2"
    local client="$3"

    command -v "$client" >/dev/null || die "$client no está instalado"

    local args=(
        --host="$DB_HOST"
        --port="$DB_PORT"
        --user="$DB_USER"
        --single-transaction
        --routines
        --triggers
        --events
    )

    if [[ -n "$DB_PASSWORD" ]]; then
        MYSQL_PWD="$DB_PASSWORD" "$client" "${args[@]}" "$db" | gzip -9 > "$out_file"
    else
        "$client" "${args[@]}" "$db" | gzip -9 > "$out_file"
    fi
}

dump_postgres() {
    local db="$1"
    local out_file="$2"

    command -v pg_dump >/dev/null || die "pg_dump no está instalado"

    if [[ -n "$DB_PASSWORD" ]]; then
        PGPASSWORD="$DB_PASSWORD" pg_dump \
            -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
            -F p "$db" | gzip -9 > "$out_file"
    else
        pg_dump \
            -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
            -F p "$db" | gzip -9 > "$out_file"
    fi
}

do_backup() {
    mkdir -p "$BACKUP_DIR"

    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"

    local db
    for db in "${DB_NAMES[@]}"; do
        local out_file="$BACKUP_DIR/${BACKUP_PREFIX}_${db}_${timestamp}.sql.gz"
        log "Respaldando BD '$db' ($DB_ENGINE) -> $out_file"

        case "$DB_ENGINE" in
            mysql)
                if command -v mysqldump >/dev/null; then
                    dump_mysql_like "$db" "$out_file" "mysqldump"
                else
                    dump_mysql_like "$db" "$out_file" "mariadb-dump"
                fi
                ;;
            mariadb)
                if command -v mariadb-dump >/dev/null; then
                    dump_mysql_like "$db" "$out_file" "mariadb-dump"
                else
                    dump_mysql_like "$db" "$out_file" "mysqldump"
                fi
                ;;
            postgresql|postgres)
                dump_postgres "$db" "$out_file"
                ;;
            *)
                die "DB_ENGINE no soportado: $DB_ENGINE"
                ;;
        esac

        [[ -s "$out_file" ]] || die "El dump quedó vacío: $out_file"
        log "Dump creado: $(du -h "$out_file" | cut -f1)"

        if [[ "$KEEP_BACKUPS" -gt 0 ]]; then
            ls -1t "$BACKUP_DIR"/${BACKUP_PREFIX}_${db}_* 2>/dev/null \
                | tail -n +$((KEEP_BACKUPS + 1)) \
                | while read -r old; do
                    log "Eliminando dump antiguo: $old"
                    rm -f -- "$old"
                done
        fi
    done

    log "Respaldo de base(s) de datos finalizado."
}

# -------------------------------
#  INSTALACIÓN AUTOMÁTICA
# -------------------------------
install_systemd() {
    local user_dir="$HOME/.config/systemd/user"
    mkdir -p "$user_dir"

    cat > "$user_dir/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Backup de Base de Datos Laravel

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH}
EOF

    local on_calendar
    if [[ -n "$SYSTEMD_ON_CALENDAR" ]]; then
        on_calendar="$SYSTEMD_ON_CALENDAR"
    else
        on_calendar="$INTERVAL_SYSTEMD"
    fi

    cat > "$user_dir/${SERVICE_NAME}.timer" <<EOF
[Unit]
Description=Timer para backup de Base de Datos

[Timer]
OnCalendar=${on_calendar}
Persistent=true
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now "${SERVICE_NAME}.timer"
    log "Timer systemd instalado y activado (${on_calendar})."
}

install_cron() {
    command -v crontab >/dev/null || die "crontab no está instalado"
    local line="${INTERVAL_CRON} ${SCRIPT_PATH} >> ${LOG_FILE:-/dev/null} 2>&1"
    ( crontab -l 2>/dev/null | grep -v -F "$SCRIPT_PATH" ; echo "$line" ) | crontab -
    log "Entrada cron instalada: $line"
}

install_auto() {
    [[ "$AUTO_EXECUTE" == "true" ]] || { log "AUTO_EXECUTE=false, no se instala nada."; return; }

    if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
        install_systemd
    else
        log "systemd --user no disponible, usando cron."
        install_cron
    fi
}

uninstall_auto() {
    if systemctl --user list-unit-files 2>/dev/null | grep -q "${SERVICE_NAME}.timer"; then
        systemctl --user disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/${SERVICE_NAME}.service" \
              "$HOME/.config/systemd/user/${SERVICE_NAME}.timer"
        systemctl --user daemon-reload
        log "Timer systemd eliminado."
    fi
    if command -v crontab >/dev/null; then
        crontab -l 2>/dev/null | grep -v -F "$SCRIPT_PATH" | crontab - || true
        log "Entrada cron eliminada (si existía)."
    fi
}

status_auto() {
    echo "== Estado del backup de BD =="
    if systemctl --user list-timers 2>/dev/null | grep -q "$SERVICE_NAME"; then
        systemctl --user status "${SERVICE_NAME}.timer" --no-pager || true
    fi
    if command -v crontab >/dev/null; then
        echo "-- Cron --"
        crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH" || echo "(sin entrada cron)"
    fi
    echo "-- Últimos dumps en $BACKUP_DIR --"
    ls -lh "$BACKUP_DIR" 2>/dev/null || echo "(sin dumps aún)"
}

# -------------------------------
#  MAIN
# -------------------------------
main() {
    local distro
    distro="$(detect_distro)"
    log "Distro detectada: $distro"

    case "${1:-}" in
        --install)   install_auto ;;
        --uninstall) uninstall_auto ;;
        --status)    status_auto ;;
        ""|--run)    do_backup ;;
        *)           echo "Uso: $0 [--install|--uninstall|--status|--run]"; exit 1 ;;
    esac
}

main "$@"
