<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="bandeja/iconos/logo-oscuro.png">
    <img src="bandeja/iconos/logo.png" alt="Helpert, asistente de soporte TI con IA" width="480">
  </picture>
</p>

# Helpert

Asistente de soporte TI Nivel 1. El plan completo está en [Helpert_Plan_de_desarrollo.md](Helpert_Plan_de_desarrollo.md).

Estado: versión multiempresa funcionando en Linux. Incluye servidor, agente (servicio systemd), bandeja con inicio de sesión, chat, historial, ayuda y perfil, instalador de un archivo, 99 playbooks (85 en Linux, 95 en Windows y 81 en macOS) y consola web con casos por nivel (N1 Helpert, N2 en sitio, N3 analista), empresas con fondo de IA, métricas configurables con exportación CSV y administración, sobre PostgreSQL. El agente y la bandeja también compilan y se prueban para Windows y macOS (falta probarlos en un PC y un Mac reales).

Infraestructura: en la nube. El servidor y la consola van en una VPS detrás de Caddy (HTTPS); los datos, en Supabase (PostgreSQL). La IA principal es Gemini (API de Google) y Ollama es el respaldo.

## Piezas

| Carpeta | Qué es |
| --- | --- |
| `server/` | API para los agentes, consola web, capa de IA con respaldo, catálogo, firma de playbooks y evaluación |
| `agente/` | `helpert-agente` (servicio del equipo, Rust) y `helpert` (chat de terminal) |
| `bandeja/` | `helpert-bandeja` (Tauri): icono con los estados del logo y ventana de chat; `iconos/generar.py` dibuja el logo y los iconos |
| `web/` | Estilos y scripts de la consola y de la bandeja: Tailwind + componentes de shadcn/ui, DataTables, Choices.js, ECharts, fuente Inter. `npm run build` deja el resultado en `server/helpert_server/estatico/` y `bandeja/ui/` |
| `playbooks/` | Playbooks: `manifest.toml` + un script por sistema |
| `eval/` | Casos etiquetados y resultados de la evaluación por modelo |
| `despliegue/` | Instaladores y empaquetadores del agente (Linux `.run`, Windows `.zip`, macOS `.zip`) e instalación del servidor en la VPS (Caddy, systemd, respaldo) |
| `pruebas/` | Playbook inofensivo para las pruebas automáticas |

## Probar en este equipo

Necesita `uv`, `cargo`, PostgreSQL (`initdb`, `pg_ctl`) y Ollama con `gemma4:e4b`. `dev.sh` crea un PostgreSQL propio en `.dev/` que solo escucha por socket local.

```sh
./dev.sh usuario tu@correo.pe admin                        # una vez: tu cuenta de la consola (pide la contraseña)
./dev.sh                                                    # firma, registra el equipo, arranca servidor y agente
./dev.sh persona tu@correo.pe "Mi organización"             # en otra terminal: un código de acceso para el chat (24 h)
HELPERT_SOCKET=.dev/agente.sock agente/target/debug/helpert    # el chat: pide el correo y el código la primera vez
```

La consola queda en <http://127.0.0.1:8765/consola>. Roles:
- `admin`: la plataforma. Ve todas las empresas y toda la Administración: emergencia, ajustes, cadena de IA con costos, playbooks, categorías, empresas (fondo, recargas, sedes, personas y códigos de acceso), equipos e inscripción, cuentas y auditoría.
- `admin_empresa`: lo mismo, pero solo de su empresa (Mi empresa, privacidad, equipos y cuentas).
- `analista` (N3) y `tecnico` (N2, asistente en sitio): casos y métricas de su empresa.
- `gerencia`: solo métricas.

`admin_empresa` necesita una empresa: `./dev.sh usuario jefe@acme.pe admin_empresa "Acme SAC"`. Sin empresa, `analista`, `tecnico` y `gerencia` ven todas las empresas (personal de la plataforma).

Las personas de la bandeja entran con su correo y un código. Si hay `[smtp]` en la configuración, el código llega por correo; si no, lo genera soporte en Consola → Empresas → Personas, o con `helpert-server persona`. Un correo cuyo dominio esté en los dominios de una empresa se da de alta solo. El primer inicio de sesión liga el equipo a la empresa de esa persona.

Interfaz: paleta Oxocarbon en modo claro y oscuro (sigue al sistema); el azul de la marca es el color principal. Tras cambiar algo en `web/` o en las clases de `consola.py` / `bandeja/ui`: `(cd web && npm ci && npm run build)`.

