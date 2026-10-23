#!/usr/bin/env bash
set -Eeuo pipefail

# Native, single-host DSpace 10 installer for Ubuntu 22.04/24.04.
# Safe to rerun: packages, service accounts and directories are reused; the
# DSpace database and repository are never dropped or overwritten automatically.

[[ $EUID -eq 0 ]] || { echo "Ejecuta con sudo: sudo $0" >&2; exit 1; }
command -v apt-get >/dev/null || { echo "Este instalador requiere Ubuntu/Debian con apt." >&2; exit 1; }

as_dspace() { runuser -u "$OS_USER" -- "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="$SCRIPT_DIR/.env"
[[ -f $ENV_FILE ]] || die "No existe $ENV_FILE. Primero ejecuta ./prerequisitos-dspace.sh."
[[ $(stat -c '%a' "$ENV_FILE") == 600 ]] || die "Protege $ENV_FILE con chmod 600 antes de continuar."
# shellcheck disable=SC1090
source "$ENV_FILE"
for required in OS_USER OS_GROUP DSPACE_DIR SOURCE_DIR UI_SOURCE_DIR UI_DEPLOY_DIR SOLR_BASE_DIR DB_NAME DB_USER DB_PASS HOSTNAME_PUBLIC DSPACE_NAME UI_PORT BACKEND_PORT DSPACE_VERSION SOLR_VERSION; do
  [[ -n ${!required:-} ]] || die "Falta $required en $ENV_FILE. Regenera la configuración con ./prerequisitos-dspace.sh."
done
echo "Instalación nativa de DSpace 10 (Ubuntu 22.04/24.04) para $HOSTNAME_PUBLIC."
SOLR_DIR="$SOLR_BASE_DIR/solr"

[[ $DSPACE_DIR = /* && $SOURCE_DIR = /* && $UI_SOURCE_DIR = /* && $UI_DEPLOY_DIR = /* && $SOLR_BASE_DIR = /* && $SOLR_BASE_DIR != / ]] || die "Todos los directorios deben ser rutas absolutas (la base de Solr no puede ser /)."
[[ $DSPACE_DIR$SOURCE_DIR$UI_SOURCE_DIR$UI_DEPLOY_DIR$SOLR_BASE_DIR =~ ^/[A-Za-z0-9_./-]+$ ]] || die "Las rutas solo pueden contener letras, números, punto, guion, guion bajo y slash."
[[ $HOSTNAME_PUBLIC =~ ^[A-Za-z0-9.-]+$ ]] || die "Host público inválido; usa un nombre DNS o localhost, sin esquema ni ruta."
[[ $OS_USER =~ ^[a-z_][a-z0-9_-]*$ && $OS_GROUP =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Usuario/grupo inválido."
[[ $DB_NAME =~ ^[a-zA-Z0-9_]+$ && $DB_USER =~ ^[a-zA-Z0-9_]+$ ]] || die "Nombre de base/usuario inválido."
[[ $DSPACE_VERSION =~ ^dspace-[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Tag esperado: dspace-10.0."
[[ $SOLR_VERSION =~ ^9\.[0-9]+(\.[0-9]+)?$ ]] || die "Se requiere Solr 9.x."

if ! getent group "$OS_GROUP" >/dev/null; then groupadd --system "$OS_GROUP"; fi
if ! id "$OS_USER" >/dev/null 2>&1; then useradd --system --gid "$OS_GROUP" --home-dir "$DSPACE_DIR" --shell /usr/sbin/nologin "$OS_USER"; fi
usermod -g "$OS_GROUP" -d "$DSPACE_DIR" -s /usr/sbin/nologin "$OS_USER"
install -d -o "$OS_USER" -g "$OS_GROUP" -m 0750 "$DSPACE_DIR" "$SOURCE_DIR" "$UI_SOURCE_DIR" "$UI_DEPLOY_DIR"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openjdk-21-jdk maven ant git curl wget ca-certificates gnupg unzip build-essential python3 postgresql postgresql-contrib nginx
JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")
cat >/etc/profile.d/dspace-java.sh <<EOF
export JAVA_HOME=$JAVA_HOME
export PATH=\$JAVA_HOME/bin:\$PATH
EOF

# Install a supported Node LTS via the NodeSource 22.x repository.
if ! command -v node >/dev/null || ! node -e 'process.exit(Number(process.versions.node.split(".")[0])===22?0:1)'; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
command -v pm2 >/dev/null || npm install --global pm2

systemctl enable --now postgresql
# psql does not interpolate variables in -c SQL; feed SQL through stdin.
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
  runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -v dbuser="$DB_USER" -v dbpass="$DB_PASS" <<'SQL'
CREATE ROLE :"dbuser" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'dbpass';
SQL
else
  runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -v dbuser="$DB_USER" -v dbpass="$DB_PASS" <<'SQL'
ALTER ROLE :"dbuser" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'dbpass';
SQL
fi
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
  runuser -u postgres -- createdb --owner="$DB_USER" --encoding=UTF8 "$DB_NAME"
fi

# Solr runs as its own unprivileged account and only listens on loopback.
getent group solr >/dev/null || groupadd --system solr
id solr >/dev/null 2>&1 || useradd --system --gid solr --home-dir /var/solr --shell /usr/sbin/nologin solr
if [[ ! -x "$SOLR_DIR/bin/solr" ]]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  curl -fL "https://archive.apache.org/dist/solr/solr/$SOLR_VERSION/solr-$SOLR_VERSION.tgz" -o "$tmp/solr.tgz"
  tar -xzf "$tmp/solr.tgz" -C "$tmp"
  "$tmp/solr-$SOLR_VERSION/bin/install_solr_service.sh" "$tmp/solr-$SOLR_VERSION.tgz" -n -i "$SOLR_BASE_DIR" -d /var/solr -u solr -s solr -p 8983
fi
install -d -o solr -g solr -m 0750 /var/solr/data/configsets
if [[ -f /etc/default/solr.in.sh ]]; then
  grep -q '^SOLR_OPTS=' /etc/default/solr.in.sh && sed -i 's|^SOLR_OPTS=.*|SOLR_OPTS="-Dsolr.config.lib.enabled=true"|' /etc/default/solr.in.sh || echo 'SOLR_OPTS="-Dsolr.config.lib.enabled=true"' >>/etc/default/solr.in.sh
fi
systemctl enable --now solr

if [[ ! -d "$SOURCE_DIR/.git" ]]; then git clone --branch "$DSPACE_VERSION" --depth 1 https://github.com/DSpace/DSpace.git "$SOURCE_DIR"; fi
if [[ ! -d "$UI_SOURCE_DIR/.git" ]]; then git clone --branch "$DSPACE_VERSION" --depth 1 https://github.com/DSpace/dspace-angular.git "$UI_SOURCE_DIR"; fi
chown -R "$OS_USER:$OS_GROUP" "$SOURCE_DIR" "$UI_SOURCE_DIR"

LOCAL_CFG="$SOURCE_DIR/dspace/config/local.cfg"
if [[ ! -f $LOCAL_CFG ]]; then
  cp "$SOURCE_DIR/dspace/config/local.cfg.EXAMPLE" "$LOCAL_CFG"
fi
cat >"$SOURCE_DIR/dspace/config/local.cfg" <<EOF
dspace.dir = $DSPACE_DIR
dspace.server.url = http://$HOSTNAME_PUBLIC:$BACKEND_PORT/server
dspace.ui.url = http://$HOSTNAME_PUBLIC:$UI_PORT
dspace.name = $DSPACE_NAME
solr.server = http://localhost:8983/solr
db.url = jdbc:postgresql://localhost:5432/$DB_NAME
db.username = $DB_USER
db.password = $DB_PASS
db.schema = public
EOF
chown "$OS_USER:$OS_GROUP" "$LOCAL_CFG"; chmod 0640 "$LOCAL_CFG"

if [[ ! -x "$DSPACE_DIR/bin/dspace" ]]; then
  as_dspace bash -lc "cd '$SOURCE_DIR' && mvn -U -DskipTests package"
  as_dspace bash -lc "cd '$SOURCE_DIR/dspace/target/dspace-installer' && ant fresh_install"
fi
chown -R "$OS_USER:$OS_GROUP" "$DSPACE_DIR"
"$DSPACE_DIR/bin/dspace" database migrate

# Install DSpace's six Solr configsets; create missing cores idempotently.
cp -a "$DSPACE_DIR/solr/." /var/solr/data/configsets/
chown -R solr:solr /var/solr/data/configsets
systemctl restart solr
for configset in /var/solr/data/configsets/*; do
  [[ -d $configset ]] || continue
  core=${configset##*/}
  curl -fsS "http://127.0.0.1:8983/solr/admin/cores?action=STATUS&core=$core" | grep -q '"name"' || \
    curl -fsS -G http://127.0.0.1:8983/solr/admin/cores --data-urlencode action=CREATE --data-urlencode "name=$core" --data-urlencode "configSet=$core" >/dev/null
done

install -d -o "$OS_USER" -g "$OS_GROUP" "$UI_DEPLOY_DIR/config"
chown -R "$OS_USER:$OS_GROUP" "$UI_SOURCE_DIR" "$UI_DEPLOY_DIR"
as_dspace bash -lc "cd '$UI_SOURCE_DIR' && npm ci && npm run build:prod"
rm -rf "$UI_DEPLOY_DIR/dist"
cp -a "$UI_SOURCE_DIR/dist" "$UI_DEPLOY_DIR/dist"
cat >"$UI_DEPLOY_DIR/ecosystem.config.cjs" <<EOF
module.exports = { apps: [{ name: 'dspace-ui', cwd: '$UI_DEPLOY_DIR', script: 'dist/server/main.js', instances: 1, exec_mode: 'fork', env: { NODE_ENV: 'production', DSPACE_UI_SSL: 'false', DSPACE_UI_HOST: '127.0.0.1', DSPACE_UI_PORT: '$UI_PORT', DSPACE_UI_BASEURL: 'http://$HOSTNAME_PUBLIC:$UI_PORT', DSPACE_REST_SSL: 'false', DSPACE_REST_HOST: '$HOSTNAME_PUBLIC', DSPACE_REST_PORT: '$BACKEND_PORT', DSPACE_REST_NAMESPACE: '/server' } }] };
EOF
chown -R "$OS_USER:$OS_GROUP" "$UI_DEPLOY_DIR"

cat >/etc/systemd/system/dspace-backend.service <<EOF
[Unit]
Description=DSpace 10 backend
After=network.target postgresql.service solr.service
Requires=postgresql.service solr.service
[Service]
Type=simple
User=$OS_USER
Group=$OS_GROUP
WorkingDirectory=$DSPACE_DIR
Environment=JAVA_OPTS=-Dfile.encoding=UTF-8
ExecStart=$JAVA_HOME/bin/java -Dfile.encoding=UTF-8 -jar $DSPACE_DIR/webapps/server-boot.jar --server.port=$BACKEND_PORT
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=$DSPACE_DIR
[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/dspace-ui.service <<EOF
[Unit]
Description=DSpace Angular UI
After=network.target dspace-backend.service
[Service]
Type=simple
User=$OS_USER
Group=$OS_GROUP
WorkingDirectory=$UI_DEPLOY_DIR
Environment=PM2_HOME=$DSPACE_DIR/.pm2
ExecStart=/usr/bin/pm2-runtime start $UI_DEPLOY_DIR/ecosystem.config.cjs
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=$UI_DEPLOY_DIR $DSPACE_DIR/.pm2
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now dspace-backend dspace-ui

install -d -m 0750 /etc/dspace-installer
cat >/etc/dspace-installer/paths.conf <<EOF
OS_USER='$OS_USER'
OS_GROUP='$OS_GROUP'
DSPACE_DIR='$DSPACE_DIR'
SOURCE_DIR='$SOURCE_DIR'
UI_SOURCE_DIR='$UI_SOURCE_DIR'
UI_DEPLOY_DIR='$UI_DEPLOY_DIR'
SOLR_DIR='$SOLR_DIR'
SOLR_BASE_DIR='$SOLR_BASE_DIR'
SOLR_VERSION_DIR='$SOLR_BASE_DIR/solr-$SOLR_VERSION'
DB_NAME='$DB_NAME'
DB_USER='$DB_USER'
EOF
chmod 0600 /etc/dspace-installer/paths.conf
echo "Instalación completada. UI: http://$HOSTNAME_PUBLIC:$UI_PORT  Backend: http://$HOSTNAME_PUBLIC:$BACKEND_PORT/server"
echo "Para crear el administrador: sudo -u $OS_USER $DSPACE_DIR/bin/dspace create-administrator"
