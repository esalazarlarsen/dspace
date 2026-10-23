# Instalación nativa de DSpace 10 en Ubuntu

Scripts interactivos e idempotentes para Ubuntu 22.04/24.04. Siguen la [guía oficial de instalación de DSpace 10](https://wiki.lyrasis.org/spaces/DSDOC10x/pages/408944708/Installing+DSpace): backend Java 21, PostgreSQL, Solr 9 y UI Angular con Node.js 22/PM2. El backend usa el JAR ejecutable con Tomcat integrado.

## Uso

```bash
chmod +x prerequisitos-dspace.sh install-dspace.sh nuke-dspace.sh
./prerequisitos-dspace.sh
sudo ./install-dspace.sh
```

`prerequisitos-dspace.sh` comprueba Ubuntu 22.04/24.04, conexión HTTPS y recursos aproximados del servidor. Después pregunta rutas, nombre del repositorio, dominio/IP, puertos, versiones y credenciales PostgreSQL, y guarda las respuestas en `.env` con permisos `600`. No instala paquetes. Si dejas vacía la contraseña, genera una aleatoria; conserva el `.env` porque contiene ese secreto.

`install-dspace.sh` lee ese `.env` y realiza la instalación. No requiere cuenta de GitHub: descarga los repositorios públicos de DSpace automáticamente, por lo que el servidor necesita acceso a Internet. Se puede volver a ejecutar; conserva la base de datos y el build ya instalado. La primera instalación compila DSpace y la UI y puede tardar varios minutos.

Para cambiar los valores, vuelve a ejecutar `./prerequisitos-dspace.sh`; confirma y guarda la nueva configuración antes de ejecutar el instalador. No publiques ni compartas `.env`.

Para una prueba en una sola máquina, responde `localhost` como host. Para producción, usa el dominio público y configura HTTPS con Nginx y un certificado válido antes de permitir inicios de sesión desde otros equipos. El script instala Nginx pero no publica un virtual host ni abre el firewall automáticamente.

Crear la cuenta administradora inicial:

```bash
sudo -u dspace /dspace/bin/dspace create-administrator
```

Comprobar los servicios:

```bash
systemctl status dspace-backend dspace-ui solr postgresql
journalctl -u dspace-backend -u dspace-ui -f
```

## Eliminación completa

```bash
sudo ./nuke-dspace.sh
```

El nuke muestra el alcance y exige escribir `NUKE`. Elimina las rutas registradas, servicios, usuario/grupo dedicados, Solr y la base/rol PostgreSQL definidos durante la instalación. Conserva paquetes compartidos del sistema (Java, PostgreSQL, Node, Nginx) y no borra archivos fuera de las rutas registradas.

## Notas operativas

- La cuenta `dspace` es de sistema, sin shell de inicio de sesión; Solr corre con la cuenta separada `solr`.
- Los puertos del backend, UI y Solr deben quedar restringidos a localhost/firewall. Para producción, termina TLS en el proxy inverso y alinea las URL públicas en `local.cfg` y la configuración UI.
- DSpace necesita tareas programadas para thumbnails, indexación y estadísticas; deben configurarse siguiendo la sección *Scheduled Tasks via Cron* de la documentación oficial.
- Una reinstalación limpia después de `nuke-dspace.sh` requerirá volver a ingresar los mismos valores. El nuke no desinstala paquetes del sistema ni elimina PostgreSQL.