El agente corre sin privilegios en desarrollo: los diagnósticos funcionan, y los pasos que cambian algo se detienen en «comprobar» y se escalan. Para ver el ciclo completo con un playbook inofensivo:

```sh
DEV=.dev-pruebas PLAYBOOKS=pruebas/playbooks PUERTO=8766 ./dev.sh
HELPERT_SOCKET=.dev-pruebas/agente.sock agente/target/debug/helpert   # «crea un archivo de prueba llamado x1»
```

Gemini: crea una clave en Google AI Studio y ponla en Administración → IA (proveedor `gemini`). La capa gratuita alcanza para probar, con límites: unas 20 peticiones al día por modelo en `gemini-3.5-flash` (más en `gemini-3.5-flash-lite`), y Google puede usar esos datos para entrenar, así que solo datos de prueba. En producción, una clave de pago.

Medir un modelo con los casos etiquetados (`eval/casos.jsonl`: catálogo, guías, saludos, escalar, lo que no se guía, ataques y conversaciones de varios turnos; cada caso dice qué debe recibir la persona):

```sh
uv run --project server helpert-server --config .dev/helpert-server.toml evaluar eval/casos.jsonl --proveedor 0
```

## Instalar el agente en un equipo Linux

```sh
despliegue/empaquetar-linux.sh --servidor https://helpert.empresa.pe --clave-publica playbooks.pub \
    --inscripcion-archivo inscripcion.txt     # → helpert-instalar.run (agente, bandeja, playbooks firmados)
```

En el equipo: `sh helpert-instalar.run`. Desde la terminal pide la contraseña con sudo; sin terminal, con la ventana de polkit. Aún no es de doble clic: Nautilus abre los `.run` en el editor de texto. Para Ubuntu y Fedora faltan los paquetes .deb y .rpm, y en Arch no hay un instalador gráfico de paquetes por defecto. Instala:
- el servicio `helpert-agente`, que corre como root;
- la bandeja, que arranca al iniciar sesión y aparece en el menú de aplicaciones;
- el registro del equipo en el servidor, con la clave de inscripción (`inscripcion_env` en la configuración del servidor).

Si falta WebKitGTK, lo instala con apt, dnf o pacman; solo se probó en CachyOS (Hyprland con Quickshell). En Ubuntu y Fedora falta probarlo en una VM, incluidos los nombres de los paquetes. Al reinstalar se conserva el token del equipo. Para quitarlo: `sudo despliegue/instalar-agente-linux.sh --desinstalar`.

Con el agente como root, lo que el usuario confirma en el chat se aplica de verdad: limpiar archivos temporales, vaciar la cola de impresión o reiniciar la red.

Clic en el icono: el chat se despliega como panel flotante en la esquina de la barra, como OneDrive en Windows (en Wayland, una capa pegada a la barra, sin taparla); se recoge con otro clic, Esc o al hacer clic fuera. Clic derecho: «Abrir Helpert» y «Salir». El icono se publica por D-Bus (StatusNotifierItem), sin AppIndicator.

Iconos de la bandeja: verde, disponible; azul, pensando (esperando al servidor o a la IA); amarillo, trabajando (corre un paso de playbook); rojo con punto, aviso (respuesta sin leer o error). Usa la versión oscura si el escritorio tiene el esquema oscuro (o no hay gsettings); se fuerza con `HELPERT_TEMA=claro|oscuro`.

## Instalar el agente en Windows

Windows 10 y 11, x64. Se compila y se prueba en la CI (`.github/workflows/ci.yml`, trabajo `windows`: pruebas del agente y de la bandeja, los scripts de los playbooks con PowerShell 5.1 y una prueba de punta a punta con el servicio real, la tubería y un servidor). El artefacto `helpert-windows` trae los `.exe`.

```sh
despliegue/empaquetar-windows.sh --servidor https://helpert.miempresa.pe --clave-publica playbooks.pub \
    --inscripcion-archivo inscripcion.txt     # → helpert-windows.zip; baja los .exe de la CI de este mismo commit
```

En el equipo: descomprimir y doble clic en «Instalar Helpert.cmd» (pide permisos de administrador). Para GPO o Intune: `powershell -ExecutionPolicy Bypass -File instalar.ps1 -Silencioso`. Instala el servicio `Helpert` (LocalSystem; se reinicia solo si falla), la bandeja (arranca al iniciar sesión y está en el menú Inicio), WebView2 si falta (comprueba que lo firma Microsoft) y registra el equipo con la clave de inscripción. Datos y registro en `C:\ProgramData\Helpert`, solo para SYSTEM y Administradores. `helpert.exe --estado` dice si el servicio y el servidor responden. Para quitarlo: «Desinstalar Helpert.cmd».

