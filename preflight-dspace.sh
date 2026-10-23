#!/usr/bin/env bash
set -Eeuo pipefail

# Preflight for the native DSpace installer. Checks the host and writes a
# shell-compatible .env file beside this script; it does not install packages.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="$SCRIPT_DIR/.env"
die() { echo "ERROR: $*" >&2; exit 1; }
ask() { local name=$1 prompt=$2 default=$3 value; read -r -p "$prompt [$default]: " value; printf -v "$name" '%s' "${value:-$default}"; }
ask_secret() {
  local name=$1 value confirmation
  while :; do
    read -r -s -p 'Contraseña PostgreSQL (mínimo 16 caracteres): ' value; echo
    read -r -s -p 'Confirma la contraseña: ' confirmation; echo
    ((${#value} >= 16)) || { echo 'Usa al menos 16 caracteres.'; continue; }
    [[ $value == "$confirmation" ]] || { echo 'Las contraseñas no coinciden.'; continue; }
    printf -v "$name" '%s' "$value"; break
  done
}
valid_id() { [[ $2 =~ ^[a-zA-Z0-9_]+$ ]]; }
valid_path() { [[ $2 =~ ^/[A-Za-z0-9_./-]+$ && $2 != / ]]; }
valid_port() { [[ $2 =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= 65535 )); }
quote_env() { printf '%q' "$2"; }

echo 'Preflight de instalación nativa DSpace 10 (Ubuntu 22.04/24.04).'
[[ -r /etc/os-release ]] || die 'No se pudo identificar el sistema operativo.'
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == ubuntu && ( ${VERSION_ID:-} == 22.04 || ${VERSION_ID:-} == 24.04 ) ]] || die "Se requiere Ubuntu 22.04 o 24.04; encontrado: ${PRETTY_NAME:-desconocido}."
command -v apt-get >/dev/null || die 'No se encontró apt-get.'
command -v curl >/dev/null || die 'Instala curl y vuelve a ejecutar este preflight.'

mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
disk_gb=$(df -BG --output=avail "$SCRIPT_DIR" | tail -1 | tr -dc '0-9')
cpu_count=$(getconf _NPROCESSORS_ONLN)
echo "Sistema: $PRETTY_NAME | CPU: $cpu_count | RAM: ${mem_mb} MB | espacio libre: ${disk_gb} GB"
(( mem_mb >= 4096 )) || echo 'AVISO: se recomiendan al menos 4 GB de RAM para compilar DSpace.'
(( disk_gb >= 25 )) || echo 'AVISO: se recomiendan al menos 25 GB libres para fuentes, compilación y datos.'
curl -fsSI --max-time 10 https://github.com/ >/dev/null || die 'No hay conexión HTTPS a GitHub; revisa DNS, red y proxy.'
curl -fsSI --max-time 10 https://archive.apache.org/ >/dev/null || die 'No hay conexión HTTPS al archivo de Apache, requerido para Solr.'

echo
echo 'Ingresa la configuración. Pulsa Enter para aceptar el valor sugerido.'
ask OS_USER 'Usuario de servicio' 'dspace'
ask OS_GROUP 'Grupo de servicio' 'dspace'
ask DSPACE_DIR 'Directorio de datos/instalación' '/dspace'
ask SOURCE_DIR 'Directorio del código fuente backend' '/opt/dspace-src'
ask UI_SOURCE_DIR 'Directorio del código fuente UI' '/opt/dspace-angular'
ask UI_DEPLOY_DIR 'Directorio de despliegue UI' '/opt/dspace-ui'
ask SOLR_BASE_DIR 'Directorio base de Solr' '/opt'
ask DB_NAME 'Nombre de la base PostgreSQL' 'dspace'
ask DB_USER 'Usuario PostgreSQL' 'dspace'
ask HOSTNAME_PUBLIC 'Dominio público o IP (localhost para prueba)' 'localhost'
ask DSPACE_NAME 'Nombre visible del repositorio' 'DSpace Repository'
ask UI_PORT 'Puerto interno UI' '4000'
ask BACKEND_PORT 'Puerto interno backend' '8080'
ask DSPACE_VERSION 'Tag DSpace' 'dspace-10.0'
ask SOLR_VERSION 'Versión Solr 9.x' '9.8.1'
ask DB_PASS 'Contraseña PostgreSQL (deja vacío para generar una)' ''
if [[ -z $DB_PASS ]]; then
  DB_PASS=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
  echo 'Se generó una contraseña aleatoria; consérvala en el archivo .env.'
else
  [[ ${#DB_PASS} -ge 16 ]] || die 'La contraseña PostgreSQL debe tener al menos 16 caracteres.'
fi

[[ $OS_USER =~ ^[a-z_][a-z0-9_-]*$ && $OS_GROUP =~ ^[a-z_][a-z0-9_-]*$ ]] || die 'Usuario o grupo inválido.'
for pair in "DSPACE_DIR:$DSPACE_DIR" "SOURCE_DIR:$SOURCE_DIR" "UI_SOURCE_DIR:$UI_SOURCE_DIR" "UI_DEPLOY_DIR:$UI_DEPLOY_DIR" "SOLR_BASE_DIR:$SOLR_BASE_DIR"; do
  key=${pair%%:*}; value=${pair#*:}; valid_path "$key" "$value" || die "Ruta inválida en $key. Usa una ruta absoluta sin espacios."
done
valid_id DB_NAME "$DB_NAME" && valid_id DB_USER "$DB_USER" || die 'DB_NAME y DB_USER solo admiten letras, números y guion bajo.'
[[ $HOSTNAME_PUBLIC =~ ^[A-Za-z0-9.-]+$ ]] || die 'Dominio/IP inválido; no incluyas esquema ni ruta.'
name_re='^[A-Za-z0-9_. -]+$'
[[ $DSPACE_NAME =~ $name_re ]] || die 'Nombre visible: usa letras, números, espacios, punto, guion o guion bajo.'
valid_port UI_PORT "$UI_PORT" && valid_port BACKEND_PORT "$BACKEND_PORT" || die 'Los puertos deben estar entre 1 y 65535.'
[[ $UI_PORT != "$BACKEND_PORT" ]] || die 'UI y backend deben usar puertos distintos.'
[[ $DSPACE_VERSION =~ ^dspace-[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die 'Tag DSpace inválido; se espera, por ejemplo, dspace-10.0.'
[[ $SOLR_VERSION =~ ^9\.[0-9]+(\.[0-9]+)?$ ]] || die 'Se requiere una versión Solr 9.x.'

if [[ $HOSTNAME_PUBLIC != localhost ]] && ! getent ahosts "$HOSTNAME_PUBLIC" >/dev/null; then
  echo "AVISO: $HOSTNAME_PUBLIC todavía no resuelve por DNS desde este servidor."
fi
if command -v ss >/dev/null; then
  for port in "$UI_PORT" "$BACKEND_PORT" 8983; do
    if ss -ltn "sport = :$port" | tail -n +2 | grep -q .; then echo "AVISO: el puerto $port ya está en uso."; fi
  done
fi

umask 077
{
  for name in OS_USER OS_GROUP DSPACE_DIR SOURCE_DIR UI_SOURCE_DIR UI_DEPLOY_DIR SOLR_BASE_DIR DB_NAME DB_USER DB_PASS HOSTNAME_PUBLIC DSPACE_NAME UI_PORT BACKEND_PORT DSPACE_VERSION SOLR_VERSION; do
    printf '%s=%s\n' "$name" "$(quote_env "$name" "${!name}")"
  done
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo
echo "Preflight completado. Configuración guardada en $ENV_FILE (permisos 600)."
echo 'El preflight no instaló paquetes ni cambió servicios.'
echo 'Cuando estés listo, ejecuta: sudo ./install-dspace.sh'
