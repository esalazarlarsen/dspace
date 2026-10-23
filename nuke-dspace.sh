#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Ejecuta con sudo." >&2; exit 1; }
CONF=/etc/dspace-installer/paths.conf
[[ -f $CONF ]] || { echo "No existe $CONF; no puedo determinar rutas seguras. Nada eliminado." >&2; exit 1; }
# This file is created only by install-dspace.sh and contains validated local paths.
# shellcheck disable=SC1090
source "$CONF"
echo "Se eliminarán servicios DSpace, el usuario/grupo $OS_USER:$OS_GROUP,"
echo "las rutas registradas y la base '$DB_NAME' (usuario PostgreSQL '$DB_USER')."
read -r -p "Escribe NUKE para continuar: " answer
[[ $answer == NUKE ]] || { echo "Cancelado."; exit 0; }
systemctl disable --now dspace-ui dspace-backend solr 2>/dev/null || true
rm -f /etc/systemd/system/dspace-ui.service /etc/systemd/system/dspace-backend.service
systemctl daemon-reload
runuser -u postgres -- dropdb --if-exists "$DB_NAME"
runuser -u postgres -- psql -c "DROP ROLE IF EXISTS \"$DB_USER\";" || true
rm -rf -- "$DSPACE_DIR" "$SOURCE_DIR" "$UI_SOURCE_DIR" "$UI_DEPLOY_DIR"
rm -f /etc/systemd/system/solr.service
systemctl daemon-reload
rm -rf -- "$SOLR_DIR" "$SOLR_VERSION_DIR"
rm -rf /var/solr
rm -f /etc/default/solr.in.sh /etc/init.d/solr /etc/profile.d/dspace-java.sh
getent passwd solr >/dev/null && userdel solr || true
getent group solr >/dev/null && groupdel solr || true
getent passwd "$OS_USER" >/dev/null && userdel "$OS_USER" || true
getent group "$OS_GROUP" >/dev/null && groupdel "$OS_GROUP" || true
rm -rf /etc/dspace-installer
echo "Datos y servicios asociados a DSpace eliminados. Los paquetes Ubuntu compartidos (Java, PostgreSQL, Node, nginx) se conservaron."