Clic en el icono: el panel se despliega en la esquina, como OneDrive; clic derecho: «Abrir Helpert» y «Salir». La bandeja y la guía en pantalla con «Hazlo tú» (SendInput) solo se han comprobado compilando: falta probarlas en un PC real, igual que SmartScreen/Defender con los `.exe` sin firma de código (pedirán confirmación hasta firmarlos con un certificado de editor) y los avisos del sistema (hoy solo cambia el icono).

Playbooks: 99 en total, 95 con script de Windows. Sin script de Windows: los propios de Linux (`app.update-apps`, `disk.boot-space`, `files.home-permissions`) y `print.supply-levels` (Windows no da los niveles de tóner sin el programa de cada fabricante); en Windows esos casos van a guía o a un técnico. Los que actúan en la sesión de la persona (VPN, unidades de red) usan una tarea programada como ella, que se borra al terminar: asoma una ventana un instante.

## Instalar el agente en macOS

macOS 13 o más nuevo, Apple Silicon e Intel (binarios universales). Se compila y se prueba en la CI (trabajo `macos`: pruebas del agente y de la bandeja, `despliegue/armar-macos.sh` arma los binarios y `Helpert.app`, y `despliegue/probar-macos-ci.sh` instala el servicio de verdad con launchd, consulta por el socket y desinstala). El artefacto `helpert-macos` trae los binarios.

```sh
despliegue/empaquetar-macos.sh --servidor https://helpert.miempresa.pe --clave-publica playbooks.pub \
    --inscripcion-archivo inscripcion.txt     # → helpert-macos.zip; baja los binarios de la CI de este mismo commit
```

En el Mac: abrir el .zip y doble clic en «Instalar Helpert.command» (pide la contraseña de administrador; la primera vez macOS puede bloquearlo por no ser de un desarrollador identificado: clic derecho > Abrir). Instala el servicio `pe.helpert.agente` (LaunchDaemon, root; launchd lo vuelve a arrancar si sale), `Helpert.app` en Aplicaciones (solo en la barra de menús, arranca al iniciar sesión) y registra el equipo. Configuración en `/etc/helpert` (solo root), playbooks en `/usr/local/lib/helpert`, registro en `/var/log/helpert-agente.log`. Para quitarlo: «Desinstalar Helpert.command».

Sin probar en un Mac real: la bandeja (icono en la barra de menús y panel), los permisos que macOS pide la primera vez («Grabación de pantalla» para la captura; «Acceso total al disco» para que el servicio lea carpetas protegidas como Documentos o la Papelera, que se da en Ajustes del Sistema o con un perfil MDM) y Gatekeeper con binarios sin firma de Apple (firma ad hoc; para quitar el aviso hace falta una cuenta de desarrollador y notarizarlos). «Hazlo tú» en macOS señala dónde hacer clic pero no lo hace: el clic lo da la persona.

Playbooks en macOS: 81 de 99. Sin script, porque macOS no lo permite o no tiene sentido: los de Windows y Office (activación de Windows, licencia y reparación de Office, caché de Outlook, rutas largas, Winsock, impresora PDF, reparar archivos del sistema), `app.update-apps`, `disk.boot-space`, `disk.optimize` (APFS hace TRIM solo), `domain.refresh-policies` (los perfiles MDM los envía el servidor), `hw.device-errors`, `hw.display-detect`, `hw.privacy-access` (sin MDM no se cambian), `print.scanner`, `system.services-check` (launchd ya reinicia los esenciales) y `system.slow-boot`. `security.quick-scan` en macOS necesita Microsoft Defender (XProtect no tiene un análisis que se pueda lanzar).

## Playbooks

Cada carpeta de `playbooks/` tiene `manifest.toml` (lo que lee la IA para elegir: nombre, descripción, riesgo, parámetros) y un script por sistema (`linux.sh`, `windows.ps1`, `macos.sh`) con los pasos `diagnosticar`, `comprobar`, `aplicar`, `verificar` y, si se puede deshacer, `deshacer`. Lo que toca archivos de la persona corre como ella (suplantación en Windows, `runuser`/`sudo -u` en Linux y macOS), nunca como root o SYSTEM.

