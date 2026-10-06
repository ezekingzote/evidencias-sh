#!/bin/bash
set -euo pipefail

BACKUP_BASE="/home/ezequiel/backups/sistema-evidencias"
PROJECT_NAME="sistema-evidencias"
GIT_REPO="git@github.com:ezekingzote/sistema-evidencias.git"
BRANCH="main"

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; NC="\033[0m"
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] $1${NC}"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] $1${NC}"; }

detect_os_and_path() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-desconocido}"
        OS_LIKE="${ID_LIKE:-}"
    else
        OS_ID="desconocido"; OS_LIKE=""
    fi

    case "$OS_ID" in
        debian|ubuntu|linuxmint|pop)
            PROJECT_DIR="/var/www/sistema-evidencias" ;;
        manjaro|arch|endeavouros)
            PROJECT_DIR="/srv/http/sistema-evidencias" ;;
        *)
            if [[ "$OS_LIKE" == *"debian"* || "$OS_LIKE" == *"ubuntu"* ]]; then
                PROJECT_DIR="/var/www/sistema-evidencias"
            elif [[ "$OS_LIKE" == *"arch"* ]]; then
                PROJECT_DIR="/srv/http/sistema-evidencias"
            else
                err "SO no reconocido ($OS_ID)."
                exit 1
            fi ;;
    esac

    log "SO detectado: $OS_ID"
    log "Ruta del proyecto: $PROJECT_DIR"
}

detect_os_and_path

log "Solicitando permisos sudo..."
sudo -v

if [ ! -d "$PROJECT_DIR" ]; then
    err "No existe el directorio del proyecto: $PROJECT_DIR"; exit 1
fi
if [ ! -d "$PROJECT_DIR/.git" ]; then
    err "El directorio $PROJECT_DIR no es un repositorio Git"; exit 1
fi

if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    warn "SSH_AUTH_SOCK no esta definido. Asegurate de tener ssh-agent corriendo y la llave cargada:"
    warn "  eval \$(ssh-agent -s) && ssh-add ~/.ssh/id_ed25519"
    exit 1
fi

cd "$PROJECT_DIR"

log "Configurando remote origin a SSH..."
sudo git remote set-url origin "$GIT_REPO"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="$BACKUP_BASE/$PROJECT_NAME/$TIMESTAMP"

log "Creando respaldo en: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

if sudo test -f "$PROJECT_DIR/.env"; then
    sudo cp "$PROJECT_DIR/.env" "$BACKUP_DIR/.env"
    sudo chown "$(id -u):$(id -g)" "$BACKUP_DIR/.env"
    log "  -> .env respaldado"
else
    warn "  -> No se encontro .env"
fi

for f in .env.local .env.production docker-compose.yml; do
    if sudo test -f "$PROJECT_DIR/$f"; then
        sudo cp "$PROJECT_DIR/$f" "$BACKUP_DIR/$f"
        sudo chown "$(id -u):$(id -g)" "$BACKUP_DIR/$f"
        log "  -> $f respaldado"
    fi
done

CURRENT_COMMIT=$(sudo git rev-parse HEAD)
echo "$CURRENT_COMMIT" > "$BACKUP_DIR/commit_anterior.txt"
log "  -> Commit anterior: $CURRENT_COMMIT"

log "Empaquetando codigo actual..."
sudo tar --exclude='./vendor' \
    --exclude='./node_modules' \
    --exclude='./.git' \
    --exclude='./storage/logs' \
    -czf "$BACKUP_DIR/codigo_$TIMESTAMP.tar.gz" \
    -C "$PROJECT_DIR" . 2>/dev/null || warn "  -> Respaldo de codigo parcial"
sudo chown "$(id -u):$(id -g)" "$BACKUP_DIR/codigo_$TIMESTAMP.tar.gz"

log "Verificando acceso SSH a GitHub..."
sudo -E SSH_AUTH_SOCK="$SSH_AUTH_SOCK" ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -q "successfully authenticated" \
    && log "  -> SSH OK" \
    || warn "  -> No se pudo confirmar autenticacion SSH (puede continuar igual)"

log "Fetch origin..."
sudo -E SSH_AUTH_SOCK="$SSH_AUTH_SOCK" git fetch origin

log "Pull origin $BRANCH..."
sudo -E SSH_AUTH_SOCK="$SSH_AUTH_SOCK" git pull origin "$BRANCH"

if [ -f "$BACKUP_DIR/.env" ]; then
    log "Restaurando .env..."
    sudo cp "$BACKUP_DIR/.env" "$PROJECT_DIR/.env"
fi

log "Deploy completado"
log "Respaldo en: $BACKUP_DIR"
echo ""
echo "Si algo falla, para revertir:"
echo "  cd $PROJECT_DIR"
echo "  sudo git reset --hard $CURRENT_COMMIT"
echo "  sudo cp $BACKUP_DIR/.env .env"
echo "  composer install"
echo ""
echo "O restaurando desde el tar:"
echo "  sudo tar -xzf $BACKUP_DIR/codigo_$TIMESTAMP.tar.gz -C $PROJECT_DIR"
echo "  composer install"