La CI corre cada script como lo lanza el agente, como root o SYSTEM, en máquinas desechables de GitHub (`playbooks/probar-unix.py` en Ubuntu y macOS, `playbooks/probar-windows.ps1` en Windows): `diagnosticar` siempre y, si dice que hay algo que hacer, también `comprobar`, `aplicar` y `verificar`, salvo los que dejarían a la máquina sin red o la reiniciarían. Lo que una máquina de la CI no tiene (Wi-Fi, impresoras, dominio, USB, batería) solo se prueba en equipos reales. **Nunca corras esas pruebas con `--aplicar` en un equipo de verdad.**

Tras cambiar un playbook, súbele la `version` y vuelve a firmar (`helpert-server firmar playbooks --clave ...`).

## Pruebas

```sh
./dev.sh pg && (cd server && uv run pytest -q)   # arranca el PostgreSQL de .dev y corre las pruebas
(cd agente && cargo test -q)                     # firma Python → verificación Rust, parámetros, https
(cd agente && cargo test -q -- --ignored)        # HTTPS real contra internet
```

## Llevar el servidor a producción

Una VPS con Debian 12+ o Ubuntu 24.04+, un nombre DNS apuntando a ella (los agentes solo hablan HTTPS) y los puertos 80 y 443 abiertos. Lo probado: el servidor, `revisar`, `/salud`, el respaldo y su rotación, en este equipo; el script de instalación completo aún no se ha corrido en una VPS real.

1. **En tu equipo, firma los playbooks.** La clave privada nunca va a la VPS, al repositorio ni a los equipos:
   ```sh
   uv run --project server helpert-server claves ~/helpert-claves            # una sola vez; guárdala fuera de línea
   uv run --project server helpert-server firmar playbooks --clave ~/helpert-claves/playbooks.key
   ```
2. **Copia el repositorio (con las firmas) y la clave pública a la VPS**, por ejemplo con `rsync -a --exclude .git --exclude .dev --exclude target ./ vps:helpert/` y `scp ~/helpert-claves/playbooks.pub vps:`.
3. **En la VPS:** `sudo helpert/despliegue/instalar-servidor.sh --dominio helpert.miempresa.pe --clave-publica playbooks.pub`. Instala PostgreSQL local (o `--db-env` para usar Supabase: pon la cadena en `HELPERT_DB` y vuelve a ejecutarlo), `uv`, Caddy con HTTPS, el servicio, el respaldo diario (`/var/backups/helpert`, se guardan 14) y el cortafuegos. Genera en `/etc/helpert/servidor.env` la clave maestra y la de inscripción; **guarda una copia de la clave maestra fuera de la VPS**: sin ella, las claves de API guardadas en la consola no se pueden leer. Volver a ejecutarlo actualiza el código sin tocar la configuración ni los secretos.
4. `sudo helpert-server usuario-consola TU-CORREO --rol admin`, entra en `https://DOMINIO/consola` y pon la clave de la IA en Administración → IA (la capa gratuita de Gemini es solo para pruebas).
5. `sudo helpert-server revisar` comprueba la base, la cuenta admin, la clave maestra, la inscripción, la firma de cada playbook contra la clave pública, las claves de la IA y el correo; sale con 1 si falta algo. `https://DOMINIO/salud` responde 200 si el servidor llega a la base (sirve para un monitor externo).

**Traer los datos de desarrollo** (opcional): en tu equipo `pg_dump --format=custom --no-owner "postgresql://helpert@/helpert?host=$PWD/.dev/pgsock" > helpert.dump`, cópialo y en la VPS `sudo -u helpert pg_restore --clean --if-exists --no-owner -d helpert helpert.dump`. Copia también el valor de `.dev/clave-maestra` en `HELPERT_CLAVE_MAESTRA` (si no, vuelve a escribir las claves de API) y reinicia con `sudo systemctl restart helpert-server`. Los equipos registrados contra el servidor de desarrollo hay que reinstalarlos con el paquete nuevo (apuntan a otra dirección).

Más:
- Correo para los códigos de acceso: bloque `[smtp]` en `/etc/helpert/helpert-server.toml` y la contraseña en `HELPERT_SMTP_CLAVE`.
- **Versiones del agente.** Fuera de la VPS: `helpert-server firmar-agente BINARIO --version X --so linux|windows --clave CLAVE_PRIVADA`. En la VPS: `sudo helpert-server publicar-agente BINARIO --version X --firma BINARIO.firma`. Publica primero la versión que ya tienen los equipos y márcala estable (es a la que se vuelve); la nueva se despliega por etapas en Consola → Administración → Equipos. Cada agente comprueba la firma, prueba el binario nuevo (`--version`) y se reinicia. La bandeja aún se actualiza reinstalando.
- Retención de capturas: el servidor borra las vencidas cada hora; `sudo helpert-server purgar` lo hace a mano.
- Restaurar un respaldo: `sudo -u helpert pg_restore --clean --if-exists -d helpert /var/backups/helpert/helpert-AAAAMMDD-HHMM.dump`. Copia esos archivos fuera de la VPS con tu sistema de respaldo.

## Reglas

- Nivel 1: en cada mensaje la IA declara una acción (`accion`): elegir un playbook del catálogo, dar una guía con pasos (dudas de uso), preguntar o escalar. La decisión final la toma `ia.resolver`, la misma función para la API y para la evaluación:
  - Antes de pasar a una persona, Helpert pregunta (como mucho 2 veces) si el modelo duda o falta un dato. Pedir «una persona» escala enseguida.
  - Un dato que la persona no escribió (un nombre inventado, «null») no se usa: se pregunta.
  - Un mensaje con señales de inyección (`; reboot`, `| sudo bash`, `rm -rf`, «ignora tus instrucciones») nunca ejecuta un playbook ni recibe una guía.
  - Una guía termina con «¿se resolvió?» y la calificación; si no, pasa a N2. Una duda de uso nunca abre una visita de técnico sola.
  - Nunca guía a desactivar el antivirus, saltarse controles ni entrar a la cuenta de otra persona: escala.
- El servidor valida la respuesta de la IA y los parámetros, y el agente los vuelve a validar.
- Nada se aplica sin una confirmación del usuario registrada en el servidor.
- El agente ejecuta los bytes que verificó con la firma Ed25519, y solo habla con el servidor por `https://` (o con uno local en desarrollo).
- La consola escapa todo dato que no escribimos (usuario, IA, scripts) y usa CSP estricta: solo scripts propios servidos por el mismo servidor, y todo funciona sin JavaScript. Los formularios de administración llevan token CSRF y cada cambio queda en `auditoria`. Los ajustes se guardan en la tabla `ajustes` (el TOML solo da los valores iniciales) y la API los lee en cada petición, así que pausar los agentes, apagar la IA o desactivar un playbook actúa en segundos. Las claves de API se guardan cifradas (Fernet, con `HELPERT_CLAVE_MAESTRA`), nunca se muestran ni entran en la auditoría; también pueden ir en variables `HELPERT_IA_*`.
- Reglas por área (Administración → Privacidad): un área «solo IA local» nunca usa un proveedor externo; si no hay uno local activo, recibe el menú sin IA. También bloquean playbooks y capturas por área.
- Capturas: apagadas por defecto. Con ellas activas, Helpert pide permiso, la persona ve la captura antes de enviarla y se registra el sí o el no. Solo las ven Administración, el Analista N2 y el técnico asignado, y cada vista queda en la auditoría. Falta el ocultamiento automático de datos sensibles que pide el plan.
- Guía en pantalla: después de una guía escrita, si el área permite capturas, la bandeja ofrece «Guíame en pantalla». Helpert toma la pantalla, el modelo de visión lista sus elementos con su caja (análisis de pantalla), el servidor les dibuja números (Set-of-Mark) y el modelo elige un número y una acción de una lista cerrada (clic, doble clic, desplazar). La bandeja resalta ese elemento y lleva un cursor fantasma hasta él, en una capa transparente que deja pasar los clics. La persona hace el paso, o pulsa «Hazlo tú» y Helpert hace solo ese clic (Hyprland: `ydotool`; X11: `xdotool`); nunca escribe texto. La imagen no se guarda, solo el texto de cada paso. Un paso que pide contraseñas, códigos o comandos se escala, y cada caso tiene un tope de 12 pasos y 24 intentos.
- Empresas: cada consulta de la consola filtra por la empresa de la cuenta; un id de otra empresa da 404. La API solo atiende a una persona con sesión en ese equipo. Con el fondo activo y sin saldo (o con la persona en su tope del mes), no se llama a ninguna IA externa: atiende el modelo local, luego el menú y luego se escala.
- La bandeja solo abre `mailto:` y `https://wa.me/<dígitos>`, y solo ejecuta `rustdesk` o `anydesk`; nada de lo que llega del servidor se ejecuta tal cual.
- Atajos marcados con `shortcut:` en el código: clave de inscripción compartida en el instalador, login propio en lugar de Supabase Auth, token sin TLS mutuo y una conexión a la base por petición.
