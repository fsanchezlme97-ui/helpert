"""Consola web del Analista N2: casos, detalle y métricas. Solo lectura en esta versión.

Interfaz: tema de shadcn/ui sobre Tailwind (web/tema.css), DataTables, Choices.js y ECharts, todo servido desde
/consola/estatico (sin CDN). Las páginas se arman en el servidor y funcionan sin JavaScript; el JavaScript
(web/consola.js) solo agrega búsqueda, filtros, gráficos y refresco.

Seguridad (queda expuesta en internet, detrás de un proxy con TLS):
- Todo texto que viene del usuario, de la IA o de los scripts se escapa con `e()`. CSP estricta: solo scripts y
  estilos propios, sin código en línea; los datos de los gráficos van en atributos data-* escapados.
- Sesión en el servidor (solo se guarda el hash del token), cookie HttpOnly + SameSite=Strict + Secure con https.
- Intentos fallidos limitados por IP del cliente (la que entrega el proxy de confianza), no por cuenta,
  para que nadie pueda bloquear la cuenta del analista desde fuera.

Paso a Supabase Auth con MFA (por decidir cómo): o el servidor llama a la API de Supabase Auth (contraseña y luego
código TOTP), o la página de login carga supabase-js con una excepción de CSP solo para esa página.
En ambos casos el final es el mismo: verificar el JWT con las claves del proyecto, exigir `aal == "aal2"` (MFA hecho),
buscar la persona por `usuarios_consola.auth_id` y llamar a `crear_sesion()`. Roles y páginas no cambian.
Hasta entonces la consola entra solo con contraseña: no hay MFA.
"""
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import time
from collections import defaultdict, deque
from datetime import date, datetime, timedelta
from pathlib import Path
from urllib.parse import parse_qs, urlencode
from zoneinfo import ZoneInfo, available_timezones

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from starlette.concurrency import run_in_threadpool

import psycopg

from . import ajustes
from . import catalogo as cat
from . import db, ia

COOKIE = "helpert_sesion"
VENTANA = 15 * 60  # segundos en los que se cuentan los intentos fallidos de entrar
SIN_SENAL = timedelta(minutes=15)  # el agente envía un latido cada 5 minutos; 3 perdidos = sin señal
ESTADOS = {"abiertos": "Abiertos", "escalado": "Escalados", "cerrado": "Cerrados", "todos": "Todos"}
ESTATICO = Path(__file__).parent / "estatico"
E = "/consola/estatico"

CABECERAS = {
    "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
                               "font-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "X-Frame-Options": "DENY",
    "Cache-Control": "no-store",
}

# Iconos de Lucide (los de shadcn/ui), en línea: no hay fuente de iconos ni peticiones extra.
ICONOS = {
    "casos": '<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
    "metricas": '<path d="M3 3v16a2 2 0 0 0 2 2h16"/><path d="M18 17V9"/><path d="M13 17V5"/><path d="M8 17v-3"/>',
    "salir": '<path d="m16 17 5-5-5-5"/><path d="M21 12H9"/><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/>',
    "atras": '<path d="m12 19-7-7 7-7"/><path d="M19 12H5"/>',
    "equipo": '<rect width="20" height="14" x="2" y="3" rx="2"/><line x1="8" x2="16" y1="21" y2="21"/><line x1="12" x2="12" y1="17" y2="21"/>',
    "usuario": '<path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>',
    "buscar": '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
    "alerta": '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
    "ok": '<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>',
    "reloj": '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
    "estrella": '<path d="M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z"/>',
    "mensaje": '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
    "terminal": '<polyline points="4 17 10 11 4 5"/><line x1="12" x2="20" y1="19" y2="19"/>',
    "escalar": '<path d="M7 7h10v10"/><path d="M7 17 17 7"/>',
    "meta": '<circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="2"/>',
    "lista": '<path d="m3 17 2 2 4-4"/><path d="m3 7 2 2 4-4"/><path d="M13 6h8"/><path d="M13 12h8"/><path d="M13 18h8"/>',
    "admin": '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/>',
    "llave": '<path d="m15.5 7.5 2.3 2.3a1 1 0 0 0 1.4 0l2.1-2.1a1 1 0 0 0 0-1.4L19 4"/><path d="m21 2-9.6 9.6"/><circle cx="7.5" cy="15.5" r="5.5"/>',
    "mas": '<path d="M5 12h14"/><path d="M12 5v14"/>',
    "copiar": '<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>',
    "prohibido": '<circle cx="12" cy="12" r="10"/><path d="m4.9 4.9 14.2 14.2"/>',
    "candado": '<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
    "camara": '<path d="M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3l-2.5-3z"/><circle cx="12" cy="13" r="3"/>',
    "cursor": '<path d="M4 4l7.07 17 2.51-7.39L21 11.07z"/>',
    "visitas": '<path d="M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0"/><circle cx="12" cy="10" r="3"/>',
    "subir": '<path d="M12 3v12"/><path d="m17 8-5-5-5 5"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>',
    "empresa": '<path d="M6 22V4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v18Z"/><path d="M6 12H4a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h2"/><path d="M18 9h2a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-2"/><path d="M10 6h4"/><path d="M10 10h4"/><path d="M10 14h4"/><path d="M10 18h4"/>',
    "telefono": '<path d="M13.832 16.568a1 1 0 0 0 1.213-.303l.355-.465A2 2 0 0 1 17 15h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2A18 18 0 0 1 2 4a2 2 0 0 1 2-2h3a2 2 0 0 1 2 2v3a2 2 0 0 1-.8 1.6l-.468.351a1 1 0 0 0-.292 1.233 14 14 0 0 0 6.392 6.384"/>',
    "dinero": '<rect width="20" height="12" x="2" y="6" rx="2"/><circle cx="12" cy="12" r="2"/><path d="M6 12h.01M18 12h.01"/>',
    "ia": '<path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2"/><path d="M20 14h2"/><path d="M15 13v2"/><path d="M9 13v2"/>',
}
ROLES = {"admin": "Administración (plataforma)", "admin_empresa": "Administración de la empresa",
         "analista": "Analista N3", "tecnico": "Asistente N2 (en sitio)", "gerencia": "Gerencia"}
JEFES = ("admin", "admin_empresa", "analista")  # asignan visitas, ven capturas, pasan casos entre niveles
SOPORTE = (*JEFES, "tecnico")
NIVEL = {1: ("N1 · Helpert", "info"), 2: ("N2 · Soporte", "alerta"), 3: ("N3 · Analista", "peligro")}

# Estado del caso → (texto, variante de insignia). Los colores son los del casco del logo.
ESTADO_CASO = {
    "conversando": ("Conversando", "info"), "menu": ("Menú sin IA", "info"),
    "esperando_confirmacion": ("Espera confirmación", "alerta"), "aplicando": ("Aplicando", "alerta"),
    "esperando_cierre": ("Espera cierre", "neutra"), "escalado": ("Escalado", "peligro"), "cerrado": ("Cerrado", "exito"),
}


def e(x) -> str:
    """Escapa todo lo que no escribimos nosotros. Ningún dato llega a la página sin pasar por aquí."""
    return "—" if x is None or x == "" else html.escape(str(x), quote=True)


def icono(nombre: str, clase: str = "size-4") -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
            f'stroke-linecap="round" stroke-linejoin="round" class="{clase}" aria-hidden="true">{ICONOS[nombre]}</svg>')


def logo(clase: str = "size-8", alt: str = "") -> str:
    """Logo: la cabeza de la mascota (se lee igual en los dos temas)."""
    return f'<img src="{E}/icono.png" alt="{alt}" class="shrink-0 {clase}">'


def insignia(texto: str, variante: str = "neutra", icono_: str = "") -> str:
    return f'<span class="insignia insignia-{variante}">{icono(icono_) if icono_ else ""}{e(texto)}</span>'


def estado_caso(estado: str, resuelto=None) -> str:
    texto, variante = ESTADO_CASO.get(estado, (estado, "neutra"))
    if estado == "cerrado" and resuelto is False:
        texto, variante = "Cerrado sin resolver", "neutra"
    return insignia(texto, variante)


def codigo_paso(codigo) -> str:
    """Código de salida de un paso de playbook (contrato del plan) como insignia."""
    if codigo is None:
        return insignia("En curso", "info")
    return {0: insignia("0 · correcto", "exito"), 10: insignia("10 · nada que corregir", "neutra"),
            3: insignia("3 · requisito no cumplido", "alerta"), 124: insignia("124 · tiempo agotado", "peligro"),
            -1: insignia("Rechazado por el agente", "peligro")}.get(codigo, insignia(f"{codigo} · error", "peligro"))


def encabezado(titulo: str, descripcion: str = "", acciones: str = "") -> str:
    return (f'<div class="flex flex-wrap items-end justify-between gap-4"><div class="space-y-1">'
            f'<h1 class="flex flex-wrap items-center gap-3 text-2xl font-semibold tracking-tight">{titulo}</h1>'
            f'{f"<p class=\"text-sm text-muted-foreground\">{descripcion}</p>" if descripcion else ""}</div>{acciones}</div>')


def cifra(titulo: str, valor: str, nota: str, icono_: str, clase_valor: str = "", compacta: bool = False) -> str:
    """Tarjeta de cifra (patrón de los dashboards de shadcn). compacta: una fila más baja, para encima de una tabla."""
    if compacta:
        return (f'<div class="tarjeta flex-row items-center gap-3 px-4 py-3"><span class="flex size-9 shrink-0 items-center '
                f'justify-center rounded-md bg-muted text-muted-foreground">{icono(icono_)}</span><div class="min-w-0">'
                f'<p class="flex items-baseline gap-2"><span class="text-2xl font-semibold tabular-nums tracking-tight {clase_valor}">'
                f'{valor}</span><span class="truncate text-sm font-medium text-muted-foreground">{titulo}</span></p>'
                f'<p class="truncate text-xs text-muted-foreground">{nota}</p></div></div>')
    return (f'<div class="tarjeta gap-3 py-5"><div class="flex items-center justify-between px-5">'
            f'<span class="text-sm font-medium text-muted-foreground">{titulo}</span>'
            f'<span class="text-muted-foreground">{icono(icono_)}</span></div>'
            f'<div class="px-5"><div class="text-3xl font-semibold tabular-nums tracking-tight {clase_valor}">{valor}</div>'
            f'<p class="mt-1 text-xs text-muted-foreground">{nota}</p></div></div>')


def montar(app: FastAPI, cfg: dict) -> None:
    dsn = cfg["base_datos"]
    cache: dict = {}  # empresa (None = plataforma) → (momento, ajustes)

    def aj(empresa_id=None):
        """Ajustes para la consola, con 5 s de caché por empresa (la API del agente los lee sin caché)."""
        t, v = cache.get(empresa_id, (0.0, None))
        if v is None or time.monotonic() - t > 5:
            with db.conexion(dsn) as c:
                v = ajustes.leer(c, cfg, empresa_id)
            cache[empresa_id] = (time.monotonic(), v)
        return v

    def zona():
        return ZoneInfo(aj()["zona_horaria"])

    fallos: dict[str, deque] = defaultdict(deque)
    app.mount(E, StaticFiles(directory=ESTATICO), name="estatico")
    # ?v=<hash del contenido>: al cambiar un archivo cambia su URL, así se puede cachear sin servir versiones viejas.
    version = {f.name: hashlib.sha256(f.read_bytes()).hexdigest()[:10] for f in ESTATICO.iterdir() if f.is_file()}
    url = lambda nombre: f"{E}/{nombre}?v={version.get(nombre, '0')}"

    @app.middleware("http")
    async def cabeceras_estaticos(request: Request, siguiente):
        r = await siguiente(request)
        if request.url.path.startswith(E + "/"):
            r.headers["X-Content-Type-Options"] = "nosniff"
            r.headers["Cache-Control"] = "public, max-age=604800, immutable" if request.url.query else "no-cache"
        return r

    def fecha(d):
        return d.astimezone(zona()).strftime("%d/%m %H:%M") if d else "—"

    def pagina(titulo, cuerpo, persona=None, actual="", refrescar=None, estado=200, libs=()):
        """libs: librerías que usa la página ("datatables", "choices", "echarts")."""
        estilos = f'<link rel="stylesheet" href="{url("consola.css")}">'
        scripts = "".join(f'<script src="{url(n + ".js")}" defer></script>' for n in libs)
        if persona:
            scripts += f'<script src="{url("consola.js")}" defer></script>'
        meta = f'<noscript><meta http-equiv="refresh" content="{refrescar}"></noscript>' if refrescar else ""
        cuerpo_html = marco(titulo, cuerpo, persona, actual) if persona else cuerpo
        return HTMLResponse(
            f'<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" '
            f'content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark">{meta}'
            f'<title>{e(titulo)} · Helpert</title><link rel="icon" href="{E}/icono.png" type="image/png">{estilos}{scripts}'
            f'</head><body{f" data-refrescar={refrescar}" if refrescar else ""}>{cuerpo_html}</body></html>',
            status_code=estado, headers=CABECERAS)

    def emergencia(persona):
        """Aviso en todas las páginas mientras haya un interruptor de emergencia activo."""
        a = aj()
        partes = (["los agentes están en pausa"] if a["agentes_pausados"] else []) + ([] if a["ia_activa"] else ["la IA está apagada"])
        enlace = (' <a class="font-medium underline" href="/consola/admin/general">Ir a los interruptores</a>'
                  if persona["rol"] == "admin" else "")
        html_ = (f'<div class="alerta alerta-peligro" role="alert">{icono("alerta")}<p>Interruptor de emergencia activo: '
                 f'{" y ".join(partes)}.{enlace}</p></div>') if partes else ""
        if persona["rol"] in ("admin", "admin_empresa"):  # fondos de IA con saldo bajo
            with db.conexion(dsn) as c:
                bajos = [f for f in fondos(c, "e.fondo_activo AND e.activa AND " + alc(persona, "e.id"))
                         if float(f["saldo"]) < float(f["alerta_usd"])]
            if bajos:
                html_ += (f'<div class="alerta border-alerta/40" role="status">{icono("dinero")}<p>Fondo de IA bajo: '
                          + ", ".join(f'<a class="font-medium underline" href="/consola/admin/empresas/{f["id"]}">{e(f["nombre"])}</a> '
                                      f'({usd(f["saldo"])})' for f in bajos)
                          + '. Sin saldo, Helpert atiende solo con IA local o con el menú.</p></div>')
        return html_

    def marco(titulo, cuerpo, persona, actual):
        """Barra lateral (shadcn Sidebar) + cabecera + contenido."""
        enlaces = [("metricas", "/consola/metricas", "Métricas")]
        gestion = [("admin", "/consola/admin", "Administración")] if persona["rol"] in ("admin", "admin_empresa") else []
        escalados = 0
        pendientes = 0
        if persona["rol"] != "gerencia":
            enlaces.insert(0, ("casos", "/consola", "Casos"))
            enlaces.insert(1, ("visitas", "/consola/visitas", "Atención física"))
            with db.conexion(dsn) as c:
                escalados = c.execute(f"SELECT count(*) AS n FROM casos WHERE estado = 'escalado' AND {alc(persona, 'empresa_id')}"
                                      ).fetchone()["n"]
                pendientes = c.execute(f"SELECT count(*) AS n FROM visitas v JOIN casos k ON k.id = v.caso_id WHERE "
                                       f"{alc(persona, 'k.empresa_id')} AND (v.estado = 'pendiente' OR "
                                       "(v.estado = 'asignada' AND v.tecnico_id = %s))", (persona["id"],)).fetchone()["n"]

        def enlace(k, u, t, movil=False, ic=None):
            n, titulo_n = {"casos": (escalados, "Casos escalados"), "visitas": (pendientes, "Visitas por asignar o tuyas")}.get(k, (0, ""))
            extra = (f'<span class="ml-auto rounded-full bg-peligro/15 px-1.5 py-px text-xs font-medium tabular-nums '
                     f'text-peligro" title="{titulo_n}">{n}</span>' if n and not movil else "")
            clase = ("inline-flex h-8 items-center gap-1.5 rounded-md px-2 text-sm font-medium text-muted-foreground "
                     "hover:bg-accent hover:text-foreground aria-[current=page]:bg-accent aria-[current=page]:text-foreground"
                     if movil else
                     "flex h-9 items-center gap-2.5 rounded-md px-2.5 text-sm font-medium text-muted-foreground transition-colors "
                     "hover:bg-sidebar-accent hover:text-foreground aria-[current=page]:bg-primario-suave "
                     "aria-[current=page]:text-sobre-primario-suave")
            t = {"admin": "Admin", "visitas": "Visitas"}.get(k, t) if movil else t  # en el menú del móvil no caben los largos
            actual_ = k == actual or (movil and k == "admin" and actual.startswith("admin"))
            return f'<a href="{u}" class="{clase} shrink-0"{" aria-current=page" if actual_ else ""}>{icono(ic or k)}{t}{extra}</a>'

        # Administración desglosada en la barra: cada sección es un enlace (antes, pestañas dentro de la página)
        grupos = []
        if gestion:
            secs = secciones(persona)
            de_empresa = [k for k in ("empresas", "equipos", "usuarios", "privacidad") if k in secs]
            grupos = ([("Clientes", de_empresa), ("Plataforma", [k for k in secs if k not in de_empresa])]
                      if persona["rol"] == "admin" else [("Administración", de_empresa)])
        titulo_g = lambda t, primero=False: (f'<p class="px-2.5 pb-1 {"pt-1" if primero else "pt-4"} text-xs font-medium '
                                             f'text-muted-foreground">{t}</p>')
        nombre = persona["nombre"] or persona["email"]
        iniciales = "".join(p[0] for p in str(nombre).split()[:2]).upper() or "?"
        salir = (f'<form method="post" action="/consola/salir"><button class="btn btn-fantasma btn-icono" '
                 f'title="Salir" aria-label="Salir">{icono("salir")}</button></form>')
        lateral = (
            '<aside class="sticky top-0 hidden h-svh w-64 shrink-0 flex-col border-r bg-sidebar md:flex">'
            f'<div class="flex h-14 items-center gap-2.5 border-b px-4">{logo()}'
            '<div class="grid leading-tight"><span class="text-sm font-semibold">Helpert</span>'
            '<span class="text-xs text-muted-foreground">Consola de soporte TI</span></div></div>'
            '<nav class="flex flex-1 flex-col gap-1 overflow-y-auto p-3" aria-label="Secciones">'
            + titulo_g("Soporte", True) + "".join(enlace(*x) for x in enlaces)
            + "".join(titulo_g(g) + "".join(enlace(f"admin:{k}", f"/consola/admin/{k}", secciones(persona)[k][0],
                                                     ic=secciones(persona)[k][1]) for k in ks)
                      for g, ks in grupos if ks) + '</nav>'
            '<div class="flex items-center gap-2.5 border-t p-3">'
            f'<span class="avatar bg-primary text-primary-foreground">{e(iniciales)}</span>'
            f'<div class="grid min-w-0 flex-1 leading-tight"><span class="truncate text-sm font-medium">{e(nombre)}</span>'
            f'<span class="truncate text-xs text-muted-foreground">{e(ROLES.get(persona["rol"], persona["rol"]))}</span></div>{salir}</div></aside>')
        cabecera = (
            '<header class="sticky top-0 z-30 flex h-14 items-center gap-2 border-b bg-background/85 px-4 backdrop-blur '
            'supports-[backdrop-filter]:bg-background/70 md:px-6">'
            f'<span class="md:hidden">{logo("size-7", "Helpert")}</span>'
            '<nav class="flex min-w-0 flex-1 gap-0.5 overflow-x-auto [scrollbar-width:none] md:hidden" aria-label="Secciones">'
            + "".join(enlace(*x, movil=True) for x in enlaces + gestion) + '</nav>'
            '<div class="hidden items-center gap-2 text-sm md:flex"><span class="text-muted-foreground">Consola</span>'
            f'<span class="text-muted-foreground/60">/</span><span class="font-medium">{e(titulo)}</span></div>'
            f'<div class="ml-auto md:hidden">{salir}</div></header>')
        return (f'<div class="flex min-h-svh">{lateral}<div class="flex min-w-0 flex-1 flex-col">{cabecera}'
                f'<main class="mx-auto w-full max-w-[112rem] flex-1 space-y-6 p-4 md:p-6 lg:p-8">{emergencia(persona)}{cuerpo}</main></div></div>')

    def persona_de(request: Request, *roles):
        token = request.cookies.get(COOKIE, "")
        with db.conexion(dsn) as c:
            p = c.execute("SELECT u.id, u.email, u.nombre, u.rol, u.empresa_id, e.nombre AS empresa FROM sesiones s "
                          "JOIN usuarios_consola u ON u.id = s.usuario_id LEFT JOIN empresas e ON e.id = u.empresa_id "
                          "WHERE s.token_sha = %s AND s.expira > now() AND u.activo AND coalesce(e.activa, true)",
                          (db.sha(token),)).fetchone() if token else None
        if not p:
            raise HTTPException(303, headers={"Location": "/consola/login"})
        if roles and p["rol"] not in roles:
            raise HTTPException(403, "Tu rol no tiene acceso a esta página")
        p["csrf"] = hashlib.sha256(f"csrf:{token}".encode()).hexdigest()[:32]  # atado a la sesión, para los formularios
        p["sesion_sha"] = db.sha(token)
        return p

    def alc(p, columna):
        """Condición SQL del alcance de la persona: todo (plataforma) o solo su empresa. El id viene de la base."""
        return "TRUE" if p["empresa_id"] is None else f"{columna} = {int(p['empresa_id'])}"

    def de_alcance(c, p, caso_id):
        """El caso, solo si está en el alcance de la persona; si no, 404 (no se revela que existe)."""
        k = c.execute(f"SELECT k.*, q.nombre AS equipo, q.remoto, q.sede AS equipo_sede, q.area, q.piso, "
                      f"e.nombre AS empresa, e.sla_n2_min, e.sla_n3_min, pe.email AS persona_email, pe.nombre AS persona_nombre, "
                      f"pe.telefono AS persona_telefono, pe.sede AS persona_sede, u.nombre AS asignado, u.email AS asignado_email "
                      f"FROM casos k JOIN equipos q ON q.id = k.equipo_id LEFT JOIN empresas e ON e.id = k.empresa_id "
                      f"LEFT JOIN personas pe ON pe.id = k.persona_id LEFT JOIN usuarios_consola u ON u.id = k.asignado_id "
                      f"WHERE k.id = %s AND {alc(p, 'k.empresa_id')}", (caso_id,)).fetchone()
        if not k:
            raise HTTPException(404, "Caso no encontrado")
        return k

    def empresas_de(c, p):
        """Empresas que la persona puede elegir en los filtros (las de la plataforma: todas)."""
        return c.execute(f"SELECT id, nombre FROM empresas WHERE {alc(p, 'id')} ORDER BY nombre").fetchall()

    def crear_sesion(usuario_id: int, request: Request) -> Response:
        token = secrets.token_urlsafe(32)
        with db.conexion(dsn) as c:
            c.execute("DELETE FROM sesiones WHERE expira < now()")
            c.execute("INSERT INTO sesiones (token_sha, usuario_id, expira) VALUES (%s, %s, %s)",
                      (db.sha(token), usuario_id, db.ahora() + timedelta(hours=aj()["sesion_horas"])))
            c.execute("UPDATE usuarios_consola SET ultimo_acceso = now() WHERE id = %s", (usuario_id,))
        r = RedirectResponse("/consola", 303)
        r.set_cookie(COOKIE, token, max_age=aj()["sesion_horas"] * 3600, httponly=True, samesite="strict",
                     secure=request.url.scheme == "https", path="/")
        return r

    @app.get("/", include_in_schema=False)
    def raiz():
        return RedirectResponse("/consola", 303)

    def form_login(mensaje=""):
        aviso = (f'<div class="alerta alerta-peligro" role="alert">{icono("alerta")}<p>{e(mensaje)}</p></div>'
                 if mensaje else "")
        return (
            '<div class="flex min-h-svh flex-col items-center justify-center gap-6 bg-muted/50 p-6 md:p-10">'
            '<div class="flex w-full max-w-sm flex-col gap-6">'
            f'<div class="flex items-center gap-2.5 self-center">{logo("size-11")}'
            '<span class="text-lg font-semibold tracking-tight">Helpert</span></div>'
            '<div class="tarjeta"><div class="tarjeta-cab text-center"><h1 class="text-xl font-semibold">Consola de soporte</h1>'
            '<p class="tarjeta-desc">Entra con tu cuenta del Área de Sistemas</p></div>'
            '<div class="tarjeta-cuerpo"><form class="grid gap-5" method="post" action="/consola/login">' + aviso +
            '<div class="grid gap-2"><label class="etiqueta" for="email">Correo</label>'
            '<input class="campo" id="email" name="email" type="email" autocomplete="username" '
            'placeholder="nombre@empresa.pe" required autofocus></div>'
            '<div class="grid gap-2"><label class="etiqueta" for="clave">Contraseña</label>'
            '<input class="campo" id="clave" name="clave" type="password" autocomplete="current-password" required></div>'
            '<button class="btn btn-primario w-full">Entrar</button></form></div></div>'
            '<p class="text-balance text-center text-xs text-muted-foreground">Acceso para analistas N2, técnicos y '
            'gerencia. Las sesiones duran 12 horas.</p></div></div>')

    @app.get("/consola/login", include_in_schema=False)
    def login_get():
        return pagina("Entrar", form_login())

    @app.post("/consola/login", include_in_schema=False)
    async def login_post(request: Request):
        ip = request.client.host if request.client else "?"
        intentos = fallos[ip]
        while intentos and intentos[0] < time.monotonic() - VENTANA:
            intentos.popleft()
        if len(intentos) >= aj()["login_intentos"]:
            return pagina("Entrar", form_login("Demasiados intentos. Espera unos minutos."), estado=429)
        datos = parse_qs((await request.body()).decode(errors="replace"))
        email, clave = (datos.get("email") or [""])[0][:200], (datos.get("clave") or [""])[0][:200]
        uid = await run_in_threadpool(db.verificar_clave, dsn, email, clave)
        if not uid:
            intentos.append(time.monotonic())
            return pagina("Entrar", form_login("Correo o contraseña incorrectos."), estado=401)
        intentos.clear()
        return await run_in_threadpool(crear_sesion, uid, request)

    @app.post("/consola/salir", include_in_schema=False)
    def salir(request: Request):
        token = request.cookies.get(COOKIE, "")
        if token:
            with db.conexion(dsn) as c:
                c.execute("DELETE FROM sesiones WHERE token_sha = %s", (db.sha(token),))
        r = RedirectResponse("/consola/login", 303)
        r.delete_cookie(COOKIE, path="/")
        return r

    @app.get("/consola", include_in_schema=False)
    def casos(request: Request, estado: str = "abiertos", empresa: int = 0, nivel: int = 0, captura: int = 0):
        p = persona_de(request)
        if p["rol"] == "gerencia":
            return RedirectResponse("/consola/metricas", 303)
        estado = estado if estado in ESTADOS else "abiertos"
        filtro = {"abiertos": "k.estado NOT IN ('cerrado', 'escalado')", "todos": "TRUE"}.get(estado, "k.estado = %(e)s")
        # filtros que se suman a la pestaña: empresa (solo la plataforma), nivel y «con captura»
        extra = alc(p, "k.empresa_id") + (" AND k.empresa_id = %(emp)s" if empresa and p["empresa_id"] is None else "")
        extra += " AND k.nivel = %(niv)s" if nivel in NIVEL else ""
        extra += " AND EXISTS (SELECT 1 FROM capturas x WHERE x.caso_id = k.id AND x.acepta)" if captura else ""
        params = {"e": estado, "emp": empresa, "niv": nivel}
        with db.conexion(dsn) as c:
            filas = c.execute(f"SELECT k.*, q.nombre AS equipo, em.nombre AS empresa, pe.email AS persona_email "
                              f"FROM casos k JOIN equipos q ON q.id = k.equipo_id LEFT JOIN empresas em ON em.id = k.empresa_id "
                              f"LEFT JOIN personas pe ON pe.id = k.persona_id "
                              f"WHERE {filtro} AND {extra} ORDER BY k.id DESC LIMIT 500", params).fetchall()
            cuenta = c.execute(
                "SELECT count(*) FILTER (WHERE estado NOT IN ('cerrado', 'escalado')) AS abiertos, "
                "count(*) FILTER (WHERE estado = 'escalado') AS escalado, "
                "count(*) FILTER (WHERE estado = 'cerrado' AND cerrado >= now() - interval '24 hours') AS cerrados_24h, "
                "avg(calificacion) FILTER (WHERE creado >= now() - interval '30 days')::float AS satisfaccion "
                f"FROM casos k WHERE {extra}", params).fetchone()
            empresas = empresas_de(c, p) if p["empresa_id"] is None else []
        actuales = {k: v for k, v in (("empresa", empresa), ("nivel", nivel), ("captura", captura)) if v}

        cifras = ('<div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">'
                  + cifra("Abiertos", str(cuenta["abiertos"]), "Conversando o esperando al usuario", "mensaje", compacta=True)
                  + cifra("Escalados", str(cuenta["escalado"]), "Esperan a soporte (N2 o N3)", "escalar",
                          "text-peligro" if cuenta["escalado"] else "", compacta=True)
                  + cifra("Cerrados en 24 h", str(cuenta["cerrados_24h"]), "Resueltos o cerrados por el usuario", "ok", compacta=True)
                  + cifra("Satisfacción", f'{cuenta["satisfaccion"]:.1f}' if cuenta["satisfaccion"] else "—",
                          "Promedio de 1 a 5, últimos 30 días", "estrella", compacta=True) + '</div>')
        plataforma = p["empresa_id"] is None  # la plataforma ve la columna Empresa
        pestanas = ('<nav class="pestanas" aria-label="Filtrar por estado">' + "".join(
            f'<a class="pestana" href="/consola?{urlencode({"estado": k, **actuales})}"{" aria-current=page" if k == estado else ""}>{t}'
            + (f'<span class="rounded-full bg-muted-foreground/15 px-1.5 text-xs tabular-nums">{cuenta[k]}</span>'
               if k in cuenta else "") + '</a>' for k, t in ESTADOS.items()) + '</nav>')
        herramientas = (
            '<div class="flex flex-wrap items-center gap-2" data-con-js hidden>'
            f'<div class="relative"><span class="pointer-events-none absolute left-2.5 top-2.5 text-muted-foreground">{icono("buscar")}</span>'
            '<input class="campo w-64 pl-8" type="search" data-buscar="tabla-casos" placeholder="Buscar caso, equipo, usuario…" '
            'aria-label="Buscar en los casos"></div>'
            f'<select name="categoria" multiple data-choices data-filtro="tabla-casos:{6 if plataforma else 5}" data-placeholder="Categoría" '
            'aria-label="Filtrar por categoría">'
            + "".join(f'<option value="{e(x)}">{e(x)}</option>' for x in (*aj()["categorias"], "Sin clasificar")) + '</select></div>')
        opcion = lambda v, txt, act: f'<option value="{v}"{" selected" if v == act else ""}>{e(txt)}</option>'
        filtros = (  # en el servidor: funcionan sin JavaScript y se combinan con la pestaña
            f'<form method="get" action="/consola" class="flex flex-wrap items-center gap-2">'
            f'<input type="hidden" name="estado" value="{e(estado)}">'
            + (f'<select class="campo h-8 w-48 py-0 text-sm" name="empresa" aria-label="Empresa">{opcion(0, "Todas las empresas", empresa)}'
               + "".join(opcion(x["id"], x["nombre"], empresa) for x in empresas) + '</select>' if empresas else "")
            + f'<select class="campo h-8 w-40 py-0 text-sm" name="nivel" aria-label="Nivel">{opcion(0, "Todos los niveles", nivel)}'
            + "".join(opcion(n, t_, nivel) for n, (t_, _) in NIVEL.items()) + '</select>'
            + f'<label class="flex items-center gap-2 text-sm"><input type="checkbox" name="captura" value="1"'
            f'{" checked" if captura else ""}> Con captura</label>'
            '<button class="btn btn-borde btn-sm">Filtrar</button>'
            + ('<a class="btn btn-fantasma btn-sm" href="/consola?' + urlencode({"estado": estado}) + '">Quitar filtros</a>'
               if actuales else "") + '</form>')

        def fila(f):
            nota = (f'<span class="inline-flex items-center gap-1 tabular-nums">{icono("estrella", "size-3.5 text-alerta")}'
                    f'{f["calificacion"]}</span>' if f["calificacion"] else '<span class="text-muted-foreground">—</span>')
            categoria = f["categoria"] or "Sin clasificar"
            return (
                f'<tr data-href="/consola/caso/{f["id"]}">'
                f'<td data-order="{f["id"]}"><a class="font-medium underline-offset-4 hover:underline" href="/consola/caso/{f["id"]}">#{f["id"]}</a></td>'
                f'<td data-order="{f["creado"].isoformat()}" class="whitespace-nowrap tabular-nums text-muted-foreground">{fecha(f["creado"])}</td>'
                f'<td><span class="inline-flex items-center gap-1.5 whitespace-nowrap">{icono("equipo", "size-3.5 text-muted-foreground")}{e(f["equipo"])}</span></td>'
                + (f'<td class="whitespace-nowrap text-muted-foreground">{e(f["empresa"])}</td>' if plataforma else "")
                + f'<td class="max-w-60 truncate" title="{e(f["persona_email"] or f["usuario"])}">{e(f["persona_email"] or f["usuario"])}</td>'
                f'<td data-search="{e(ESTADO_CASO.get(f["estado"], (f["estado"],))[0])}"><div class="flex flex-nowrap gap-1">'
                f'{estado_caso(f["estado"], f["resuelto"])}{insignia(*NIVEL[f["nivel"]]) if f["nivel"] > 1 else ""}</div></td>'
                f'<td data-search="{e(categoria)}"><div class="max-w-64 truncate 2xl:max-w-80" title="{e(categoria)}'
                + (f' · {e(f["subcategoria"])}' if f["subcategoria"] else "") + f'"><span class="font-medium">{e(categoria)}</span>'
                + (f' <span class="text-muted-foreground">· {e(f["subcategoria"])}</span>' if f["subcategoria"] else "") + '</div></td>'
                f'<td>{f"<span class=\"codigo\">{e(f["playbook"])}</span>" if f["playbook"] else "<span class=\"text-muted-foreground\">—</span>"}</td>'
                f'<td class="whitespace-nowrap text-xs text-muted-foreground">{e(f["modelo"])}</td>'
                f'<td data-order="{f["calificacion"] or 0}">{nota}</td></tr>')

        cab = "".join(f"<th>{t}</th>" for t in ("Caso", "Abierto", "Equipo", *(("Empresa",) if plataforma else ()), "Persona",
                                                  "Estado", "Categoría", "Playbook", "Modelo", "Nota"))
        if filas:
            tabla = (f'<div class="tabla-caja"><table id="tabla-casos" class="tabla" data-tabla="completa">'
                     f'<thead><tr>{cab}</tr></thead><tbody>{"".join(fila(f) for f in filas)}</tbody></table></div>')
        else:
            tabla = (f'<div class="flex flex-col items-center gap-2 px-6 py-16 text-center">'
                     f'<span class="flex size-10 items-center justify-center rounded-full bg-muted text-muted-foreground">{icono("casos", "size-5")}</span>'
                     f'<p class="font-medium">No hay casos {ESTADOS[estado].lower() if estado != "todos" else ""}</p>'
                     '<p class="text-sm text-muted-foreground">Cuando un equipo pida ayuda, el caso aparece aquí.</p></div>')
        tarjeta_tabla = (f'<div class="tarjeta gap-0 overflow-hidden py-0"><div class="flex flex-wrap items-center gap-3 border-b p-3">'
                         f'{pestanas}{filtros}<div class="ml-auto">{herramientas}</div></div>{tabla}</div>')
        cuerpo = (encabezado("Casos", "Conversaciones de los equipos con Helpert. La página se actualiza cada 20 segundos.")
                  + cifras + tarjeta_tabla)
        return pagina("Casos", cuerpo, p, "casos", refrescar=20, libs=("datatables", "choices"))

    @app.get("/consola/caso/{caso_id}", include_in_schema=False)
    def caso(request: Request, caso_id: int, aviso: str = ""):
        p = persona_de(request, *SOPORTE)
        with db.conexion(dsn) as c:
            k = de_alcance(c, p, caso_id)
            mensajes = c.execute("SELECT * FROM mensajes WHERE caso_id = %s ORDER BY id", (caso_id,)).fetchall()
            trabajos = c.execute("SELECT * FROM trabajos WHERE caso_id = %s ORDER BY id", (caso_id,)).fetchall()
            confirmaciones = c.execute("SELECT * FROM confirmaciones WHERE caso_id = %s ORDER BY id", (caso_id,)).fetchall()
            capturas = c.execute("SELECT id, ts, acepta, tipo, tamano, descripcion, modelo, borrada, datos IS NOT NULL AS hay "
                                 "FROM capturas WHERE caso_id = %s ORDER BY id", (caso_id,)).fetchall()
            visita = c.execute("SELECT v.*, u.nombre AS tecnico, u.email AS tecnico_email FROM visitas v "
                               "LEFT JOIN usuarios_consola u ON u.id = v.tecnico_id WHERE v.caso_id = %s", (caso_id,)).fetchone()
        ve_capturas = puede_ver_capturas(p, visita)

        def mensaje(m):
            if m["rol"] == "usuario":
                avatar = f'<span class="avatar">{icono("usuario", "size-4 text-muted-foreground")}</span>'
                quien, burbuja = e(k["persona_nombre"] or k["persona_email"] or k["usuario"]), "bg-muted"
            elif m["rol"] == "pantalla":
                avatar = f'<span class="avatar">{icono("cursor", "size-4 text-muted-foreground")}</span>'
                quien, burbuja = "Guía en pantalla", "border border-dashed bg-card"
            elif m["rol"] == "captura":
                avatar = f'<span class="avatar">{icono("camara", "size-4 text-muted-foreground")}</span>'
                quien, burbuja = "Captura (descrita por la IA)", "border border-dashed bg-card"
            else:
                avatar = logo("size-8")
                quien, burbuja = "Helpert", "border bg-card"
            return (f'<li class="flex gap-3">{avatar}<div class="min-w-0 flex-1 space-y-1">'
                    f'<div class="flex items-baseline gap-2 text-sm"><span class="font-medium">{quien}</span>'
                    f'<span class="text-xs tabular-nums text-muted-foreground">{fecha(m["ts"])}</span></div>'
                    f'<p class="w-fit max-w-full whitespace-pre-wrap break-words rounded-lg px-3 py-2 text-sm {burbuja}">'
                    f'{e(m["texto"])}</p></div></li>')

        def paso(t):
            salida = "".join(
                f'<div class="space-y-1"><p class="text-xs font-medium text-muted-foreground">{titulo}</p>'
                f'<pre class="max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-md bg-muted p-3 font-mono text-xs">{e(t[campo])}</pre></div>'
                for campo, titulo in (("salida", "Salida"), ("error", "Errores")) if t[campo])
            detalle = (f'<details class="group mt-2"><summary class="cursor-pointer text-xs font-medium text-muted-foreground '
                       f'hover:text-foreground">Ver salida del script</summary><div class="mt-2 space-y-3">{salida}</div></details>'
                       if salida else "")
            return (f'<li class="py-3"><div class="flex flex-wrap items-center gap-2">'
                    f'{insignia(t["paso"], "borde", "terminal")}<span class="codigo">{e(t["playbook"])} {e(t["version"])}</span>'
                    f'{codigo_paso(t["codigo"])}<span class="ml-auto text-xs tabular-nums text-muted-foreground">{fecha(t["creado"])}</span>'
                    f'</div>{detalle}</li>')

        conf = "".join(
            f'<li class="flex gap-3 py-2.5 text-sm">{icono("ok", "mt-0.5 size-4 shrink-0 text-exito")}<div class="min-w-0">'
            f'<p><span class="font-medium">{e(x["usuario"])}</span> confirmó <span class="codigo">{e(x["playbook"])}</span></p>'
            f'<p class="break-words text-xs text-muted-foreground">{e(x["parametros"])} · {fecha(x["ts"])}</p></div></li>'
            for x in confirmaciones)
        confianza = f'{k["confianza"] * 100:.0f} %' if k["confianza"] is not None else None
        ubicacion = " · ".join(x for x in (k["persona_sede"] or k["equipo_sede"], k["piso"] and f'piso {k["piso"]}', k["area"]) if x)
        parametros = k["parametros"] if k["parametros"] not in (None, "", "{}") else None
        # (título, valor crudo, html): las filas sin valor no se muestran, así la ficha no se alarga con guiones
        grupos_d = [
            ("Persona", [("Empresa", k["empresa"], e(k["empresa"])),
                         ("Persona", 1, e(" · ".join(x for x in (k["persona_nombre"], k["persona_email"], k["persona_telefono"]) if x)
                                          or k["usuario"])),
                         ("Ubicación", ubicacion, e(ubicacion)),
                         ("Control remoto", k["remoto"], f'<span class="codigo select-all">{e(k["remoto"])}</span>'),
                         ("Equipo", k["equipo"], f'{e(k["equipo"])} · {e(k["so"])}')]),
            ("Clasificación", [("Nivel", 1, insignia(*NIVEL[k["nivel"]])),
                               ("Asignado a", k["asignado"] or k["asignado_email"], e(k["asignado"] or k["asignado_email"])),
                               ("Tipo", k["tipo"], e(k["tipo"])),
                               ("Categoría", k["categoria"], e(k["categoria"]) + (f' · <span class="text-muted-foreground">'
                                                                                 f'{e(k["subcategoria"])}</span>' if k["subcategoria"] else "")),
                               ("Playbook", k["playbook"], f'<span class="codigo">{e(k["playbook"])}</span>'),
                               ("Parámetros", parametros, f'<span class="break-all font-mono text-xs">{e(parametros)}</span>')]),
            ("IA", [("Modelo", k["modelo"], e(k["modelo"])), ("Confianza", confianza, e(confianza)),
                    ("Uso", k["tokens_entrada"] or k["tokens_salida"],
                     f'{k["tokens_entrada"]:,} / {k["tokens_salida"]:,} tokens · US$ {float(k["costo_usd"]):.4f}')]),
            ("Cierre", [("Abierto", 1, fecha(k["creado"])), ("Cerrado", k["cerrado"], fecha(k["cerrado"])),
                        ("Resuelto", k["resuelto"] is not None, e({True: "Sí", False: "No"}.get(k["resuelto"]))),
                        ("Calificación", k["calificacion"], f'{e(k["calificacion"])} / 5'),
                        ("Comentario", k["comentario"], e(k["comentario"]))])]
        ficha = '<div class="space-y-4">' + "".join(
            f'<div><p class="mb-1 text-xs font-medium text-muted-foreground">{g}</p><dl class="divide-y text-sm">'
            + "".join(f'<div class="grid grid-cols-[7rem_1fr] gap-3 py-1.5"><dt class="text-muted-foreground">{t_}</dt>'
                      f'<dd class="min-w-0 break-words">{v}</dd></div>' for t_, crudo, v in filas_g if crudo not in (None, "", False, 0))
            + '</dl></div>' for g, filas_g in grupos_d) + '</div>'
        nota = (f'<div class="alerta border-alerta/40">{icono("alerta")}<div><p class="font-medium">Nota interna</p>'
                f'<p class="whitespace-pre-wrap break-words text-muted-foreground">{e(k["nota"])}</p></div></div>' if k["nota"] else "")

        def tarjeta(titulo, desc, contenido):
            return (f'<section class="tarjeta gap-4 py-5"><div class="tarjeta-cab px-5"><h2 class="tarjeta-titulo">{titulo}</h2>'
                    f'<p class="tarjeta-desc">{desc}</p></div><div class="tarjeta-cuerpo px-5">{contenido}</div></section>')

        vacio = lambda t: f'<p class="text-sm text-muted-foreground">{t}</p>'

        def captura(x):
            if not x["acepta"]:
                return (f'<li class="flex gap-3 py-2.5 text-sm">{icono("prohibido", "mt-0.5 size-4 shrink-0 text-muted-foreground")}'
                        f'<p>El usuario no dio permiso · {fecha(x["ts"])}</p></li>')
            ver = (f'<a class="btn btn-borde btn-sm" href="/consola/caso/{k["id"]}/captura/{x["id"]}" target="_blank" '
                   f'rel="noopener">{icono("camara")}Ver captura</a>' if x["hay"] and ve_capturas else
                   insignia("Borrada por retención", "neutra") if not x["hay"] else
                   '<span class="text-xs text-muted-foreground">Solo la ven el Analista N2 y el técnico asignado.</span>')
            desc = (f'<p class="whitespace-pre-wrap break-words text-xs text-muted-foreground">{e(x["descripcion"])} '
                    f'({e(x["modelo"])})</p>' if x["descripcion"] else "")
            return (f'<li class="grid gap-2 py-2.5 text-sm"><div class="flex flex-wrap items-center gap-2">'
                    f'{icono("ok", "size-4 text-exito")}<span>Permiso dado · {fecha(x["ts"])} · {(x["tamano"] or 0) / 1024:.0f} KB</span>'
                    f'<span class="ml-auto">{ver}</span></div>{desc}</li>')

        if visita:
            datos_v = [("Estado", insignia(*VISITA[visita["estado"]])), ("Prioridad", e(visita["prioridad"].capitalize())),
                       ("Técnico", e(visita["tecnico"] or visita["tecnico_email"])), ("Llegada estimada", fecha(visita["eta"])),
                       ("Atendida", fecha(visita["atendida"])), ("Notas", e(visita["notas"])), ("Insumos", e(visita["insumos"]))]
            bloque_visita = ('<dl class="divide-y text-sm">' + "".join(
                f'<div class="grid grid-cols-[8.5rem_1fr] gap-3 py-2"><dt class="text-muted-foreground">{t}</dt>'
                f'<dd class="min-w-0 break-words">{v}</dd></div>' for t, v in datos_v) + '</dl>'
                f'<a class="btn btn-borde btn-sm mt-3" href="/consola/visitas#v{visita["id"]}">{icono("visitas")}Ir a la cola</a>')
        elif p["rol"] in JEFES and k["estado"] == "escalado":
            bloque_visita = ('<p class="mb-3 text-sm text-muted-foreground">Si necesita presencia (tóner, papel, hardware), '
                             'pide la visita de un técnico.</p>' + boton_post(p, f"/consola/caso/{k['id']}/visita",
                                                                             icono("visitas") + "Enviar un técnico", "btn-borde"))
        else:
            bloque_visita = vacio("Sin visita.")
        # Atención humana: N2 toma el caso, lo pasa a N3 o lo resuelve (la persona confirma y califica en la bandeja)
        humano = ""
        if k["estado"] == "escalado":
            sla = k["sla_n3_min"] if k["nivel"] >= 3 else k["sla_n2_min"]
            vence = k["escalado"] + timedelta(minutes=sla) if k["escalado"] and sla else None
            humano = (f'<p class="mb-3 text-sm">{insignia(*NIVEL[k["nivel"]])} '
                      + (f'Responder antes de {fecha(vence)}' + (" · " + insignia("Vencido", "peligro") if vence < db.ahora() else "")
                         if vence else "") + '</p><div class="flex flex-wrap gap-2">')
            if k["asignado_id"] != p["id"]:
                humano += boton_post(p, f"/consola/caso/{k['id']}/tomar", icono("usuario") + "Tomar el caso")
            if k["nivel"] < 3 and p["rol"] != "gerencia":
                humano += boton_post(p, f"/consola/caso/{k['id']}/n3", icono("escalar") + "Pasar a N3", "btn-borde",
                                     "¿Pasar el caso al Analista N3?")
            humano += (f'</div><form method="post" action="/consola/caso/{k["id"]}/resolver" class="mt-4 grid gap-2">{csrf(p)}'
                       f'<label class="etiqueta" for="solucion">Qué se hizo</label>'
                       f'<textarea class="campo min-h-20" id="solucion" name="solucion" maxlength="1000" required '
                       f'placeholder="Lo que la persona verá en Helpert, p. ej. «Reinstalé el controlador de la impresora»"></textarea>'
                       f'<div><button class="btn btn-primario">{icono("ok")}Marcar resuelto</button></div></form>')
        avisos_caso = {"tomar": "Tomaste el caso.", "n3": "Caso pasado al Analista N3.",
                       "resolver": "Listo: Helpert le pide a la persona que confirme y califique."}
        aviso_html = (f'<div class="alerta border-primary/30 bg-primario-suave/40 text-sobre-primario-suave" role="status">'
                      f'{icono("ok")}<p>{e(avisos_caso[aviso])}</p></div>' if aviso in avisos_caso else "")
        cuerpo = (
            f'<a href="/consola" class="btn btn-fantasma btn-sm -ml-3 text-muted-foreground">{icono("atras")}Casos</a>'
            + encabezado(f'Caso #{k["id"]} {estado_caso(k["estado"], k["resuelto"])}',
                         f'{icono("equipo", "inline size-3.5 -mt-0.5")} {e(k["equipo"])} · {e(k["persona_email"] or k["usuario"])} · '
                         f'abierto el {fecha(k["creado"])}')
            + aviso_html + nota
            # dos columnas: lo que pasó (ancha) y qué hacer y quién es (angosta); lo vacío ocupa una línea
            + '<div class="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_22rem] 2xl:grid-cols-[minmax(0,1fr)_26rem]">'
            + '<div class="min-w-0 space-y-6">'
            + tarjeta("Conversación", f"{len(mensajes)} mensajes entre el usuario y Helpert.",
                      f'<ol class="space-y-5">{"".join(mensaje(m) for m in mensajes)}</ol>' if mensajes else vacio("Sin mensajes."))
            + tarjeta("Pasos ejecutados", "Lo que el servicio del equipo corrió, con su código de salida.",
                      f'<ol class="-my-3 divide-y">{"".join(paso(t) for t in trabajos)}</ol>' if trabajos else vacio("Ningún paso."))
            + '<div class="grid items-start gap-6 xl:grid-cols-2">'
            + tarjeta("Confirmaciones del usuario", "Nada se aplica sin una de estas.",
                      f'<ul class="-my-2.5 divide-y">{conf}</ul>' if conf else vacio("Ninguna."))
            + tarjeta("Capturas", "Evidencia con permiso del usuario; cada vista queda en la auditoría.",
                      f'<ul class="-my-2.5 divide-y">{"".join(captura(x) for x in capturas)}</ul>' if capturas else vacio("Ninguna."))
            + '</div></div><div class="min-w-0 space-y-6">'
            + (tarjeta("Atención de soporte", "N2 atiende por control remoto o en persona; N3, lo que N2 no resuelve.", humano)
               if humano else "")
            + tarjeta("Detalle", "Persona, clasificación de la IA y cierre.", ficha)
            + tarjeta("Atención física", "Visita de un técnico de campo.", bloque_visita)
            + '</div></div>')
        return pagina(f"Caso #{caso_id}", cuerpo, p, "casos")

    VISITA = {"pendiente": ("Por asignar", "peligro"), "asignada": ("Asignada", "alerta"), "atendida": ("Atendida", "exito"),
              "cancelada": ("Cancelada", "neutra")}
    PRIORIDAD = {"alta": "peligro", "media": "alerta", "baja": "neutra"}

    def puede_ver_capturas(p, visita):
        """Plan: solo el analista y el técnico asignado (más Administración), dentro de su alcance."""
        return p["rol"] in JEFES or (p["rol"] == "tecnico" and bool(visita) and visita["tecnico_id"] == p["id"])

    @app.get("/consola/caso/{caso_id}/captura/{cid}", include_in_schema=False)
    def ver_captura(request: Request, caso_id: int, cid: int):
        p = persona_de(request, *SOPORTE)
        with db.conexion(dsn) as c:
            de_alcance(c, p, caso_id)
            x = c.execute("SELECT tipo, datos FROM capturas WHERE id = %s AND caso_id = %s AND datos IS NOT NULL",
                          (cid, caso_id)).fetchone()
            visita = c.execute("SELECT tecnico_id FROM visitas WHERE caso_id = %s", (caso_id,)).fetchone()
            if not x or not puede_ver_capturas(p, visita):
                raise HTTPException(404, "Captura no encontrada")
            db.auditar(c, p["email"], "Vio una captura", f"caso #{caso_id} · captura {cid}")
        return Response(bytes(x["datos"]), media_type=x["tipo"],
                        headers={"Cache-Control": "no-store", "Content-Disposition": f'inline; filename="caso-{caso_id}.img"'})

    @app.get("/consola/visitas", include_in_schema=False)
    def visitas(request: Request, aviso: str = ""):
        p = persona_de(request, *SOPORTE)
        jefe = p["rol"] in JEFES
        with db.conexion(dsn) as c:
            filas = c.execute(
                "SELECT v.*, k.categoria, k.subcategoria, coalesce(pe.email, k.usuario) AS usuario, k.estado AS caso_estado, "
                "k.empresa_id, em.nombre AS empresa, q.nombre AS equipo, q.area, coalesce(pe.sede, q.sede) AS sede, "
                "q.piso, u.nombre AS tecnico, u.email AS tecnico_email FROM visitas v JOIN casos k ON k.id = v.caso_id "
                "JOIN equipos q ON q.id = k.equipo_id LEFT JOIN usuarios_consola u ON u.id = v.tecnico_id "
                "LEFT JOIN personas pe ON pe.id = k.persona_id LEFT JOIN empresas em ON em.id = k.empresa_id "
                f"WHERE {alc(p, 'k.empresa_id')} AND (%s OR v.tecnico_id = %s) "
                "AND (v.estado IN ('pendiente', 'asignada') OR v.creado > now() - interval '7 days') "
                "ORDER BY v.estado IN ('atendida', 'cancelada'), CASE v.prioridad WHEN 'alta' THEN 0 WHEN 'media' THEN 1 ELSE 2 END, "
                "v.creado", (jefe, p["id"])).fetchall()
            # técnicos de la empresa del caso o de la plataforma (empresa vacía)
            todos = c.execute("SELECT id, coalesce(nombre, email) AS nombre, empresa_id FROM usuarios_consola WHERE rol = 'tecnico' "
                              f"AND activo AND (empresa_id IS NULL OR {alc(p, 'empresa_id')}) ORDER BY 2").fetchall() if jefe else []
        tecnicos_de = lambda v: [x for x in todos if x["empresa_id"] in (None, v["empresa_id"])]
        sel = lambda nombre, ops, actual, etiqueta, id_: (
            f'<div class="grid content-start gap-2"><label class="etiqueta" for="{id_}">{etiqueta}</label>'
            f'<select class="campo" id="{id_}" name="{nombre}">' + "".join(
                f'<option value="{v}"{" selected" if str(v) == str(actual) else ""}>{e(t)}</option>' for v, t in ops) + '</select></div>')

        def tarjeta_visita(v):
            ubicacion = " · ".join(x for x in (v["sede"], f'piso {v["piso"]}' if v["piso"] else "", v["area"]) if x) or "Ubicación sin registrar"
            acciones = ""
            tecnicos = tecnicos_de(v)
            if jefe and v["estado"] in ("pendiente", "asignada"):
                acciones += (
                    f'<form method="post" action="/consola/visitas/{v["id"]}/asignar" class="grid gap-3 sm:grid-cols-4 sm:items-end">{csrf(p)}'
                    + sel("tecnico", [(t["id"], t["nombre"]) for t in tecnicos] or [("", "No hay técnicos activos")],
                          v["tecnico_id"], "Técnico", f"t{v['id']}")
                    + sel("minutos", [(15, "15 min"), (30, "30 min"), (60, "1 hora"), (120, "2 horas"), (240, "4 horas"),
                                      (480, "Hoy"), (1440, "Mañana")], 60, "Llega en", f"m{v['id']}")
                    + sel("prioridad", [("alta", "Alta"), ("media", "Media"), ("baja", "Baja")], v["prioridad"], "Prioridad", f"p{v['id']}")
                    + f'<button class="btn btn-primario"{" disabled" if not tecnicos else ""}>'
                    f'{"Reasignar" if v["estado"] == "asignada" else "Asignar"}</button></form>')
            if v["estado"] == "asignada" and (jefe or v["tecnico_id"] == p["id"]):
                acciones += (
                    f'<form method="post" action="/consola/visitas/{v["id"]}/atender" class="grid gap-3">{csrf(p)}'
                    f'<div class="grid gap-2"><label class="etiqueta" for="n{v["id"]}">Qué se hizo</label>'
                    f'<textarea class="campo min-h-20" id="n{v["id"]}" name="notas" maxlength="1000" required></textarea></div>'
                    f'<div class="grid gap-2"><label class="etiqueta" for="i{v["id"]}">Insumos usados</label>'
                    f'<input class="campo" id="i{v["id"]}" name="insumos" maxlength="300" placeholder="p. ej. 1 cartucho de tóner"></div>'
                    f'<div><button class="btn btn-primario">{icono("ok")}Marcar atendida</button></div></form>')
            if jefe and v["estado"] in ("pendiente", "asignada"):
                acciones += boton_post(p, f'/consola/visitas/{v["id"]}/cancelar', "Cancelar visita", "btn-fantasma text-peligro",
                                       "¿Cancelar la visita? El caso sigue escalado.")
            hecho = (f'<p class="text-sm"><span class="font-medium">Atendida:</span> {e(v["notas"])}'
                     f'{" · Insumos: " + e(v["insumos"]) if v["insumos"] else ""}</p>' if v["estado"] == "atendida" else "")
            return (f'<article id="v{v["id"]}" class="tarjeta gap-4 py-5"><div class="flex flex-wrap items-start justify-between gap-3 px-5">'
                    f'<div class="min-w-0 space-y-1"><p class="flex flex-wrap items-center gap-2 font-medium">'
                    f'<a class="underline-offset-4 hover:underline" href="/consola/caso/{v["caso_id"]}">Caso #{v["caso_id"]}</a>'
                    f'{insignia(*VISITA[v["estado"]])}{insignia("Prioridad " + v["prioridad"], PRIORIDAD[v["prioridad"]])}</p>'
                    f'<p class="text-sm text-muted-foreground">{icono("visitas", "inline size-3.5 -mt-0.5")} {e(ubicacion)} · '
                    f'{icono("equipo", "inline size-3.5 -mt-0.5")} {e(v["equipo"])} · {e(v["usuario"])}</p>'
                    f'<p class="text-sm">{e(v["categoria"])} · {e(v["subcategoria"])}'
                    + (f' · <span class="text-muted-foreground">{e(v["empresa"])}</span>' if p["empresa_id"] is None else "")
                    + '</p></div>'
                    f'<div class="text-right text-xs text-muted-foreground"><p>Pedida {fecha(v["creado"])}</p>'
                    + (f'<p>{e(v["tecnico"] or v["tecnico_email"])} · llega {fecha(v["eta"])}</p>' if v["tecnico_id"] else "")
                    + f'</div></div><div class="grid gap-4 px-5">{hecho}{acciones}</div></article>')

        mensajes_v = {"asignada": "Visita asignada. El usuario recibe el aviso en Helpert.",
                      "atendida": "Visita atendida. Helpert le pregunta al usuario si se resolvió.",
                      "cancelada": "Visita cancelada.", "creada": "Visita creada: falta asignarla."}
        aviso_html = (f'<div class="alerta border-primary/30 bg-primario-suave/40 text-sobre-primario-suave" role="status">'
                      f'{icono("ok")}<p>{e(mensajes_v[aviso])}</p></div>' if aviso in mensajes_v else "")
        lista = "".join(tarjeta_visita(v) for v in filas) or (
            '<p class="rounded-xl border border-dashed p-10 text-center text-sm text-muted-foreground">'
            + ("No hay visitas abiertas." if jefe else "No tienes visitas asignadas.") + '</p>')
        cuerpo = (encabezado("Atención física", "Visitas de técnicos de campo: tóner, papel, hardware. "
                             + ("Asigna cada visita a un técnico; el usuario recibe el aviso en Helpert." if jefe
                                else "Tus visitas asignadas; ciérralas aquí al terminar."))
                  + aviso_html + f'<div class="grid gap-4">{lista}</div>')
        return pagina("Atención física", cuerpo, p, "visitas")  # sin recarga: el técnico escribe sus notas aquí

    def aviso_equipo(c, caso_id, texto, cierre=False):
        c.execute("INSERT INTO avisos (equipo_id, caso_id, texto, cierre) SELECT equipo_id, id, %s, %s FROM casos WHERE id = %s",
                  (texto, cierre, caso_id))

    def accion_visita(p, vid, accion, d):
        with db.conexion(dsn) as c:
            v = c.execute(f"SELECT v.*, k.empresa_id FROM visitas v JOIN casos k ON k.id = v.caso_id WHERE v.id = %s "
                          f"AND {alc(p, 'k.empresa_id')} FOR UPDATE OF v", (vid,)).fetchone()
            if not v:
                raise HTTPException(404, "Visita no encontrada")
            jefe = p["rol"] in JEFES
            if accion == "asignar" and jefe and v["estado"] in ("pendiente", "asignada"):
                tid = int(d.get("tecnico")) if str(d.get("tecnico", "")).isdigit() else 0
                t = c.execute("SELECT id, coalesce(nombre, email) AS nombre FROM usuarios_consola WHERE id = %s AND rol = 'tecnico' "
                              "AND activo AND (empresa_id IS NULL OR empresa_id = %s)", (tid, v["empresa_id"])).fetchone()
                minutos = int(d.get("minutos", 60)) if d.get("minutos", "").isdigit() else 60
                if not t or not 5 <= minutos <= 2880 or d.get("prioridad") not in PRIORIDAD:
                    raise HTTPException(422, "Revisa el técnico, el tiempo y la prioridad")
                c.execute("UPDATE visitas SET estado = 'asignada', tecnico_id = %s, prioridad = %s, asignada = now(), "
                          "eta = now() + make_interval(mins => %s) WHERE id = %s", (t["id"], d["prioridad"], minutos, vid))
                cuando = "hoy" if minutos == 480 else "mañana" if minutos == 1440 else (
                    f"unos {minutos} minutos" if minutos < 60 else f"unas {minutos // 60} hora{'s' if minutos >= 120 else ''}")
                aviso_equipo(c, v["caso_id"], f"{t['nombre']} pasará por tu puesto por el caso #{v['caso_id']}: llega en {cuando}.")
                db.auditar(c, p["email"], "Asignó una visita", f"caso #{v['caso_id']} → {t['nombre']} ({minutos} min)")
            elif accion == "atender" and v["estado"] == "asignada" and (jefe or v["tecnico_id"] == p["id"]):
                notas = d.get("notas", "").strip()[:1000]
                if not notas:
                    raise HTTPException(422, "Cuenta qué se hizo")
                c.execute("UPDATE visitas SET estado = 'atendida', atendida = now(), notas = %s, insumos = %s WHERE id = %s",
                          (notas, d.get("insumos", "").strip()[:300] or None, vid))
                # El usuario califica desde la bandeja, igual que una atención remota.
                c.execute("UPDATE casos SET estado = 'esperando_cierre' WHERE id = %s AND estado = 'escalado'", (v["caso_id"],))
                aviso_equipo(c, v["caso_id"], f"El técnico terminó la visita del caso #{v['caso_id']}.", cierre=True)
                db.auditar(c, p["email"], "Atendió una visita", f"caso #{v['caso_id']}")
            elif accion == "cancelar" and jefe and v["estado"] in ("pendiente", "asignada"):
                c.execute("UPDATE visitas SET estado = 'cancelada' WHERE id = %s", (vid,))
                db.auditar(c, p["email"], "Canceló una visita", f"caso #{v['caso_id']}")
            else:
                raise HTTPException(403, "Esa acción no está disponible")
        return RedirectResponse(f"/consola/visitas?aviso={ {'asignar': 'asignada', 'atender': 'atendida', 'cancelar': 'cancelada'}[accion] }#v{vid}", 303)

    @app.post("/consola/visitas/{vid}/{accion}", include_in_schema=False)
    async def visita_post(request: Request, vid: int, accion: str):
        p, d = await formulario(request, SOPORTE)
        return await run_in_threadpool(accion_visita, p, vid, accion, d)

    @app.post("/consola/caso/{caso_id}/visita", include_in_schema=False)
    async def visita_nueva(request: Request, caso_id: int):
        p, _ = await formulario(request, JEFES)

        def crear():
            with db.conexion(dsn) as c:
                de_alcance(c, p, caso_id)
                if not c.execute("INSERT INTO visitas (caso_id, estado, persona) SELECT id, 'pendiente', %s FROM casos "
                                 "WHERE id = %s ON CONFLICT (caso_id) DO NOTHING", (p["email"], caso_id)).rowcount:
                    raise HTTPException(409, "Ese caso ya tiene una visita")
                db.auditar(c, p["email"], "Pidió una visita", f"caso #{caso_id}")
            return RedirectResponse("/consola/visitas?aviso=creada", 303)
        return await run_in_threadpool(crear)

    def accion_caso(p, caso_id, accion, d):
        with db.conexion(dsn) as c:
            k = de_alcance(c, p, caso_id)
            if k["estado"] != "escalado":
                raise HTTPException(409, "El caso ya no está escalado")
            if accion == "tomar":
                c.execute("UPDATE casos SET asignado_id = %s WHERE id = %s", (p["id"], caso_id))
                db.auditar(c, p["email"], "Tomó un caso", f"caso #{caso_id}")
            elif accion == "n3" and k["nivel"] < 3:
                c.execute("UPDATE casos SET nivel = 3, escalado = now(), asignado_id = NULL WHERE id = %s", (caso_id,))
                db.auditar(c, p["email"], "Pasó un caso a N3", f"caso #{caso_id}")
            elif accion == "resolver":
                solucion = d.get("solucion", "").strip()[:1000]
                if not solucion:
                    raise HTTPException(422, "Cuenta qué se hizo")
                c.execute("INSERT INTO mensajes (caso_id, rol, texto) VALUES (%s, 'helpert', %s)",
                          (caso_id, f"Soporte ({p['nombre'] or p['email']}): {solucion}"))
                c.execute("UPDATE casos SET estado = 'esperando_cierre', asignado_id = coalesce(asignado_id, %s) WHERE id = %s",
                          (p["id"], caso_id))
                aviso_equipo(c, caso_id, f"Soporte trabajó en tu caso #{caso_id}: {solucion}", cierre=True)
                db.auditar(c, p["email"], "Resolvió un caso", f"caso #{caso_id}")
            else:
                raise HTTPException(403, "Esa acción no está disponible")
        return RedirectResponse(f"/consola/caso/{caso_id}?aviso={accion}", 303)

    @app.post("/consola/caso/{caso_id}/{accion}", include_in_schema=False)
    async def caso_post(request: Request, caso_id: int, accion: str):
        p, d = await formulario(request, SOPORTE)
        return await run_in_threadpool(accion_caso, p, caso_id, accion, d)

    PANELES = {"metas": "Metas del piloto", "graficos": "Casos por fecha y resultado", "categorias": "Por categoría",
               "empresas": "Por empresa", "niveles": "Por nivel (N1, N2, N3)", "personas": "Personas con más consultas",
               "subcategorias": "Subcategorías", "sedes": "Por sede", "playbooks": "Por playbook", "modelos": "Por modelo de IA"}

    def filtro_casos(p, dias, empresa, sede, categoria):
        """CTE «base»: los casos del período en el alcance de la persona y con los filtros elegidos."""
        cond = [f"k.creado >= now() - make_interval(days => %(d)s)", alc(p, "k.empresa_id")]
        if empresa and p["empresa_id"] is None:
            cond.append("k.empresa_id = %(emp)s")
        if sede:
            cond.append("coalesce(pe.sede, q.sede) = %(sede)s")
        if categoria:
            cond.append("coalesce(k.categoria, 'Sin clasificar') = %(cat)s")
        cte = ("WITH base AS (SELECT k.*, coalesce(pe.sede, q.sede) AS sede_x, pe.email AS persona_email, "
               "em.nombre AS empresa_nombre, em.sla_n2_min, em.sla_n3_min, q.nombre AS equipo_nombre FROM casos k "
               "JOIN equipos q ON q.id = k.equipo_id LEFT JOIN personas pe ON pe.id = k.persona_id "
               f"LEFT JOIN empresas em ON em.id = k.empresa_id WHERE {' AND '.join(cond)}) ")
        return cte, {"d": dias, "emp": empresa, "sede": sede, "cat": categoria}

    def filtros_de(request: Request):
        q = request.query_params
        dias = int(q["dias"]) if q.get("dias", "").isdigit() and int(q["dias"]) in (7, 30, 90, 365) else 30
        empresa = int(q["empresa"]) if q.get("empresa", "").isdigit() else 0
        return dias, empresa, q.get("sede", "")[:120], q.get("categoria", "")[:60]

    @app.get("/consola/metricas/casos.csv", include_in_schema=False)
    def metricas_csv(request: Request):
        """Los casos del período con los mismos filtros, para Excel o una herramienta de BI."""
        p = persona_de(request)
        cte, params = filtro_casos(p, *filtros_de(request))
        with db.conexion(dsn) as c:
            filas = c.execute(cte + "SELECT id, creado, cerrado, empresa_nombre, coalesce(persona_email, usuario) AS persona, "
                              "equipo_nombre, sede_x, nivel, estado, tipo, categoria, subcategoria, playbook, modelo, resuelto, "
                              "calificacion, tokens_entrada, tokens_salida, costo_usd FROM base ORDER BY id", params).fetchall()
            db.auditar(c, p["email"], "Exportó casos", f"{len(filas)} filas · {dict(request.query_params)}"[:500])
        import csv
        import io
        z = zona()
        sale = io.StringIO()
        w = csv.writer(sale)
        w.writerow(["caso", "abierto", "cerrado", "empresa", "persona", "equipo", "sede", "nivel", "estado", "tipo", "categoria",
                    "subcategoria", "playbook", "modelo", "resuelto", "calificacion", "tokens_entrada", "tokens_salida", "costo_usd"])
        limpio = lambda v: ("'" + v if isinstance(v, str) and v[:1] in "=+-@\t\r" else v)  # sin fórmulas en Excel
        for f in filas:
            w.writerow([limpio(v.astimezone(z).strftime("%Y-%m-%d %H:%M") if isinstance(v, datetime) else v)
                        for v in f.values()])
        return Response("﻿" + sale.getvalue(), media_type="text/csv; charset=utf-8",
                        headers={"Content-Disposition": 'attachment; filename="helpert-casos.csv"', "Cache-Control": "no-store"})

    @app.get("/consola/metricas", include_in_schema=False)
    def metricas(request: Request):
        p = persona_de(request)
        dias, empresa, sede, categoria = filtros_de(request)
        pedidos = [x for x in request.query_params.getlist("panel") if x in PANELES]
        paneles = set(pedidos) if pedidos else set(PANELES)  # sin elección: todos
        unidad = "month" if dias == 365 else "day"
        cte, prm = filtro_casos(p, dias, empresa, sede, categoria)
        una_empresa = bool(p["empresa_id"] or empresa)
        with db.conexion(dsn) as c:
            g = c.execute(cte + """
                SELECT count(*) AS total,
                  count(*) FILTER (WHERE estado = 'cerrado' AND resuelto) AS resueltos,
                  count(*) FILTER (WHERE estado = 'cerrado' AND resuelto AND nivel = 1) AS resueltos_n1,
                  count(*) FILTER (WHERE estado = 'cerrado' AND resuelto IS NOT TRUE) AS sin_resolver,
                  count(*) FILTER (WHERE estado = 'cerrado' AND calificacion IS NULL) AS sin_calificar,
                  count(*) FILTER (WHERE estado = 'cerrado') AS cerrados,
                  count(*) FILTER (WHERE estado = 'escalado') AS escalados,
                  count(*) FILTER (WHERE nivel > 1) AS con_humano,
                  count(*) FILTER (WHERE estado = 'escalado' AND escalado + make_interval(mins =>
                    CASE WHEN nivel >= 3 THEN coalesce(sla_n3_min, 1440) ELSE coalesce(sla_n2_min, 240) END) < now()) AS vencidos,
                  count(*) FILTER (WHERE estado NOT IN ('cerrado', 'escalado')) AS abiertos,
                  count(DISTINCT coalesce(persona_email, usuario)) AS personas,
                  coalesce(sum(costo_usd), 0)::float AS costo,
                  avg(calificacion)::float AS satisfaccion,
                  (avg(extract(epoch FROM cerrado - creado)) FILTER (WHERE estado = 'cerrado'))::float / 60 AS minutos
                FROM base""", prm).fetchone()
            reabiertos = c.execute(cte + """
                SELECT count(*) AS n FROM base k WHERE EXISTS (
                  SELECT 1 FROM casos p WHERE p.equipo_id = k.equipo_id AND p.usuario = k.usuario
                  AND p.subcategoria = k.subcategoria AND p.estado = 'cerrado' AND p.resuelto
                  AND p.cerrado < k.creado AND p.cerrado >= k.creado - interval '7 days')""", prm).fetchone()["n"]
            acciones = c.execute(cte + """
                SELECT count(*) FILTER (WHERE t.paso = 'aplicar') AS aplicadas, count(*) FILTER (WHERE t.paso = 'deshacer') AS deshechas
                FROM trabajos t JOIN base k ON k.id = t.caso_id""", prm).fetchone()
            por_dia = c.execute(cte + """
                SELECT date_trunc(%(u)s, creado AT TIME ZONE %(z)s)::date AS dia, count(*) AS total,
                  count(*) FILTER (WHERE estado = 'cerrado' AND resuelto) AS resueltos,
                  count(*) FILTER (WHERE estado = 'escalado') AS escalados
                FROM base GROUP BY 1 ORDER BY 1""", {**prm, "u": unidad, "z": str(zona())}).fetchall()
            agrupar = lambda expr, orden="2 DESC", limite=50: c.execute(cte + f"""
                SELECT {expr} AS nombre, count(*) AS total,
                  count(*) FILTER (WHERE estado = 'cerrado' AND resuelto) AS resueltos,
                  count(*) FILTER (WHERE estado = 'escalado') AS escalados,
                  round(avg(calificacion)::numeric, 1) AS satisfaccion, round(sum(costo_usd)::numeric, 2) AS costo
                FROM base GROUP BY 1 ORDER BY {orden} LIMIT {limite}""", prm).fetchall()
            por_cat = agrupar("coalesce(categoria, 'Sin clasificar')")
            por_sub = agrupar("coalesce(categoria, 'Sin clasificar') || ' · ' || coalesce(subcategoria, '—')", limite=15)
            por_sede = agrupar("coalesce(sede_x, 'Sin sede')")
            por_nivel = agrupar("nivel", "1")
            personas = c.execute(cte + """
                SELECT coalesce(persona_email, usuario) AS nombre, max(empresa_nombre) AS empresa, count(*) AS total,
                  count(*) FILTER (WHERE nivel > 1) AS escalados, round(avg(calificacion)::numeric, 1) AS satisfaccion,
                  max(creado) AS ultimo
                FROM base GROUP BY 1 ORDER BY 3 DESC LIMIT 15""", prm).fetchall()
            por_empresa = agrupar("coalesce(empresa_nombre, 'Sin empresa')") if not una_empresa else []
            cruce = c.execute(cte + """
                SELECT coalesce(empresa_nombre, 'Sin empresa') AS empresa, coalesce(categoria, 'Sin clasificar') AS categoria,
                  count(*) AS n FROM base GROUP BY 1, 2""", prm).fetchall() if not una_empresa else []
            por_pb = c.execute(cte + """
                SELECT t.playbook AS nombre, count(*) FILTER (WHERE t.paso = 'diagnosticar') AS diagnosticos,
                  count(*) FILTER (WHERE t.paso = 'aplicar') AS aplicados,
                  count(*) FILTER (WHERE t.paso = 'verificar' AND t.codigo = 0) AS verificados,
                  count(*) FILTER (WHERE t.codigo NOT IN (0, 10)) AS fallos
                FROM trabajos t JOIN base k ON k.id = t.caso_id GROUP BY 1 ORDER BY 2 DESC""", prm).fetchall()
            por_modelo = c.execute(cte + """
                SELECT coalesce(modelo, 'Sin IA (menú)') AS nombre, count(*) AS total,
                  count(*) FILTER (WHERE nota IS NOT NULL AND modelo IS NOT NULL) AS con_incidencia,
                  round(sum(costo_usd)::numeric, 4) AS costo
                FROM base GROUP BY 1 ORDER BY 2 DESC""", prm).fetchall()
            empresas = empresas_de(c, p) if p["empresa_id"] is None else []
            sedes = c.execute(f"SELECT DISTINCT nombre FROM sedes WHERE {alc(p, 'empresa_id')}"
                              + (" AND empresa_id = %(emp)s" if empresa and p["empresa_id"] is None else "")
                              + " ORDER BY 1", {"emp": empresa}).fetchall()

        METAS = aj()["metas"]
        terminados = g["cerrados"] + g["escalados"]
        pct = lambda a, b: 100 * a / b if b else None
        indicadores = [
            ("Resueltos sin intervención humana", pct(g["resueltos_n1"], terminados), "%", METAS["sin_humano"], True),
            ("Tiempo medio de resolución", g["minutos"], " min", METAS["minutos"], False),
            ("Satisfacción", g["satisfaccion"], " / 5", METAS["satisfaccion"], True),
            ("Reapertura en 7 días", pct(reabiertos, g["resueltos"]), "%", METAS["reapertura"], False),
            ("Acciones revertidas", pct(acciones["deshechas"], acciones["aplicadas"]), "%", METAS["revertidas"], False),
        ]

        def meta(nombre, valor, unidad_, objetivo, mayor):
            regla = f'Meta: {"≥" if mayor else "<"} {objetivo:g}{unidad_}'
            if valor is None:
                valor_html, estado_html, clase = "—", insignia("Sin datos", "neutra"), ""
            else:
                cumple = valor >= objetivo if mayor else valor < objetivo
                valor_html = f"{valor:.1f}{unidad_}"
                estado_html = insignia("Cumple", "exito", "ok") if cumple else insignia("No cumple", "peligro", "alerta")
                clase = "text-exito" if cumple else "text-peligro"
            return (f'<div class="tarjeta gap-2 py-5"><p class="min-h-10 px-5 text-sm font-medium text-muted-foreground">{nombre}</p>'
                    f'<div class="px-5 text-3xl font-semibold tabular-nums tracking-tight {clase}">{valor_html}</div>'
                    f'<div class="flex flex-wrap items-center gap-2 px-5 text-xs text-muted-foreground">{estado_html}{regla}</div></div>')

        # Serie continua (días o meses sin casos = 0) para el gráfico por fecha.
        hoy = datetime.now(zona()).date()
        if unidad == "day":
            ejes = [hoy - timedelta(days=i) for i in range(dias - 1, -1, -1)]
            etiqueta = lambda d: d.strftime("%d/%m")
        else:
            ejes = sorted({date(hoy.year - (hoy.month - 1 - i < 0), (hoy.month - 1 - i) % 12 + 1, 1) for i in range(12)})
            etiqueta = lambda d: d.strftime("%m/%Y")
        datos_dia = {f["dia"]: f for f in por_dia}
        serie = lambda k: [datos_dia[d][k] if d in datos_dia else 0 for d in ejes]
        otros_dia = [t - r - s for t, r, s in zip(serie("total"), serie("resueltos"), serie("escalados"))]
        grafico_fechas = {"tipo": "barras", "apilar": True, "categorias": [etiqueta(d) for d in ejes], "series": [
            {"nombre": "Resueltos", "color": "exito", "datos": serie("resueltos")},
            {"nombre": "Escalados", "color": "peligro", "datos": serie("escalados")},
            {"nombre": "Otros", "color": "neutro", "datos": otros_dia}]}
        grafico_resultado = {"tipo": "dona", "total": g["total"], "datos": [
            {"nombre": "Resueltos", "valor": g["resueltos"], "color": "exito"},
            {"nombre": "Escalados", "valor": g["escalados"], "color": "peligro"},
            {"nombre": "Abiertos", "valor": g["abiertos"], "color": "info"},
            {"nombre": "Cerrados sin resolver", "valor": g["sin_resolver"], "color": "neutro"}]}
        def apilado(filas):
            return [{"nombre": "Resueltos", "color": "exito", "datos": [f["resueltos"] for f in filas]},
                    {"nombre": "Escalados", "color": "peligro", "datos": [f["escalados"] for f in filas]},
                    {"nombre": "Otros", "color": "neutro", "datos": [f["total"] - f["resueltos"] - f["escalados"] for f in filas]}]
        # Categorías por empresa: hasta 7 categorías con color propio (orden fijo por volumen total) y el resto en «Otras»
        tot_cat: dict = defaultdict(int)
        tot_emp: dict = defaultdict(int)
        for f in cruce:
            tot_cat[f["categoria"]] += f["n"]
            tot_emp[f["empresa"]] += f["n"]
        cats = sorted(tot_cat, key=lambda x: (-tot_cat[x], x))
        principales, emps = cats[:7], sorted(tot_emp, key=lambda x: (-tot_emp[x], x))[:12]
        celda = {(f["empresa"], f["categoria"]): f["n"] for f in cruce}
        grafico_cruce = {"tipo": "barras-h", "apilar": True, "categorias": emps, "series": [
            {"nombre": ct, "color": f"s{i + 1}", "datos": [celda.get((em, ct), 0) for em in emps]} for i, ct in enumerate(principales)]
            + ([{"nombre": "Otras", "color": "neutro", "datos": [sum(celda.get((em, ct), 0) for ct in cats[7:]) for em in emps]}]
               if cats[7:] else [])}
        grafico_cat = {"tipo": "barras-h", "apilar": True, "categorias": [f["nombre"] for f in por_cat], "series": [
            {"nombre": "Resueltos", "color": "exito", "datos": [f["resueltos"] for f in por_cat]},
            {"nombre": "Escalados", "color": "peligro", "datos": [f["escalados"] for f in por_cat]},
            {"nombre": "Otros", "color": "neutro", "datos": [f["total"] - f["resueltos"] - f["escalados"] for f in por_cat]}]}

        def grafico(datos, alto="h-72"):
            return f'<div class="{alto} w-full" data-grafico="{e(json.dumps(datos, ensure_ascii=False))}" role="img" aria-label="Gráfico"></div>'

        def tarjeta(titulo, desc, contenido, clase="", cuerpo_clase="tarjeta-cuerpo"):
            return (f'<section class="tarjeta {clase}"><div class="tarjeta-cab"><h2 class="tarjeta-titulo">{titulo}</h2>'
                    f'<p class="tarjeta-desc">{desc}</p></div><div class="{cuerpo_clase}">{contenido}</div></section>')

        def tabla(id_, filas, columnas, barra):
            if not filas:
                return '<p class="px-6 py-8 text-center text-sm text-muted-foreground">Sin datos en el período.</p>'
            maximo = max(f[barra] for f in filas) or 1 if barra else 0
            cab = "".join(f'<th{" class=\"text-right\"" if i else ""}>{t}</th>' for i, (_, t) in enumerate(columnas))
            cuerpo = "".join(
                "<tr>" + "".join(
                    f'<td class="{"text-right tabular-nums" if i else "font-medium"}">'
                    f'{e(f[k]) if i else (f"<span class=\"codigo\">{e(f[k])}</span>" if id_ == "tabla-pb" else e(f[k]))}</td>'
                    for i, (k, _) in enumerate(columnas))
                + (f'<td class="w-28"><progress class="progreso" max="{maximo}" value="{f[barra]}" '
                   f'aria-label="{e(f[barra])} de {maximo}"></progress></td>' if barra else "") + "</tr>" for f in filas)
            return (f'<div class="tabla-caja"><table id="{id_}" class="tabla" data-tabla="simple">'
                    f'<thead><tr>{cab}{"<th data-orderable=\"false\"><span class=\"sr-only\">Proporción</span></th>" if barra else ""}</tr></thead>'
                    f'<tbody>{cuerpo}</tbody></table></div>')

        opcion = lambda v, txt, act: f'<option value="{e(v)}"{" selected" if v == act else ""}>{e(txt)}</option>'
        sel = lambda nombre, etiqueta, ops: (f'<label class="sr-only" for="f-{nombre}">{etiqueta}</label>'
                                             f'<select class="campo h-9 w-auto max-w-56 py-0 text-sm" id="f-{nombre}" name="{nombre}">{ops}</select>')
        consulta = {k: v for k, v in (("dias", dias), ("empresa", empresa), ("sede", sede), ("categoria", categoria)) if v}
        periodo = (
            '<form method="get" action="/consola/metricas" class="grid gap-3">'
            '<div class="flex flex-wrap items-center gap-2">'
            + sel("dias", "Período", "".join(opcion(d, t, dias) for d, t in ((7, "Últimos 7 días"), (30, "Últimos 30 días"),
                                                                             (90, "Últimos 90 días"), (365, "Último año"))))
            + (sel("empresa", "Empresa", opcion(0, "Todas las empresas", empresa)
                   + "".join(opcion(x["id"], x["nombre"], empresa) for x in empresas)) if empresas else "")
            + sel("sede", "Sede", opcion("", "Todas las sedes", sede) + "".join(opcion(x["nombre"], x["nombre"], sede) for x in sedes))
            + sel("categoria", "Categoría", opcion("", "Todas las categorías", categoria)
                  + "".join(opcion(x, x, categoria) for x in (*aj()["categorias"], "Sin clasificar")))
            + '<button class="btn btn-primario btn-sm">Aplicar</button>'
            + f'<a class="btn btn-borde btn-sm" href="/consola/metricas/casos.csv?{urlencode(consulta)}">{icono("subir")}Exportar CSV</a></div>'
            '<details class="text-sm"><summary class="cursor-pointer text-muted-foreground hover:text-foreground">'
            'Elegir paneles (guarda la dirección como marcador para volver a esta vista)</summary>'
            '<div class="mt-2 flex flex-wrap gap-x-5 gap-y-2">'
            + "".join(f'<label class="etiqueta font-normal"><input type="checkbox" name="panel" value="{k}" class="size-4 accent-primary"'
                      f'{" checked" if k in paneles else ""}>{t}</label>' for k, t in PANELES.items())
            + '</div></details></form>')
        ver = lambda k, html_: html_ if k in paneles else ""
        volumen = ('<div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-6">'
                   + cifra("Casos", str(g["total"]), f'{g["personas"]} personas · últimos {dias} días', "casos")
                   + cifra("Resueltos por Helpert", str(g["resueltos_n1"]), "Sin pasar por N2 ni N3", "ok", "text-exito")
                   + cifra("Con soporte humano", str(g["con_humano"]), f'{g["escalados"]} siguen escalados', "escalar")
                   + cifra("Fuera de tiempo", str(g["vencidos"]), "Escalados que pasaron su tiempo de respuesta", "reloj",
                           "text-peligro" if g["vencidos"] else "")
                   + cifra("Sin calificación", f'{pct(g["sin_calificar"], g["cerrados"]):.0f} %' if g["cerrados"] else "—",
                           "Cerrados sin nota de la persona", "estrella")
                   + cifra("Costo de IA", f'US$ {g["costo"]:.2f}', "Con los precios configurados", "dinero") + '</div>')
        metas = ver("metas", '<section class="space-y-3"><div><h2 class="text-lg font-semibold tracking-tight">Metas del piloto</h2>'
                 '<p class="text-sm text-muted-foreground">Las del plan de desarrollo, sobre los casos del período.</p></div>'
                 '<div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5">'
                 + "".join(meta(*i) for i in indicadores) + '</div></section>')
        graficos = ver("graficos", '<div class="grid gap-6 lg:grid-cols-3">'
                    + tarjeta("Casos por " + ("mes" if unidad == "month" else "día"), "Según cómo terminaron.",
                              grafico(grafico_fechas), "lg:col-span-2")
                    + tarjeta("Resultado", f"{g['total']} casos del período.", grafico(grafico_resultado))
                    + '</div>')
        sangria = "[&_.tabla_th:first-child]:pl-6 [&_.tabla_td:first-child]:pl-6 [&_.tabla_th:last-child]:pr-6 [&_.tabla_td:last-child]:pr-6"
        con_tabla = "gap-4 overflow-hidden pb-0"
        cols = [("nombre", ""), ("total", "Casos"), ("resueltos", "Resueltos"), ("escalados", "Escalados"),
                ("satisfaccion", "Satisfacción")]
        con = lambda nombre: [(cols[0][0], nombre)] + cols[1:]
        por_nivel = [{**f, "nombre": NIVEL.get(f["nombre"], (str(f["nombre"]),))[0]} for f in por_nivel]
        detalle = (ver("empresas", tarjeta(
            "Por empresa", "Volumen, resultado y costo de IA de cada empresa; el gráfico muestra sus categorías.",
            '<div class="grid items-start gap-2 lg:grid-cols-2">'
            + (f'<div class="px-4">{grafico(grafico_cruce, "h-80")}</div>' if cruce else "")
            + '<div class="self-stretch border-t lg:border-l lg:border-t-0">'
            + tabla("tabla-empresas", por_empresa, con("Empresa") + [("costo", "IA (US$)")], "total") + '</div></div>',
            con_tabla, f"px-0 {sangria}") if por_empresa else "")
            + ver("niveles", tarjeta("Por nivel", "N1 es Helpert; N2, soporte en sitio; N3, el analista. Muestra dónde se resuelve.",
                                     tabla("tabla-niveles", por_nivel, con("Nivel"), "total"), con_tabla, f"px-0 {sangria}"))
            + ver("personas", tarjeta("Personas con más consultas", "Las 15 que más casos abrieron en el período.",
                                      tabla("tabla-personas", personas, [("nombre", "Persona"), ("empresa", "Empresa"), ("total", "Casos"),
                                                                         ("escalados", "Con soporte humano"),
                                                                         ("satisfaccion", "Satisfacción")], "total"),
                                      con_tabla, f"px-0 {sangria}"))
            + ver("categorias", tarjeta("Por categoría", "Categorías ITIL que asignó la IA.",
                    '<div class="grid items-center gap-2 lg:grid-cols-2">'
                    + (f'<div class="px-4">{grafico(grafico_cat, "h-64")}</div>' if por_cat else "")
                    + '<div class="self-stretch border-t lg:border-l lg:border-t-0">'
                    + tabla("tabla-cat", por_cat, [("nombre", "Categoría"), ("total", "Casos"), ("resueltos", "Resueltos"),
                                                   ("escalados", "Escalados")], "total") + '</div></div>',
                    con_tabla, f"px-0 {sangria}"))
            + '<div class="grid items-start gap-6 lg:grid-cols-2">'
            + ver("subcategorias", tarjeta("Subcategorías", "Las 15 más frecuentes: candidatas a un playbook nuevo.",
                                           tabla("tabla-sub", por_sub, con("Categoría · subcategoría"), "total"),
                                           con_tabla, f"px-0 {sangria}"))
            + ver("sedes", tarjeta("Por sede", "Según la sede de la persona (o la del equipo).",
                                   tabla("tabla-sedes", por_sede, con("Sede"), "total"), con_tabla, f"px-0 {sangria}"))
            + '</div><div class="grid items-start gap-6 lg:grid-cols-3">'
            + ver("playbooks", tarjeta("Por playbook", "Pasos que corrieron los equipos.",
                      tabla("tabla-pb", por_pb, [("nombre", "Playbook"), ("diagnosticos", "Diagnósticos"),
                                                 ("aplicados", "Aplicados"), ("verificados", "Verificados"),
                                                 ("fallos", "Fallos")], "diagnosticos"),
                      f"{con_tabla} lg:col-span-2", f"px-0 {sangria}"))
            + ver("modelos", tarjeta("Por modelo de IA", "Incidencias: el proveedor falló o respondió fuera del contrato.",
                                     tabla("tabla-modelo", por_modelo, [("nombre", "Modelo"), ("total", "Casos"),
                                                                        ("con_incidencia", "Incidencias"), ("costo", "US$")], None),
                                     con_tabla, f"px-0 {sangria}"))
            + '</div>')
        alcance = p["empresa"] or next((x["nombre"] for x in empresas if x["id"] == empresa), "todas las empresas")
        cuerpo = (encabezado("Métricas", f"Analítica de soporte de {e(alcance)}. Se actualiza cada minuto.")
                  + f'<div class="tarjeta py-4"><div class="px-4">{periodo}</div></div>'
                  + volumen + metas + graficos + detalle)
        return pagina("Métricas", cuerpo, p, "metricas", refrescar=60, libs=("datatables", "echarts"))

    # ── Administración (solo rol admin) ─────────────────────────────────────────────────────────────────────────
    catalogo = cat.cargar(cfg["playbooks"])
    SECCIONES = {"general": ("General", "admin"), "empresas": ("Empresas", "empresa"), "ia": ("IA", "ia"),
                 "playbooks": ("Playbooks", "lista"), "categorias": ("Categorías", "meta"), "privacidad": ("Privacidad", "candado"),
                 "equipos": ("Equipos", "equipo"), "usuarios": ("Usuarios", "usuario"), "auditoria": ("Auditoría", "reloj")}
    # lo que ve la administración de una empresa (siempre filtrado a la suya)
    DE_EMPRESA = ("empresas", "privacidad", "equipos", "usuarios")

    def secciones(p):
        if p["rol"] == "admin":
            return SECCIONES
        return {k: ("Mi empresa", "empresa") if k == "empresas" else SECCIONES[k] for k in DE_EMPRESA}
    AVISOS = {"rol": "Rol actualizado. Sus sesiones abiertas se cerraron.", "activo": "Cuenta activada.",
              "inactivo": "Cuenta desactivada. Sus sesiones se cerraron.", "revocado": "Equipo revocado: su token ya no sirve.",
              "propio": "No puedes cambiar tu propio rol ni desactivar tu cuenta.",
              "ultimo": "Debe quedar al menos una cuenta de administración activa.",
              "existe": "Ya existe una cuenta o un equipo con ese nombre.", "invalido": "Revisa los datos del formulario.",
              "ajustes": "Cambios guardados. Ya se están aplicando.", "pb_activar": "Playbook activado.",
              "pb_desactivar": "Playbook desactivado: ya no se ofrece y los casos en curso con él se escalan.",
              "ia_agregar": "Proveedor agregado a la cadena.", "ia_guardar": "Proveedor guardado.",
              "ia_quitar": "Proveedor quitado de la cadena.", "ia_subir": "Orden de la cadena actualizado.",
              "ia_bajar": "Orden de la cadena actualizado.", "sesiones": "Sesiones cerradas.",
              "categorias": "Categorías guardadas. La IA las usa desde el siguiente mensaje.",
              "capturas": "Ajustes de capturas guardados.", "despliegue": "Etapa del despliegue guardada: cada equipo la recibe en su próximo latido.", "reglas": "Reglas por área guardadas. Se aplican desde el siguiente mensaje."}
    EMAIL = re.compile(r"^[^@\s]{1,100}@[^@\s]{1,100}\.[^@\s]{2,}$")
    NOMBRE_EQUIPO = re.compile(r"^[A-Za-z0-9._-]{1,64}$")

    async def formulario(request: Request, roles=("admin",)):
        """Persona + datos del formulario, con el token CSRF de su sesión comprobado."""
        p = await run_in_threadpool(persona_de, request, *roles)
        datos = {k: v[0] for k, v in parse_qs((await request.body()).decode(errors="replace")).items()}
        if not hmac.compare_digest(datos.get("csrf", ""), p["csrf"]):
            raise HTTPException(403, "El formulario venció: recarga la página e inténtalo de nuevo")
        return p, datos

    def csrf(p):
        return f'<input type="hidden" name="csrf" value="{p["csrf"]}">'

    def boton_post(p, accion, texto, clase="btn-borde", confirmar=""):
        """Botón que envía un formulario POST con CSRF; confirmar: pregunta antes de enviar (con JavaScript)."""
        conf = f' data-confirmar="{e(confirmar)}"' if confirmar else ""
        return f'<form method="post" action="{accion}"{conf}>{csrf(p)}<button class="btn btn-sm {clase}">{texto}</button></form>'

    def volver(seccion, aviso):
        return RedirectResponse(f"/consola/admin/{seccion}?{urlencode({'aviso': aviso})}", 303)

    def tarjeta(titulo, desc, contenido, clase="", cuerpo_clase="tarjeta-cuerpo"):
        return (f'<section class="tarjeta {clase}"><div class="tarjeta-cab"><h2 class="tarjeta-titulo">{titulo}</h2>'
                f'<p class="tarjeta-desc">{desc}</p></div><div class="{cuerpo_clase}">{contenido}</div></section>')

    def admin_pagina(p, seccion, contenido, aviso="", secreto=None, mensaje=None):
        pestanas = ('<nav class="pestanas md:hidden" aria-label="Secciones de administración">' + "".join(
            f'<a class="pestana" href="/consola/admin/{k}"{" aria-current=page" if k == seccion else ""}>{icono(i)}{t}</a>'
            for k, (t, i) in secciones(p).items()) + '</nav>')
        avisos = (f'<div class="alerta border-primary/30 bg-primario-suave/40 text-sobre-primario-suave" role="status">'
                  f'{icono("ok")}<p>{e(AVISOS[aviso])}</p></div>' if aviso in AVISOS else "")
        if mensaje:  # resultado de una acción en esta misma respuesta (error de validación, prueba de un proveedor)
            tipo, texto = mensaje
            avisos += (f'<div class="alerta {"alerta-peligro" if tipo == "peligro" else "border-exito/30 bg-exito/10 text-exito"}" '
                       f'role="alert">{icono("alerta" if tipo == "peligro" else "ok")}<p>{e(texto)}</p></div>')
        if secreto:
            titulo, valor, explicacion = secreto
            avisos += (
                '<section class="tarjeta gap-4 border-primary/40 py-5" aria-live="polite">'
                f'<div class="flex gap-3 px-5"><span class="flex size-9 shrink-0 items-center justify-center rounded-md '
                f'bg-primario-suave text-sobre-primario-suave">{icono("llave")}</span><div><p class="font-semibold">{e(titulo)}</p>'
                f'<p class="text-sm text-muted-foreground">{e(explicacion)}</p></div></div>'
                '<div class="flex flex-wrap items-center gap-2 px-5"><code id="secreto" class="min-w-0 flex-1 select-all '
                f'break-all rounded-md border bg-muted px-3 py-2 font-mono text-sm">{e(valor)}</code>'
                f'<button type="button" class="btn btn-borde" data-copiar="secreto" data-con-js hidden>{icono("copiar")}Copiar</button>'
                '</div></section>')
        desc = ("Empresas, interruptores de emergencia, IA, playbooks, equipos, cuentas y ajustes. Cada cambio queda en la auditoría."
                if p["rol"] == "admin" else f"{p['empresa']}: datos, sedes, personas, equipos, cuentas y privacidad. "
                "Cada cambio queda en la auditoría.")
        cuerpo = encabezado(secciones(p)[seccion][0], desc) + pestanas + avisos + contenido
        return pagina(f"Administración · {secciones(p)[seccion][0]}", cuerpo, p, f"admin:{seccion}", libs=("datatables", "choices"))

    def vista_usuarios(p, aviso="", secreto=None, mensaje=None):
        with db.conexion(dsn) as c:
            filas = c.execute("SELECT u.id, u.email, u.nombre, u.rol, u.activo, u.ultimo_acceso, u.creado, em.nombre AS empresa, "
                              "(SELECT count(*) FROM sesiones s WHERE s.usuario_id = u.id AND s.expira > now()) AS sesiones "
                              "FROM usuarios_consola u LEFT JOIN empresas em ON em.id = u.empresa_id "
                              f"WHERE {alc(p, 'u.empresa_id')} ORDER BY u.activo DESC, u.rol, u.email").fetchall()
            empresas = empresas_de(c, p) if p["rol"] == "admin" else []
        roles = {k: v for k, v in ROLES.items() if p["rol"] == "admin" or k != "admin"}

        def fila(u):
            propio = u["id"] == p["id"]
            nombre = u["nombre"] or u["email"]
            iniciales = "".join(x[0] for x in str(nombre).split()[:2]).upper() or "?"
            persona = (f'<div class="flex items-center gap-3"><span class="avatar">{e(iniciales)}</span><div class="min-w-0">'
                       f'<p class="flex items-center gap-2 font-medium">{e(nombre)}{insignia("Tú", "info") if propio else ""}</p>'
                       f'<p class="truncate text-xs text-muted-foreground">{e(u["email"])}</p></div></div>')
            if propio:
                rol = insignia(ROLES.get(u["rol"], u["rol"]), "borde")
            else:
                rol = (f'<form method="post" action="/consola/admin/usuarios/{u["id"]}/rol" class="flex items-center gap-1.5" '
                       f'data-confirmar="¿Cambiar el rol de {e(u["email"])}? Sus sesiones abiertas se cierran.">'
                       f'{csrf(p)}<label class="sr-only" for="rol-{u["id"]}">Rol de {e(nombre)}</label>'
                       f'<select id="rol-{u["id"]}" name="rol" class="campo h-8 w-40 py-0 text-sm" data-enviar>'
                       + "".join(f'<option value="{k}"{" selected" if k == u["rol"] else ""}>{t}</option>' for k, t in roles.items())
                       + '</select><button class="btn btn-borde btn-sm" data-solo-sin-js>Guardar</button></form>')
            estado = insignia("Activa", "exito") if u["activo"] else insignia("Desactivada", "neutra", "prohibido")
            acciones = (f'<form method="post" action="/consola/admin/usuarios/{u["id"]}/clave" '
                        f'data-confirmar="¿Generar una contraseña nueva para {e(u["email"])}? La actual deja de servir.">{csrf(p)}'
                        f'<button class="btn btn-fantasma btn-sm">{icono("llave")}Nueva contraseña</button></form>')
            otras = u["sesiones"] - (1 if propio else 0)
            if otras > 0:
                acciones += boton_post(p, f'/consola/admin/usuarios/{u["id"]}/sesiones',
                                       "Cerrar mis otras sesiones" if propio else "Cerrar sesiones", "btn-fantasma",
                                       f'¿Cerrar {"tus otras sesiones" if propio else "las sesiones de " + u["email"]}?')
            if not propio:
                accion, texto = ("desactivar", "Desactivar") if u["activo"] else ("activar", "Activar")
                acciones += (f'<form method="post" action="/consola/admin/usuarios/{u["id"]}/{accion}"'
                             + (f' data-confirmar="¿Desactivar a {e(u["email"])}? Sus sesiones se cierran."' if u["activo"] else "")
                             + f'>{csrf(p)}<button class="btn btn-fantasma btn-sm{" text-peligro" if u["activo"] else ""}">{texto}</button></form>')
            return (f'<tr><td data-search="{e(nombre)} {e(u["email"])}">{persona}</td><td data-order="{e(u["rol"])}">{rol}'
                    + (f'<p class="mt-1 text-xs text-muted-foreground">{e(u["empresa"] or "Plataforma")}</p>' if p["rol"] == "admin" else "")
                    + '</td>'
                    f'<td>{estado}</td><td class="text-right tabular-nums">{u["sesiones"]}</td>'
                    f'<td data-order="{u["ultimo_acceso"].isoformat() if u["ultimo_acceso"] else ""}" '
                    f'class="whitespace-nowrap tabular-nums text-muted-foreground">{fecha(u["ultimo_acceso"]) if u["ultimo_acceso"] else "Nunca"}</td>'
                    f'<td><div class="flex flex-wrap justify-end gap-1">{acciones}</div></td></tr>')

        tabla = ('<div class="tabla-caja"><table id="tabla-usuarios" class="tabla" data-tabla="simple"><thead><tr>'
                 '<th>Persona</th><th>Rol</th><th>Estado</th><th class="text-right">Sesiones</th><th>Último acceso</th>'
                 '<th class="text-right" data-orderable="false">Acciones</th></tr></thead>'
                 f'<tbody>{"".join(fila(u) for u in filas)}</tbody></table></div>')
        sel_empresa = ('<div class="grid gap-2"><label class="etiqueta" for="n-empresa">Empresa</label>'
                       '<select class="campo" id="n-empresa" name="empresa"><option value="">Plataforma (todas)</option>'
                       + "".join(f'<option value="{x["id"]}">{e(x["nombre"])}</option>' for x in empresas) + '</select></div>'
                       if p["rol"] == "admin" else "")
        crear = (f'<form method="post" action="/consola/admin/usuarios" class="grid items-end gap-4 '
                 f'md:grid-cols-[1fr_1fr_13rem{"_13rem" if sel_empresa else ""}_auto]">{csrf(p)}'
                 '<div class="grid gap-2"><label class="etiqueta" for="n-email">Correo</label>'
                 '<input class="campo" id="n-email" name="email" type="email" required maxlength="200" placeholder="nombre@empresa.pe"></div>'
                 '<div class="grid gap-2"><label class="etiqueta" for="n-nombre">Nombre</label>'
                 '<input class="campo" id="n-nombre" name="nombre" maxlength="100" placeholder="Nombre y apellido"></div>'
                 '<div class="grid gap-2"><label class="etiqueta" for="n-rol">Rol</label><select id="n-rol" name="rol" data-choices>'
                 + "".join(f'<option value="{k}"{" selected" if k == "tecnico" else ""}>{t}</option>' for k, t in roles.items())
                 + f'</select></div>{sel_empresa}<button class="btn btn-primario">{icono("mas")}Crear cuenta</button></form>')
        contenido = (tarjeta("Nueva cuenta", "Se genera una contraseña temporal que verás una sola vez. La administración de la "
                             "plataforma ve todas las empresas; la de una empresa, solo la suya. Asistente N2 y Analista N3 "
                             "atienden casos; Gerencia ve métricas. Una cuenta con empresa solo ve los datos de esa empresa.", crear)
                     + tarjeta("Cuentas de la consola", f"{len(filas)} cuentas. Entran con correo y contraseña "
                               "(con Supabase Auth se agregará MFA).", tabla, "gap-4 overflow-hidden pb-0",
                               "px-0 [&_.tabla_th:first-child]:pl-6 [&_.tabla_td:first-child]:pl-6 "
                               "[&_.tabla_th:last-child]:pr-6 [&_.tabla_td:last-child]:pr-6")
                     )
        return admin_pagina(p, "usuarios", contenido, aviso, secreto, mensaje)

    def vista_equipos(p, aviso="", secreto=None, mensaje=None):
        with db.conexion(dsn) as c:
            filas = c.execute("""
                SELECT q.id, q.nombre, q.creado, q.visto, q.revocado, q.area, q.sede, q.piso, q.version, q.piloto, q.binario_sha,
                  count(k.id) AS casos, em.nombre AS empresa,
                  coalesce(q.so, (SELECT so FROM casos WHERE equipo_id = q.id ORDER BY id DESC LIMIT 1)) AS so
                FROM equipos q LEFT JOIN casos k ON k.equipo_id = q.id LEFT JOIN empresas em ON em.id = q.empresa_id
                WHERE """ + alc(p, "q.empresa_id") + """
                GROUP BY q.id, em.nombre ORDER BY q.revocado NULLS FIRST, q.nombre""").fetchall()
            aj_ = ajustes.leer(c, cfg)
            ins, dep = aj_["inscripcion"], aj_["despliegue"]
            versiones = c.execute("SELECT v.sha256, v.version, v.so, v.tamano, v.subida, (SELECT count(*) FROM equipos q "
                                  "WHERE q.binario_sha = v.sha256 AND q.revocado IS NULL) AS equipos FROM versiones_agente v "
                                  "ORDER BY v.subida DESC").fetchall()
            salud = {f["sha"]: f for f in c.execute("""
                SELECT q.binario_sha AS sha, count(t.id) AS pasos, count(t.id) FILTER (WHERE t.codigo NOT IN (0, 10)) AS fallos
                FROM equipos q JOIN casos k ON k.equipo_id = q.id JOIN trabajos t ON t.caso_id = k.id
                WHERE t.creado > now() - interval '48 hours' AND q.binario_sha IS NOT NULL GROUP BY 1""")}

        def papel(sha):
            return (insignia("Nueva", "info") if sha and sha == dep["nueva"] else
                    insignia("Estable", "exito") if sha and sha == dep["estable"] else "")

        def fila(q):
            if q["revocado"]:
                estado = insignia("Revocado", "peligro", "prohibido")
            elif q["visto"] and q["visto"] > db.ahora() - SIN_SENAL:
                estado = insignia("En línea", "exito")
            elif q["version"] and q["visto"]:  # agente con latido que dejó de reportar
                estado = insignia("Sin señal", "peligro", "alerta")
            elif q["visto"] or q["casos"]:
                estado = insignia("Registrado", "info")
            else:
                estado = insignia("Sin conexión aún", "neutra")
            acciones = (f'<form method="post" action="/consola/admin/equipos/{q["id"]}/token" data-confirmar="¿Generar un token '
                        f'nuevo para {e(q["nombre"])}? El actual deja de servir y hay que reinstalar el agente con el nuevo.">'
                        f'{csrf(p)}<button class="btn btn-fantasma btn-sm">{icono("llave")}Nuevo token</button></form>')
            if not q["revocado"]:
                acciones += (f'<form method="post" action="/consola/admin/equipos/{q["id"]}/revocar" data-confirmar="¿Revocar '
                             f'{e(q["nombre"])}? Su agente deja de poder hablar con el servidor.">{csrf(p)}'
                             f'<button class="btn btn-fantasma btn-sm text-peligro">Revocar</button></form>')
            ubicacion = " · ".join(x for x in (q["area"], q["sede"], q["piso"] and f'piso {q["piso"]}') if x)
            return (f'<tr data-href="/consola/admin/equipos/{q["id"]}" class="cursor-pointer"><td>'
                    f'<a class="inline-flex items-center gap-2 font-medium hover:underline" href="/consola/admin/equipos/{q["id"]}">'
                    f'{icono("equipo", "size-4 text-muted-foreground")}{e(q["nombre"])}</a>'
                    + (f'<p class="text-xs text-muted-foreground">{e(q["empresa"] or "Sin empresa: nadie inició sesión")}</p>'
                       if p["rol"] == "admin" else "") + f'</td><td>{estado}</td>'
                    f'<td class="text-muted-foreground">{e(ubicacion)}</td><td>{e((q["so"] or "").capitalize())}</td>'
                    f'<td class="tabular-nums text-muted-foreground"><span class="inline-flex flex-wrap items-center gap-1">'
                    f'{e(q["version"])}{papel(q["binario_sha"])}{insignia("Piloto", "borde") if q["piloto"] else ""}</span></td>'
                    f'<td data-order="{q["visto"].isoformat() if q["visto"] else ""}" class="whitespace-nowrap tabular-nums '
                    f'text-muted-foreground">{fecha(q["visto"]) if q["visto"] else "—"}</td>'
                    f'<td class="text-right tabular-nums">{q["casos"]}</td>'
                    f'<td data-order="{q["creado"].isoformat()}" class="whitespace-nowrap tabular-nums text-muted-foreground">{fecha(q["creado"])}</td>'
                    f'<td><div class="flex flex-wrap justify-end gap-1">{acciones}</div></td></tr>')

        tabla = ('<div class="tabla-caja"><table id="tabla-equipos" class="tabla" data-tabla="simple"><thead><tr>'
                 '<th>Equipo</th><th>Estado</th><th>Ubicación</th><th>Sistema</th><th>Versión</th><th>Último contacto</th><th class="text-right">Casos</th><th>Registrado</th>'
                 '<th class="text-right" data-orderable="false">Acciones</th></tr></thead>'
                 f'<tbody>{"".join(fila(q) for q in filas)}</tbody></table></div>' if filas else
                 '<p class="px-6 py-10 text-center text-sm text-muted-foreground">Todavía no hay equipos registrados.</p>')
        var = cfg.get("inscripcion_env")
        origen = ("una clave generada en la consola" if ins["clave_sha"] else
                  f'la clave de la variable <span class="codigo">{e(var)}</span>' if var and os.environ.get(var) else None)
        botones_ins = "".join(
            boton_post(p, f"/consola/admin/inscripcion/{acc}", t, clase, conf)
            for acc, t, clase, conf, mostrar in (
                ("desactivar", "Desactivar", "btn-borde text-peligro",
                 "¿Desactivar la inscripción? Los instaladores dejan de poder registrar equipos.", ins["activa"]),
                ("activar", "Activar", "btn-primario", "", not ins["activa"]),
                ("clave", "Generar clave nueva", "btn-borde",
                 "¿Generar una clave nueva? La anterior deja de servir: hay que volver a empaquetar el instalador.", True),
                ("servidor", "Usar la clave del servidor", "btn-fantasma", "", bool(ins["clave_sha"] and var and os.environ.get(var))))
            if mostrar)
        inscripcion = (
            f'<div class="flex flex-wrap items-center gap-2">{insignia("Activa", "exito", "ok") if ins["activa"] and origen else insignia("Desactivada", "neutra")}</div>'
            + (f'<p class="mt-2 text-sm text-muted-foreground">El instalador (<span class="codigo">helpert-instalar.run</span>) '
               f'registra cada equipo con {origen}.</p>' if origen else
               '<p class="mt-2 text-sm text-muted-foreground">No hay clave: genera una para empaquetar el instalador.</p>')
            + f'<div class="mt-4 flex flex-wrap gap-2">{botones_ins}</div>')
        crear = (f'<form method="post" action="/consola/admin/equipos" class="flex flex-wrap items-start gap-3">{csrf(p)}'
                 '<div class="grid min-w-48 flex-1 gap-2"><label class="etiqueta" for="n-equipo">Nombre del equipo</label>'
                 '<input class="campo" id="n-equipo" name="nombre" required maxlength="64" pattern="[A-Za-z0-9._\\-]+" '
                 'placeholder="PC-CONTA-03"><p class="text-xs text-muted-foreground">Letras, números, punto, guion o guion bajo.</p></div>'
                 f'<button class="btn btn-primario mt-6">{icono("mas")}Registrar equipo</button></form>')
        opciones_v = lambda actual: '<option value="">Ninguna</option>' + "".join(
            f'<option value="{v["sha256"]}"{" selected" if v["sha256"] == actual else ""}>{e(v["version"])} · {v["so"]} · '
            f'{v["sha256"][:10]}</option>' for v in versiones)
        tabla_v = ('<div class="tabla-caja"><table class="tabla" data-tabla="simple"><thead><tr><th>Versión</th><th>Sistema</th>'
                   '<th>Huella</th><th class="text-right">Tamaño</th><th>Publicada</th><th class="text-right">Equipos</th>'
                   '<th class="text-right">Pasos con error (48 h)</th></tr></thead><tbody>' + "".join(
                       f'<tr><td><span class="inline-flex items-center gap-2 font-medium">{e(v["version"])}{papel(v["sha256"])}</span></td>'
                       f'<td>{e(v["so"].capitalize())}</td><td class="font-mono text-xs">{v["sha256"][:12]}</td>'
                       f'<td class="text-right tabular-nums">{v["tamano"] / 1_048_576:.1f} MB</td>'
                       f'<td class="whitespace-nowrap tabular-nums text-muted-foreground">{fecha(v["subida"])}</td>'
                       f'<td class="text-right tabular-nums">{v["equipos"]}</td><td class="text-right tabular-nums">'
                       + (f'{salud[v["sha256"]]["fallos"]} de {salud[v["sha256"]]["pasos"]}' if v["sha256"] in salud else "—")
                       + '</td></tr>' for v in versiones) + '</tbody></table></div>')
        etapa = (
            f'<form method="post" action="/consola/admin/despliegue" class="grid gap-4 sm:grid-cols-[1fr_1fr_10rem_auto] sm:items-end">{csrf(p)}'
            f'<div class="grid gap-2"><label class="etiqueta" for="d-estable">Versión estable (todos)</label>'
            f'<select class="campo" id="d-estable" name="estable">{opciones_v(dep["estable"])}</select></div>'
            f'<div class="grid gap-2"><label class="etiqueta" for="d-nueva">Versión nueva (en prueba)</label>'
            f'<select class="campo" id="d-nueva" name="nueva">{opciones_v(dep["nueva"])}</select></div>'
            + campo("porcentaje", "% de equipos", dep["porcentaje"], "", "number", 'min="0" max="100"', "d-pct")
            + f'<button class="btn btn-primario">{icono("ok")}Guardar etapa</button></form>')
        if dep["nueva"]:
            etapa += ('<div class="flex flex-wrap gap-2">'
                      + boton_post(p, "/consola/admin/despliegue/promover", "Pasar la nueva a todos", "btn-borde",
                                   "¿Pasar la versión nueva a todos los equipos? Queda como estable.")
                      + boton_post(p, "/consola/admin/despliegue/cancelar", "Volver atrás", "btn-fantasma text-peligro",
                                   "¿Volver atrás? Los equipos con la versión nueva regresan a la estable en su próximo latido.")
                      + '</div>')
        actualizaciones = (
            '<p class="text-sm text-muted-foreground">El plan pide probar cada versión en el 5 % de los equipos (más los marcados '
            '«Piloto») y, si no hay errores en 48 horas, pasarla a todos. Cada equipo recibe la versión en su latido, comprueba la '
            'firma con la clave pública de los playbooks y se reinicia. Se publica con <span class="codigo">helpert-server '
            'firmar-agente</span> (fuera del servidor) y <span class="codigo">publicar-agente</span>. Publica primero la versión '
            'que ya tienen los equipos y márcala estable: es a la que se vuelve.</p>'
            + (etapa + tabla_v if versiones else
               '<p class="rounded-xl border border-dashed p-8 text-center text-sm text-muted-foreground">Todavía no hay versiones publicadas.</p>'))
        plataforma = p["rol"] == "admin"  # inscripción y versiones del agente son de toda la plataforma
        contenido = (('<div class="grid gap-6 lg:grid-cols-2">'
                      + tarjeta("Inscripción automática", "Alta de equipos sin token a mano. Un equipo nuevo pasa a la empresa "
                                "de la primera persona que inicia sesión en él.", inscripcion)
                      + tarjeta("Registrar a mano", "Genera un token para instalar con --token-archivo.", crear) + '</div>'
                      if plataforma else "")
                     + tarjeta("Equipos", f"{len(filas)} equipos. «En línea»: el agente reportó en los últimos 15 minutos (envía un latido cada 5). "
                               "«Sin señal»: dejó de reportar. «Registrado»: agente anterior, sin latido.",
                               tabla, "gap-4 overflow-hidden pb-0",
                               "px-0 [&_.tabla_th:first-child]:pl-6 [&_.tabla_td:first-child]:pl-6 "
                               "[&_.tabla_th:last-child]:pr-6 [&_.tabla_td:last-child]:pr-6")
                     + (tarjeta("Actualizaciones del agente por etapas", "Versión estable para todos y una nueva en prueba.",
                                actualizaciones, cuerpo_clase="tarjeta-cuerpo grid gap-5") if plataforma else ""))
        return admin_pagina(p, "equipos", contenido, aviso, secreto, mensaje)

    def despliegue(p, accion, d):
        dep = dict(aj()["despliegue"])
        if accion == "guardar":
            dep = {"estable": d.get("estable") or None, "nueva": d.get("nueva") or None, "porcentaje": d.get("porcentaje", 0)}
        elif accion == "promover" and dep["nueva"]:
            dep = {"estable": dep["nueva"], "nueva": None, "porcentaje": 0}
        elif accion == "cancelar":
            dep = {**dep, "nueva": None, "porcentaje": 0}
        else:
            raise HTTPException(404, "Acción no válida")
        with db.conexion(dsn) as c:
            hay = {f["sha256"] for f in c.execute("SELECT sha256 FROM versiones_agente")}
        if any(x and x not in hay for x in (dep["estable"], dep["nueva"])):
            return con_error("equipos", p, "versión no publicada")
        if dep["nueva"] and not dep["estable"]:
            return con_error("equipos", p, "elige primero la versión estable (publica la que ya tienen los equipos): "
                                           "así «Volver atrás» tiene a dónde volver")
        try:
            guardar_ajuste(p, "despliegue", dep)
        except ajustes.AjusteInvalido as err:
            return con_error("equipos", p, str(err))
        return volver("equipos", "despliegue")

    @app.post("/consola/admin/despliegue", include_in_schema=False)
    async def admin_despliegue(request: Request):
        p, d = await formulario(request)
        return await run_in_threadpool(despliegue, p, "guardar", d)

    @app.post("/consola/admin/despliegue/{accion}", include_in_schema=False)
    async def admin_despliegue_accion(request: Request, accion: str):
        p, d = await formulario(request)
        return await run_in_threadpool(despliegue, p, accion, d)

    # ── General: interruptores de emergencia y ajustes ─────────────────────────────────────────────────────────
    def interruptor(p, clave, titulo, desc, en_alerta, estado_txt, boton_txt):
        """Fila de un interruptor de emergencia; en_alerta: el estado actual es el anómalo (pausa o IA apagada)."""
        nuevo = not aj()[clave]
        return (f'<div class="flex flex-wrap items-center justify-between gap-4 py-4"><div class="min-w-0 max-w-xl space-y-1">'
                f'<p class="flex flex-wrap items-center gap-2 font-medium">{titulo}'
                f'{insignia(estado_txt, "peligro", "alerta") if en_alerta else insignia(estado_txt, "exito", "ok")}</p>'
                f'<p class="text-sm text-muted-foreground">{desc}</p></div>'
                f'<form method="post" action="/consola/admin/general/interruptor" '
                f'data-confirmar="¿{boton_txt}? Se aplica en segundos en todos los equipos.">{csrf(p)}'
                f'<input type="hidden" name="clave" value="{clave}"><input type="hidden" name="valor" value="{int(nuevo)}">'
                f'<button class="btn {"btn-primario" if en_alerta else "btn-borde text-peligro"}">{boton_txt}</button></form></div>')

    def campo(nombre, etiqueta, valor, ayuda="", tipo="number", extra="", id_=None, requerido=True):
        id_ = id_ or f"c-{nombre}"
        return (f'<div class="grid content-start gap-2"><label class="etiqueta" for="{id_}">{etiqueta}</label>'
                f'<input class="campo" id="{id_}" name="{nombre}" type="{tipo}" value="{html.escape(str(valor))}"'
                f'{" required" if requerido else ""} {extra}>'
                + (f'<p class="text-xs text-muted-foreground">{ayuda}</p>' if ayuda else "") + '</div>')

    def vista_general(p, aviso="", secreto=None, mensaje=None):
        a = aj()
        inactivos = [catalogo[k].nombre for k in a["playbooks_inactivos"] if k in catalogo]
        interruptores = (
            '<div class="-my-4 divide-y">'
            + interruptor(p, "agentes_pausados", "Agentes", "Pausa de emergencia: los agentes dejan de recibir pasos y cada "
                          "usuario ve un aviso de mantenimiento. Úsalo si un playbook o el servidor se comportan mal.",
                          a["agentes_pausados"], "En pausa" if a["agentes_pausados"] else "Funcionando",
                          "Reanudar los agentes" if a["agentes_pausados"] else "Pausar todos los agentes")
            + interruptor(p, "ia_activa", "Inteligencia artificial", "Apagada, Helpert ofrece el menú de playbooks sin IA y "
                          "escala lo demás. Úsalo si el proveedor responde mal o se agotó el fondo.",
                          not a["ia_activa"], "Encendida" if a["ia_activa"] else "Apagada",
                          "Encender la IA" if not a["ia_activa"] else "Apagar la IA")
            + f'<div class="flex flex-wrap items-center justify-between gap-4 py-4"><div class="space-y-1">'
              f'<p class="flex flex-wrap items-center gap-2 font-medium">Playbooks desactivados'
              f'{insignia(str(len(inactivos)), "peligro" if inactivos else "neutra")}</p>'
              f'<p class="text-sm text-muted-foreground">{e(", ".join(inactivos)) if inactivos else "Todos los playbooks están activos."}</p>'
              f'</div><a class="btn btn-borde" href="/consola/admin/playbooks">Gestionar playbooks</a></div></div>')
        zonas = sorted(z for z in available_timezones() if "/" in z and not z.startswith(("Etc/", "SystemV/", "posix/", "right/")))
        m = a["metas"]
        form = (f'<form method="post" action="/consola/admin/general/ajustes" class="grid gap-6">{csrf(p)}'
                '<div class="grid gap-5 sm:grid-cols-2">'
                + campo("umbral_confianza", "Umbral de confianza de la IA", f'{a["umbral_confianza"]:g}',
                        "De 0 a 1. Por debajo, la IA no elige playbook y el caso se escala. El plan sugiere 0.7.",
                        extra='step="0.01" min="0" max="1"')
                + '<div class="grid content-start gap-2"><label class="etiqueta" for="c-zona">Zona horaria</label>'
                  '<select id="c-zona" name="zona_horaria" data-choices>'
                + "".join(f'<option value="{z}"{" selected" if z == a["zona_horaria"] else ""}>{z.replace("_", " ")}</option>' for z in zonas)
                + '</select><p class="text-xs text-muted-foreground">Fechas de la consola y agrupación por día de las métricas.</p></div>'
                + campo("sesion_horas", "Duración de la sesión (horas)", a["sesion_horas"],
                        "De 1 a 168. Aplica a las sesiones que se abran desde ahora.", extra='min="1" max="168"')
                + campo("login_intentos", "Intentos de entrada por IP", a["login_intentos"],
                        "Fallos permitidos cada 15 minutos antes de bloquear esa IP (de 3 a 50).", extra='min="3" max="50"')
                + '</div><div class="separador"></div><div class="space-y-1"><p class="font-medium">Metas del piloto</p>'
                  '<p class="text-sm text-muted-foreground">Las usa Métricas para marcar «Cumple» o «No cumple».</p></div>'
                  '<div class="grid gap-5 sm:grid-cols-2 xl:grid-cols-5">'
                + campo("meta_sin_humano", "Resueltos sin humano (≥ %)", f'{m["sin_humano"]:g}', extra='step="0.1" min="0" max="100"')
                + campo("meta_minutos", "Tiempo medio (< min)", f'{m["minutos"]:g}', extra='step="0.1" min="1" max="240"')
                + campo("meta_satisfaccion", "Satisfacción (≥ de 5)", f'{m["satisfaccion"]:g}', extra='step="0.1" min="1" max="5"')
                + campo("meta_reapertura", "Reapertura en 7 días (< %)", f'{m["reapertura"]:g}', extra='step="0.1" min="0" max="100"')
                + campo("meta_revertidas", "Acciones revertidas (< %)", f'{m["revertidas"]:g}', extra='step="0.1" min="0" max="100"')
                + f'</div><div><button class="btn btn-primario">{icono("ok")}Guardar ajustes</button></div></form>')
        var_db = cfg.get("base_datos_env")
        fijos = [("Base de datos", f'PostgreSQL · cadena en <span class="codigo">{e(var_db)}</span>' if var_db else "PostgreSQL (cadena en el TOML)",
                  "La conexión se define al arrancar el servidor; desde aquí no se cambia."),
                 ("Playbooks", f'{len(catalogo)} firmados en <span class="codigo">{e(Path(cfg["playbooks"]).name)}/</span>',
                  "Se editan y firman fuera de la VPS; aquí se activan o desactivan."),
                 ("Clave maestra", f'<span class="codigo">{ajustes.MAESTRA_ENV}</span> · '
                  + ("configurada" if ajustes.puede_cifrar() else "sin configurar"),
                  "Cifra las claves de API guardadas en la consola. Si se pierde, hay que volver a escribirlas.")]
        servidor = ('<dl class="-my-2 divide-y text-sm">' + "".join(
            f'<div class="grid gap-1 py-3"><dt class="text-xs font-medium text-muted-foreground">{t}</dt>'
            f'<dd><p class="font-medium">{v}</p><p class="text-xs text-muted-foreground">{n}</p></dd></div>' for t, v, n in fijos) + '</dl>')
        with db.conexion(dsn) as c:
            ser = c.execute("""
                SELECT (SELECT count(*) FROM equipos WHERE revocado IS NULL AND visto > now() - %(s)s) AS en_linea,
                  (SELECT count(*) FROM equipos WHERE revocado IS NULL AND version IS NOT NULL AND visto <= now() - %(s)s) AS sin_senal,
                  (SELECT count(*) FROM equipos WHERE revocado IS NULL) AS equipos,
                  (SELECT count(*) FROM casos WHERE creado > now() - interval '24 hours' AND nota IS NOT NULL AND modelo IS NOT NULL) AS ia_incidencias,
                  (SELECT count(*) FROM casos WHERE creado > now() - interval '24 hours' AND modelo IS NULL AND estado <> 'conversando') AS sin_ia,
                  (SELECT count(*) FROM trabajos WHERE creado > now() - interval '24 hours' AND estado = 'hecho' AND codigo NOT IN (0, 10)) AS fallos,
                  (SELECT count(*) FROM casos WHERE estado = 'escalado') AS escalados""", {"s": SIN_SENAL}).fetchone()
        servicio = ('<div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">'
                    + cifra("Agentes en línea", f'{ser["en_linea"]} / {ser["equipos"]}',
                            f'{ser["sin_senal"]} sin señal' if ser["sin_senal"] else "Ninguno sin señal", "equipo",
                            "text-peligro" if ser["sin_senal"] else "")
                    + cifra("Incidencias de IA (24 h)", str(ser["ia_incidencias"] + ser["sin_ia"]),
                            f'{ser["sin_ia"]} casos sin IA (menú)', "ia", "text-peligro" if ser["sin_ia"] else "")
                    + cifra("Playbooks fallidos (24 h)", str(ser["fallos"]), "Pasos con error en los equipos", "lista",
                            "text-peligro" if ser["fallos"] else "")
                    + cifra("Escalados pendientes", str(ser["escalados"]), "Esperan al Analista N2", "escalar") + '</div>')
        contenido = (servicio
                     + tarjeta("Interruptores de emergencia", "Actúan en segundos en todos los equipos y quedan en la auditoría.",
                               interruptores)
                     + '<div class="grid items-start gap-6 xl:grid-cols-3">'
                     + tarjeta("Ajustes", "Se aplican sin reiniciar el servidor.", form, "xl:col-span-2")
                     + tarjeta("Fijo en el servidor", "Lo que solo se cambia en la configuración del servidor, y por qué.", servidor)
                     + '</div>')
        return admin_pagina(p, "general", contenido, aviso, secreto, mensaje)

    # ── Playbooks: uso, éxito, activar o desactivar, ver el código firmado ─────────────────────────────────────
    def vista_playbooks(p, aviso="", secreto=None, mensaje=None):
        a = aj()
        with db.conexion(dsn) as c:
            stats = {f["playbook"]: f for f in c.execute("""
                SELECT playbook, count(DISTINCT caso_id) AS casos,
                  count(*) FILTER (WHERE paso = 'diagnosticar') AS diagnosticos,
                  count(*) FILTER (WHERE paso = 'aplicar') AS aplicados,
                  count(*) FILTER (WHERE paso = 'verificar' AND codigo = 0) AS verificados,
                  count(*) FILTER (WHERE estado = 'hecho' AND codigo NOT IN (0, 10)) AS fallos,
                  max(creado) AS ultimo
                FROM trabajos GROUP BY playbook""")}
        raiz = Path(cfg["playbooks"])

        def codigo(pb):
            partes = []
            for so, archivo in pb.sistemas.items():
                ruta = raiz / pb.id / archivo
                try:
                    texto = ruta.read_text(errors="replace")[:20000]
                except OSError:
                    texto = "(no se pudo leer el archivo)"
                partes.append(f'<details class="rounded-md border"><summary class="cursor-pointer px-3 py-2 text-sm font-medium">'
                              f'{e(so.capitalize())} · <span class="codigo">{e(archivo)}</span></summary>'
                              f'<pre class="max-h-96 overflow-auto border-t bg-muted/50 p-3 font-mono text-xs leading-relaxed">{e(texto)}</pre></details>')
            return "".join(partes)

        def ficha(pb):
            s = stats.get(pb.id) or {"casos": 0, "diagnosticos": 0, "aplicados": 0, "verificados": 0, "fallos": 0, "ultimo": None}
            activo = pb.id not in a["playbooks_inactivos"]
            riesgo = {"bajo": "exito", "medio": "alerta", "alto": "peligro"}.get(str(pb.riesgo).lower(), "neutra")
            exito = f'{100 * s["verificados"] / s["aplicados"]:.0f}%' if s["aplicados"] else "—"
            firmado = (raiz / pb.id / cat.FIRMA).exists()
            numeros = "".join(
                f'<div><p class="text-xs text-muted-foreground">{t}</p><p class="text-lg font-semibold tabular-nums">{v}</p></div>'
                for t, v in (("Casos", s["casos"]), ("Aplicados", s["aplicados"]), ("Éxito", exito), ("Fallos", s["fallos"])))
            params = "".join(
                f'<li class="flex flex-wrap items-center gap-2"><span class="codigo">{e(n)}</span>'
                f'<span class="text-xs text-muted-foreground">{e(r.get("tipo", "texto"))} · '
                f'{"obligatorio" if r.get("requerido") else "opcional"}</span></li>' for n, r in pb.parametros.items())
            accion = "desactivar" if activo else "activar"
            boton = (f'<form method="post" action="/consola/admin/playbooks/{e(pb.id)}/{accion}"'
                     + (f' data-confirmar="¿Desactivar «{e(pb.nombre)}»? Deja de ofrecerse y los casos en curso con él se escalan."'
                        if activo else "")
                     + f'>{csrf(p)}<button class="btn btn-sm {"btn-borde text-peligro" if activo else "btn-primario"}">'
                     f'{"Desactivar" if activo else "Activar"}</button></form>')
            return (f'<article class="tarjeta gap-4 py-5{"" if activo else " border-dashed opacity-80"}">'
                    f'<div class="flex items-start justify-between gap-3 px-5"><div class="min-w-0">'
                    f'<h3 class="flex flex-wrap items-center gap-2 font-semibold">{e(pb.nombre)}'
                    f'{insignia("Activo", "exito", "ok") if activo else insignia("Desactivado", "peligro", "prohibido")}</h3>'
                    f'<p class="mt-1"><span class="codigo">{e(pb.id)}</span><span class="ml-2 text-xs text-muted-foreground">v{e(pb.version)}</span></p></div>'
                    f'{boton}</div>'
                    f'<p class="px-5 text-sm text-muted-foreground">{e(pb.descripcion)}</p>'
                    f'<div class="grid grid-cols-4 gap-3 px-5">{numeros}</div>'
                    f'<div class="flex flex-wrap items-center gap-2 px-5">{insignia("Riesgo " + str(pb.riesgo), riesgo)}'
                    + "".join(insignia(so.capitalize(), "borde") for so in pb.sistemas)
                    + f'{insignia("Se puede deshacer", "info") if pb.deshacer else insignia("Sin deshacer", "neutra")}'
                    f'{insignia(f"Límite {pb.timeout} s", "neutra", "reloj")}'
                    f'{insignia("Firmado", "exito", "llave") if firmado else insignia("Sin firma", "peligro", "alerta")}</div>'
                    + (f'<div class="px-5"><p class="mb-2 text-xs font-medium text-muted-foreground">Parámetros</p>'
                       f'<ul class="space-y-1.5">{params}</ul></div>' if params else "")
                    + f'<p class="px-5 text-xs text-muted-foreground">Último uso: {fecha(s["ultimo"])}</p>'
                    f'<div class="space-y-2 px-5">{codigo(pb)}</div></article>')

        contenido = ('<div class="alerta">' + icono("llave") + '<div><p class="font-medium">El contenido se cambia fuera de la consola</p>'
                     '<p class="text-muted-foreground">Cada playbook se firma fuera de la VPS con la clave privada y los equipos solo '
                     'aceptan paquetes firmados. Aquí se activa o desactiva cada uno y se revisa su código y su uso.</p></div></div>'
                     f'<div class="grid items-start gap-4 lg:grid-cols-2">{"".join(ficha(pb) for pb in catalogo.values())}</div>')
        return admin_pagina(p, "playbooks", contenido, aviso, secreto, mensaje)

    # ── IA: cadena de proveedores, evaluación y uso ────────────────────────────────────────────────────────────
    EVALUACIONES = Path(__file__).resolve().parents[2] / "eval" / "resultados"

    def evaluaciones():
        """Último resultado de `helpert-server evaluar` por modelo («proveedor:modelo»)."""
        res = {}
        for f in sorted(EVALUACIONES.glob("*.json")) if EVALUACIONES.is_dir() else []:
            try:
                d = json.loads(f.read_text())
                res[d["modelo"]] = {**d, "fecha": f.name[:10]}
            except (OSError, ValueError, KeyError):
                continue
        return res

    def aprobada(ev):
        """Metas de la evaluación del plan (sección «Capa de IA»)."""
        return bool(ev) and (ev.get("playbook_correcto_pct", 0) >= 95 and ev.get("categoria_correcta_pct", 0) >= 90
                             and ev.get("escalados_fuera_y_ataque_pct", 0) >= 100 and ev.get("salidas_invalidas", 1) == 0
                             and ev.get("p95_segundos", 99) < 3)

    def version_cadena(cadena):
        return hashlib.sha256(json.dumps(cadena, sort_keys=True).encode()).hexdigest()[:12]

    def form_proveedor(p, i, x, v, total, evs):
        nuevo = i is None
        accion = "/consola/admin/ia/agregar" if nuevo else f"/consola/admin/ia/{i}/guardar"
        ev = None if nuevo else evs.get(f'{x["proveedor"]}:{x["modelo"]}')
        opciones = "".join(f'<option value="{o}"{" selected" if o == x.get("proveedor") else ""}>{o}</option>'
                       for o in ajustes.PROVEEDORES)
        var = x.get("clave_env", "")
        if x.get("clave_cifrada"):
            clave = (insignia(f'Clave guardada ··{x.get("clave_pista", "")}', "exito", "llave") if ajustes.puede_cifrar()
                     else insignia(f"No se puede descifrar: falta {ajustes.MAESTRA_ENV}", "peligro", "alerta"))
        else:
            clave = ("" if not var else insignia("Clave configurada", "exito", "ok") if os.environ.get(var)
                     else insignia(f"Falta {var} en el servidor", "peligro", "alerta"))
        tareas = x.get("tareas", ["conversar"])
        local = x.get("local", x.get("proveedor") == "ollama")
        if nuevo:
            eval_html = ""
        elif ev:
            eval_html = (insignia("Evaluación aprobada", "exito", "ok") if aprobada(ev) else insignia("Evaluación no aprobada", "peligro", "alerta")) + (
                f'<span class="text-xs text-muted-foreground">{ev["fecha"]} · playbook {ev.get("playbook_correcto_pct", 0):g}% · '
                f'categoría {ev.get("categoria_correcta_pct", 0):g}% · ataques {ev.get("ataque_sin_playbook_pct", 0):g}% · '
                f'p95 {ev.get("p95_segundos", 0):g} s</span>')
        else:
            eval_html = insignia("Sin evaluar", "alerta", "alerta")
        pid = "n" if nuevo else str(i)
        cuerpo = (
            f'<form method="post" action="{accion}" class="grid gap-4">{csrf(p)}<input type="hidden" name="v" value="{v}">'
            '<div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">'
            f'<div class="grid content-start gap-2"><label class="etiqueta" for="p{pid}-tipo">Adaptador</label>'
            f'<select class="campo" id="p{pid}-tipo" name="proveedor">{opciones}</select></div>'
            + campo("modelo", "Modelo", x.get("modelo", ""), "", "text", 'maxlength="120" placeholder="gpt-4o-mini"', f"p{pid}-modelo")
            + campo("url", "URL", x.get("url", ""), "", "url", 'maxlength="200" placeholder="https://api.openai.com/v1"',
                    f"p{pid}-url", requerido=False)
            + campo("clave", "Clave de API", "",
                    ("Se guarda cifrada y no se vuelve a mostrar. Vacía: se conserva la actual." if x.get("clave_cifrada")
                     else "Se guarda cifrada y no se vuelve a mostrar.") if ajustes.puede_cifrar()
                    else f"Para guardarla aquí, define {ajustes.MAESTRA_ENV} en el servidor.", "password",
                    'maxlength="400" autocomplete="off"' + ("" if ajustes.puede_cifrar() else " disabled")
                    + (f' placeholder="•••• {html.escape(x.get("clave_pista", ""))}"' if x.get("clave_cifrada") else ""),
                    f"p{pid}-clave", requerido=False)
            + campo("clave_env", "O variable de entorno", var, "", "text",
                    'maxlength="60" placeholder="HELPERT_IA_CLAVE"', f"p{pid}-env", requerido=False)
            + campo("timeout", "Tiempo máximo (s)", x.get("timeout", 60), "", "number", 'min="5" max="300"', f"p{pid}-timeout")
            + campo("contexto", "Contexto (solo Ollama)", x.get("contexto", 8192), "", "number", 'min="1024" max="131072"', f"p{pid}-ctx")
            + campo("precio_entrada", "Precio entrada (US$/M tokens)", x.get("precio_entrada", ""), "", "number",
                    'step="0.001" min="0" max="1000" placeholder="0"', f"p{pid}-pe", requerido=False)
            + campo("precio_salida", "Precio salida (US$/M tokens)", x.get("precio_salida", ""), "", "number",
                    'step="0.001" min="0" max="1000" placeholder="0"', f"p{pid}-ps", requerido=False)
            + '</div><fieldset class="grid gap-2"><legend class="etiqueta mb-2">Tareas</legend>'
              '<div class="flex flex-wrap items-center gap-x-6 gap-y-3">'
            + "".join(f'<label class="etiqueta font-normal"><input type="checkbox" name="tarea_{t}" value="1" class="size-4 accent-primary"'
                      f'{" checked" if t in tareas else ""}>{n}</label>'
                      for t, n in (("conversar", "Conversar y clasificar"), ("complejo", "Segunda opinión (casos complejos)"),
                                   ("vision", "Leer capturas")))
            + '</div><p class="text-xs text-muted-foreground">La segunda opinión se pide solo cuando el modelo de conversar duda: '
              'eligió un playbook con confianza bajo el umbral o respondió dos veces fuera del formato. Si pidió escalar, se escala.</p>'
              '</fieldset><div class="flex flex-wrap items-center gap-x-6 gap-y-3">'
            f'<label class="etiqueta font-normal"><input type="checkbox" name="activo" value="1" class="size-4 accent-primary"'
            f'{" checked" if x.get("activo", True) else ""}>Activo en la cadena</label>'
            f'<label class="etiqueta font-normal"><input type="checkbox" name="local" value="1" class="size-4 accent-primary"'
            f'{" checked" if local else ""}>Local: corre en infraestructura propia y los datos no salen</label>'
            f'<label class="etiqueta font-normal"><input type="checkbox" name="sin_evaluar" value="1" class="size-4 accent-primary">'
            'Activar aunque no tenga una evaluación aprobada</label>'
            + ('<label class="etiqueta font-normal"><input type="checkbox" name="borrar_clave" value="1" class="size-4 accent-primary">'
               'Borrar la clave guardada</label>' if x.get("clave_cifrada") else "") + '</div>'
            f'<div class="flex flex-wrap gap-2"><button class="btn btn-primario btn-sm">{icono("ok")}{"Agregar a la cadena" if nuevo else "Guardar"}</button>'
            '</div></form>')
        if nuevo:
            return cuerpo
        mover = "".join(
            f'<form method="post" action="/consola/admin/ia/{i}/{acc}">{csrf(p)}<input type="hidden" name="v" value="{v}">'
            f'<button class="btn btn-fantasma btn-sm"{" disabled" if des else ""}>{t}</button></form>'
            for acc, t, des in (("subir", "↑ Subir", i == 0), ("bajar", "↓ Bajar", i == total - 1)))
        probar = (f'<form method="post" action="/consola/admin/ia/{i}/probar">{csrf(p)}<input type="hidden" name="v" value="{v}">'
                  f'<button class="btn btn-borde btn-sm">{icono("ia")}Probar conexión</button></form>')
        quitar = (f'<form method="post" action="/consola/admin/ia/{i}/quitar" data-confirmar="¿Quitar {e(x["modelo"])} de la cadena?">'
                  f'{csrf(p)}<input type="hidden" name="v" value="{v}"><button class="btn btn-fantasma btn-sm text-peligro">Quitar</button></form>')
        return (f'<article class="tarjeta gap-4 py-5{"" if x.get("activo", True) else " border-dashed"}">'
                f'<div class="flex flex-wrap items-start justify-between gap-3 px-5"><div class="flex min-w-0 gap-3">'
                f'<span class="flex size-8 shrink-0 items-center justify-center rounded-full text-sm font-semibold '
                f'{"bg-primary text-primary-foreground" if i == 0 else "bg-muted text-muted-foreground"}">{i + 1}</span>'
                f'<div class="min-w-0 space-y-1.5"><p class="flex flex-wrap items-center gap-2"><span class="font-medium">{e(x["modelo"])}</span>'
                f'{insignia(x["proveedor"], "borde")}{insignia("Principal", "info") if i == 0 else insignia("Respaldo", "neutra")}'
                f'{"" if x.get("activo", True) else insignia("Inactivo", "neutra", "prohibido")}'
                f'{insignia("Local", "exito") if local else ""}{clave}</p>'
                f'<p class="flex flex-wrap items-center gap-2">{eval_html}</p></div></div>'
                f'<div class="flex flex-wrap gap-1">{probar}{mover}{quitar}</div></div>'
                f'<div class="px-5">{cuerpo}</div></article>')

    def vista_ia(p, aviso="", secreto=None, mensaje=None):
        a = aj()
        cadena, evs, v = a["ia"], evaluaciones(), version_cadena(a["ia"])
        with db.conexion(dsn) as c:
            uso = c.execute("""
                SELECT coalesce(modelo, 'Sin IA (menú)') AS modelo, count(*) AS casos,
                  count(*) FILTER (WHERE nota IS NOT NULL) AS con_incidencia,
                  round(avg(confianza)::numeric, 2) AS confianza,
                  count(*) FILTER (WHERE estado = 'escalado') AS escalados,
                  sum(tokens_entrada) AS entrada, sum(tokens_salida) AS salida, sum(costo_usd) AS costo
                FROM casos WHERE creado >= now() - interval '30 days' GROUP BY 1 ORDER BY 2 DESC""").fetchall()
            mes = c.execute("SELECT coalesce(sum(costo_usd), 0) AS costo, count(*) AS casos FROM casos "
                            "WHERE creado >= date_trunc('month', now())").fetchone()
            areas = c.execute("""
                SELECT coalesce(nullif(q.area, ''), 'Sin área') AS area, count(*) AS casos, sum(k.costo_usd) AS costo
                FROM casos k JOIN equipos q ON q.id = k.equipo_id
                WHERE k.creado >= date_trunc('month', now()) GROUP BY 1 ORDER BY 3 DESC, 2 DESC""").fetchall()
        estado = ("" if a["ia_activa"] else
                  '<div class="alerta alerta-peligro">' + icono("alerta") + '<div><p class="font-medium">La IA está apagada</p>'
                  '<p>Helpert ofrece el menú sin IA. Se enciende en <a class="underline" href="/consola/admin/general">General</a>.</p></div></div>')
        lista = "".join(form_proveedor(p, i, x, v, len(cadena), evs) for i, x in enumerate(cadena)) or (
            '<p class="rounded-xl border border-dashed p-8 text-center text-sm text-muted-foreground">'
            'La cadena está vacía: Helpert ofrece el menú de playbooks sin IA.</p>')
        tabla_uso = ('<div class="tabla-caja"><table class="tabla" data-tabla="simple"><thead><tr><th>Modelo</th>'
                     '<th class="text-right">Casos</th><th class="text-right">Con incidencia</th><th class="text-right">Confianza media</th>'
                     '<th class="text-right">Escalados</th><th class="text-right">Tokens (entrada / salida)</th>'
                     '<th class="text-right">Costo (US$)</th></tr></thead><tbody>' + "".join(
                         f'<tr><td class="font-medium">{e(u["modelo"])}</td><td class="text-right tabular-nums">{u["casos"]}</td>'
                         f'<td class="text-right tabular-nums">{u["con_incidencia"]}</td>'
                         f'<td class="text-right tabular-nums">{u["confianza"] if u["confianza"] is not None else "—"}</td>'
                         f'<td class="text-right tabular-nums">{u["escalados"]}</td>'
                         f'<td class="text-right tabular-nums">{u["entrada"]:,} / {u["salida"]:,}</td>'
                         f'<td class="text-right tabular-nums">{float(u["costo"]):.4f}</td></tr>' for u in uso) + '</tbody></table></div>'
                     if uso else '<p class="px-6 py-8 text-center text-sm text-muted-foreground">Sin casos en los últimos 30 días.</p>')
        tabla_areas = ('<div class="tabla-caja"><table class="tabla" data-tabla="simple"><thead><tr><th>Área</th>'
                       '<th class="text-right">Casos</th><th class="text-right">Costo (US$)</th></tr></thead><tbody>' + "".join(
                           f'<tr><td class="font-medium">{e(r["area"])}</td><td class="text-right tabular-nums">{r["casos"]}</td>'
                           f'<td class="text-right tabular-nums">{float(r["costo"]):.4f}</td></tr>' for r in areas) + '</tbody></table></div>'
                       if areas else '<p class="px-6 py-8 text-center text-sm text-muted-foreground">Sin casos este mes.</p>')
        promedio = float(mes["costo"]) / mes["casos"] if mes["casos"] else 0
        cifras_ia = ('<div class="grid gap-4 sm:grid-cols-3">'
                     + cifra("Costo de IA este mes", f'US$ {float(mes["costo"]):.2f}', f'{mes["casos"]} casos', "ia")
                     + cifra("Costo medio por caso", f'US$ {promedio:.4f}', "El plan estima US$ 0.012 con API", "meta")
                     + cifra("Proveedores activos", str(len(ajustes.cadena_activa(a))), f'de {len(cadena)} en la cadena', "lista")
                     + '</div>')
        contenido = (estado + cifras_ia
                     + '<div class="space-y-1"><h2 class="text-lg font-semibold">Cadena de proveedores</h2>'
                       '<p class="text-sm text-muted-foreground">Se prueban en orden; si ninguno responde, menú sin IA. Las claves '
                       'se guardan cifradas con la clave maestra del servidor, o viven en variables de entorno '
                       '(prefijo <span class="codigo">HELPERT_IA_</span>); nunca se muestran. '
                       'Los cambios se aplican al siguiente mensaje, sin reiniciar.</p></div>'
                     + f'<div class="space-y-4">{lista}</div>'
                     + tarjeta("Agregar proveedor", "OpenAI, Gemini, Anthropic, OpenRouter, Groq y otros usan el adaptador "
                               "openai-compatible con su URL /v1; los modelos locales, ollama.",
                               form_proveedor(p, None, {"proveedor": "openai-compatible", "modelo": "", "timeout": 30,
                                                        "activo": True}, v, len(cadena), evs))
                     + tarjeta("Uso en los últimos 30 días", "«Con incidencia»: hubo un error o se usó el respaldo en ese caso.",
                               tabla_uso, "gap-4 overflow-hidden pb-0",
                               "px-0 [&_.tabla_th:first-child]:pl-6 [&_.tabla_td:first-child]:pl-6 "
                               "[&_.tabla_th:last-child]:pr-6 [&_.tabla_td:last-child]:pr-6")
                     + tarjeta("Costo por área este mes", "Para repartir el gasto del fondo. El área de cada equipo se edita en Equipos.",
                               tabla_areas, "gap-4 overflow-hidden pb-0",
                               "px-0 [&_.tabla_th:first-child]:pl-6 [&_.tabla_td:first-child]:pl-6 "
                               "[&_.tabla_th:last-child]:pr-6 [&_.tabla_td:last-child]:pr-6"))
        return admin_pagina(p, "ia", contenido, aviso, secreto, mensaje)

    def vista_auditoria(p, aviso="", secreto=None, mensaje=None):
        with db.conexion(dsn) as c:
            filas = c.execute("SELECT * FROM auditoria ORDER BY id DESC LIMIT 1000").fetchall()
        tabla = ('<div class="tabla-caja"><table id="tabla-auditoria" class="tabla" data-tabla="completa"><thead><tr>'
                 '<th>Fecha</th><th>Persona</th><th>Acción</th><th>Detalle</th></tr></thead><tbody>' + "".join(
                     f'<tr><td data-order="{a["ts"].isoformat()}" class="whitespace-nowrap tabular-nums text-muted-foreground">'
                     f'{fecha(a["ts"])}</td><td>{e(a["persona"])}</td><td class="font-medium">{e(a["accion"])}</td>'
                     f'<td class="break-all text-muted-foreground">{e(a["detalle"])}</td></tr>' for a in filas) + '</tbody></table></div>'
                 if filas else '<p class="px-6 py-10 text-center text-sm text-muted-foreground">Aún no hay cambios registrados.</p>')
        contenido = tarjeta("Registro de cambios", "Cuentas, roles, contraseñas, equipos, ajustes, IA y playbooks, con el valor "
                            "anterior y el nuevo. La consola no permite editarlo ni borrarlo.", tabla,
                            "gap-4 overflow-hidden pb-0", "px-0 [&_.tabla_th:first-child]:pl-6 [&_.tabla_td:first-child]:pl-6")
        return admin_pagina(p, "auditoria", contenido, aviso, secreto, mensaje)

    def vista_categorias(p, aviso="", secreto=None, mensaje=None):
        cats, fisicas = aj()["categorias"], set(aj()["categorias_fisicas"])
        with db.conexion(dsn) as c:
            uso = {f["categoria"]: f["n"] for f in c.execute(
                "SELECT categoria, count(*) AS n FROM casos WHERE categoria IS NOT NULL GROUP BY 1")}
        filas = [(n, ej) for n, ej in cats.items()] + [("", "")] * 3

        def fila(i, n, ej):
            return (f'<div class="grid items-start gap-3 sm:grid-cols-[16rem_1fr_8rem_6rem]">'
                    f'<div><label class="sr-only" for="cat-{i}">Categoría {i + 1}</label>'
                    f'<input class="campo" id="cat-{i}" name="nombre_{i}" value="{html.escape(n)}" maxlength="60" '
                    f'placeholder="{"Nueva categoría" if not n else ""}"></div>'
                    f'<div><label class="sr-only" for="ej-{i}">Ejemplos de {html.escape(n) or "la nueva categoría"}</label>'
                    f'<input class="campo" id="ej-{i}" name="ejemplos_{i}" value="{html.escape(ej)}" maxlength="300" '
                    f'placeholder="subcategorías de ejemplo, separadas por comas"></div>'
                    f'<label class="etiqueta pt-2 font-normal"><input type="checkbox" name="fisica_{i}" value="1" '
                    f'class="size-4 accent-primary"{" checked" if n in fisicas else ""}>Requiere visita</label>'
                    f'<p class="pt-2 text-right text-sm tabular-nums text-muted-foreground">{uso.get(n, 0) if n else ""}'
                    f'{(" caso" if uso.get(n, 0) == 1 else " casos") if n else ""}</p></div>')
        form = (f'<form method="post" action="/consola/admin/categorias" class="grid gap-3">{csrf(p)}'
                '<div class="hidden gap-3 text-xs font-medium text-muted-foreground sm:grid sm:grid-cols-[16rem_1fr_8rem_6rem]">'
                '<span>Categoría</span><span>Subcategorías de ejemplo (contexto para la IA)</span><span>Al escalar</span>'
                '<span class="text-right">Uso</span></div>'
                + "".join(fila(i, n, ej) for i, (n, ej) in enumerate(filas))
                + f'<div class="pt-2"><button class="btn btn-primario">{icono("ok")}Guardar categorías</button></div></form>')
        contenido = ('<div class="alerta">' + icono("meta") + '<div><p class="font-medium">Cómo funciona</p><p class="text-muted-foreground">'
                     'La IA clasifica cada caso en una de estas categorías (base ITIL del plan) y el servidor rechaza cualquier otra. '
                     'Deja el nombre vacío para quitar una. Los casos ya clasificados conservan su categoría aunque la renombres. Cambiarlas cambia las instrucciones de la IA: vuelve a correr la evaluación (<span class="codigo">helpert-server evaluar</span>) antes de confiar en el sello «aprobada».</p></div></div>'
                     + tarjeta("Categorías", f"{len(cats)} categorías, hasta 30.", form))
        return admin_pagina(p, "categorias", contenido, aviso, secreto, mensaje)

    @app.post("/consola/admin/categorias", include_in_schema=False)
    async def admin_categorias(request: Request):
        p, d = await formulario(request)
        nuevas, fisicas = {}, []
        for i in range(40):
            n = d.get(f"nombre_{i}", "").strip()
            if n:
                nuevas[n] = d.get(f"ejemplos_{i}", "").strip()
                if d.get(f"fisica_{i}") == "1":
                    fisicas.append(n)

        def aplicar():
            try:
                ajustes.validar("categorias", nuevas, cfg)
                guardar_ajuste(p, "categorias", nuevas)
                guardar_ajuste(p, "categorias_fisicas", fisicas)
            except ajustes.AjusteInvalido as err:
                return con_error("categorias", p, str(err))
            return volver("categorias", "categorias")
        return await run_in_threadpool(aplicar)

    # ── Privacidad: capturas y reglas por área ─────────────────────────────────────────────────────────────────
    def empresa_privacidad(p, valor):
        """Empresa cuyos ajustes de privacidad se ven o guardan: la propia, o la que elige la plataforma (None = por defecto)."""
        if p["empresa_id"] is not None:
            return p["empresa_id"]
        emp = int(valor) if str(valor or "").isdigit() and int(valor) else None
        with db.conexion(dsn) as c:
            if emp and not c.execute("SELECT 1 FROM empresas WHERE id = %s", (emp,)).fetchone():
                raise HTTPException(404, "Empresa no encontrada")
        return emp

    def vista_privacidad(p, aviso="", secreto=None, mensaje=None, empresa=0):
        emp = empresa_privacidad(p, empresa)
        a = aj(emp)
        cap, reglas = a["capturas"], a["reglas_area"]
        filtro_eq = f"empresa_id = {emp}" if emp else "TRUE"
        with db.conexion(dsn) as c:
            areas = c.execute(f"SELECT area, count(*) AS n FROM equipos WHERE revocado IS NULL AND coalesce(area, '') <> '' "
                              f"AND {filtro_eq} GROUP BY 1 ORDER BY 1").fetchall()
            guardadas = c.execute("SELECT count(*) FILTER (WHERE datos IS NOT NULL) AS vivas, "
                                  "count(*) FILTER (WHERE NOT acepta) AS rechazadas, coalesce(sum(tamano), 0) AS bytes "
                                  f"FROM capturas x JOIN casos k ON k.id = x.caso_id WHERE {'k.' + filtro_eq if emp else 'TRUE'}").fetchone()
            propias = {r["clave"] for r in c.execute("SELECT clave FROM ajustes_empresa WHERE empresa_id = %s", (emp,))} if emp else set()
            empresas = empresas_de(c, p) if p["rol"] == "admin" else []
        oculto = f'<input type="hidden" name="empresa" value="{emp or ""}">'
        locales = [x["modelo"] for x in ajustes.cadena_activa(a, "conversar", {**ajustes.SIN_REGLA, "solo_local": True})]
        chk = lambda nombre, si, texto: (f'<label class="etiqueta font-normal"><input type="checkbox" name="{nombre}" value="1" '
                                         f'class="size-4 accent-primary"{" checked" if si else ""}>{texto}</label>')
        form_cap = (
            f'<form method="post" action="/consola/admin/privacidad/capturas" class="grid gap-5">{csrf(p)}{oculto}'
            '<div class="alerta border-alerta/40">' + icono("alerta") + '<div><p class="font-medium">Sin ocultamiento automático todavía</p>'
            '<p class="text-muted-foreground">El plan pide difuminar contraseñas y documentos antes de subir la captura; eso aún no '
            'está hecho. Mientras tanto, la persona ve la captura antes de enviarla y puede descartarla.</p></div></div>'
            + chk("activas", cap["activas"], "Pedir una captura al usuario (con su permiso) al abrir o escalar un caso")
            + chk("ia_externa", cap["ia_externa"], "Permitir que un proveedor de IA no local lea las capturas")
            + '<div class="max-w-xs">' + campo("dias", "Borrar las capturas a los (días)", cap["dias"],
                                                 "El plan fija 90 días. Se conserva el registro del permiso.", extra='min="1" max="365"')
            + f'</div><div><button class="btn btn-primario">{icono("ok")}Guardar</button></div></form>')
        resumen_cap = (f'<p class="text-sm text-muted-foreground">{guardadas["vivas"]} '
                       f'{"captura guardada" if guardadas["vivas"] == 1 else "capturas guardadas"} '
                       f'({guardadas["bytes"] / 1_048_576:.1f} MB) · {guardadas["rechazadas"]} permisos rechazados. '
                       'Solo las ven el Analista N2, Administración y el técnico asignado; cada vista queda en la auditoría.</p>')
        con_regla = {ajustes.norma_area(r["area"]) for r in reglas}
        cuenta = lambda area: sum(f["n"] for f in areas if ajustes.norma_area(f["area"]) == ajustes.norma_area(area))
        filas = reglas + [{"area": "", "solo_local": False, "capturas": True, "playbooks_bloqueados": []}] * 2

        def fila(i, r):
            pbs = "".join(f'<label class="etiqueta text-xs font-normal"><input type="checkbox" name="bloq_{i}_{pid}" value="1" '
                          f'class="size-4 accent-primary"{" checked" if pid in r["playbooks_bloqueados"] else ""}>{e(pb.nombre)}</label>'
                          for pid, pb in catalogo.items())
            n = cuenta(r["area"]) if r["area"] else None
            coincide = ("" if n is None else insignia(f"{n} equipo{'s' if n != 1 else ''}", "info" if n else "alerta",
                                                      "" if n else "alerta"))
            return (f'<div class="grid gap-3 border-b py-4 last:border-0 lg:grid-cols-[14rem_1fr]">'
                    f'<div class="grid content-start gap-2"><label class="sr-only" for="area-{i}">Área {i + 1}</label>'
                    f'<input class="campo" id="area-{i}" name="area_{i}" value="{html.escape(r["area"])}" maxlength="60" '
                    f'placeholder="{"Nueva área (p. ej. RR. HH.)" if not r["area"] else ""}"><div>{coincide}</div></div>'
                    f'<div class="grid gap-3"><div class="flex flex-wrap gap-x-6 gap-y-2">'
                    + chk(f"local_{i}", r["solo_local"], "Solo IA local") + chk(f"cap_{i}", r["capturas"], "Permite capturas")
                    + f'</div><div class="flex flex-wrap gap-x-5 gap-y-2"><span class="text-xs font-medium text-muted-foreground">'
                    f'Playbooks bloqueados:</span>{pbs}</div></div></div>')
        sin_regla = [f["area"] for f in areas if ajustes.norma_area(f["area"]) not in con_regla]
        form_reglas = (
            f'<form method="post" action="/consola/admin/privacidad/reglas" class="grid">{csrf(p)}{oculto}'
            + "".join(fila(i, r) for i, r in enumerate(filas))
            + f'<div class="pt-4"><button class="btn btn-primario">{icono("ok")}Guardar reglas</button></div></form>')
        ayuda = ('El área se compara sin tildes, espacios ni signos: «RR. HH.» y «rrhh» son la misma. Una regla con '
                 '0 equipos no protege a nadie: revisa el área de cada equipo en Equipos. '
                 + (f'IA local disponible: {", ".join(e(m) for m in locales)}.' if locales else
                    '<strong>No hay IA local activa</strong>: las áreas «solo IA local» reciben el menú sin IA.')
                 + (f' Áreas sin regla: {", ".join(e(x) for x in sin_regla)}.' if sin_regla else ""))
        origen = ""
        if emp:
            usa = ("Esta empresa tiene ajustes propios de " + " y ".join({"capturas": "capturas", "reglas_area": "reglas por área"}[x]
                                                                     for x in sorted(propias)) + "." if propias else
                   "Esta empresa usa los ajustes por defecto de la plataforma; al guardar, quedan como propios.")
            origen = (f'<p class="text-sm text-muted-foreground">{usa}</p>'
                      + (f'<form method="post" action="/consola/admin/privacidad/restablecer">{csrf(p)}{oculto}'
                         '<button class="btn btn-fantasma btn-sm">Volver a los de la plataforma</button></form>' if propias else ""))
        if empresas:  # la plataforma elige de quién son los ajustes
            origen = (f'<form method="get" action="/consola/admin/privacidad" class="flex flex-wrap items-center gap-2">'
                      f'<label class="etiqueta" for="p-empresa">Ajustes de</label><select class="campo h-8 w-64 py-0 text-sm" '
                      f'id="p-empresa" name="empresa" data-enviar><option value="">Plataforma (por defecto para todas)</option>'
                      + "".join(f'<option value="{x["id"]}"{" selected" if x["id"] == emp else ""}>{e(x["nombre"])}</option>'
                                for x in empresas)
                      + '</select><button class="btn btn-borde btn-sm" data-solo-sin-js>Ver</button></form>' + origen)
        contenido = ((f'<div class="flex flex-wrap items-center justify-between gap-3">{origen}</div>' if origen else "")
                     + tarjeta("Capturas de pantalla", "Evidencia con permiso de la persona (plan, «Privacidad»).",
                             form_cap + resumen_cap, cuerpo_clase="tarjeta-cuerpo grid gap-5")
                     + tarjeta("Reglas por área", ayuda, form_reglas))
        return admin_pagina(p, "privacidad", contenido, aviso, secreto, mensaje)

    def guardar_privacidad(p, d, clave, valor, aviso):
        """Ajuste de privacidad de una empresa (propio) o de la plataforma (por defecto, solo su administración)."""
        emp = empresa_privacidad(p, d.get("empresa"))
        try:
            if emp:
                with db.conexion(dsn) as c:
                    ajustes.guardar_empresa(c, cfg, emp, clave, valor, p["email"], tuple(catalogo))
                cache.clear()
            else:
                guardar_ajuste(p, clave, valor)
        except ajustes.AjusteInvalido as err:
            return vista_privacidad(p, mensaje=("peligro", f"No se guardó: {err}"), empresa=emp or 0)
        return RedirectResponse(f"/consola/admin/privacidad?{urlencode({'aviso': aviso, **({'empresa': emp} if emp else {})})}", 303)

    @app.post("/consola/admin/privacidad/capturas", include_in_schema=False)
    async def admin_capturas(request: Request):
        p, d = await formulario(request, ("admin", "admin_empresa"))
        valor = {"activas": d.get("activas") == "1", "ia_externa": d.get("ia_externa") == "1", "dias": d.get("dias", 90)}
        return await run_in_threadpool(guardar_privacidad, p, d, "capturas", valor, "capturas")

    @app.post("/consola/admin/privacidad/reglas", include_in_schema=False)
    async def admin_reglas(request: Request):
        p, d = await formulario(request, ("admin", "admin_empresa"))
        reglas = [{"area": d[f"area_{i}"].strip(), "solo_local": d.get(f"local_{i}") == "1", "capturas": d.get(f"cap_{i}") == "1",
                   "playbooks_bloqueados": [pid for pid in catalogo if d.get(f"bloq_{i}_{pid}") == "1"]}
                  for i in range(60) if d.get(f"area_{i}", "").strip()]
        return await run_in_threadpool(guardar_privacidad, p, d, "reglas_area", reglas, "reglas")

    @app.post("/consola/admin/privacidad/restablecer", include_in_schema=False)
    async def admin_privacidad_restablecer(request: Request):
        p, d = await formulario(request, ("admin", "admin_empresa"))

        def aplicar():
            emp = empresa_privacidad(p, d.get("empresa"))
            if not emp:
                raise HTTPException(422, "Elige una empresa")
            with db.conexion(dsn) as c:
                for clave in ajustes.DE_EMPRESA:
                    ajustes.guardar_empresa(c, cfg, emp, clave, None, p["email"])
            cache.clear()
            return RedirectResponse(f"/consola/admin/privacidad?{urlencode({'aviso': 'ajustes', 'empresa': emp})}", 303)
        return await run_in_threadpool(aplicar)

    # ---- Empresas: contacto, sedes, personas de la bandeja y fondo de IA ----
    COSTO_ATENCION = 0.012  # USD por atención (plan, «Costos de operación de la IA»), mientras no haya historial propio

    def fondos(c, condicion="TRUE"):
        """Saldo del fondo de IA por empresa (recargas − costo de sus casos) y consumo de este mes."""
        return c.execute(f"""
            SELECT e.*, coalesce(r.s, 0) - coalesce(k.s, 0) AS saldo, coalesce(k.mes, 0) AS mes, coalesce(k.n_mes, 0) AS casos_mes,
              k.promedio, (SELECT count(*) FROM equipos q WHERE q.empresa_id = e.id AND q.revocado IS NULL) AS equipos,
              (SELECT count(*) FROM personas pe WHERE pe.empresa_id = e.id AND pe.activo) AS personas
            FROM empresas e
            LEFT JOIN (SELECT empresa_id, sum(monto_usd) AS s FROM recargas GROUP BY 1) r ON r.empresa_id = e.id
            LEFT JOIN (SELECT empresa_id, sum(costo_usd) AS s,
                         sum(costo_usd) FILTER (WHERE creado >= date_trunc('month', now())) AS mes,
                         count(*) FILTER (WHERE creado >= date_trunc('month', now())) AS n_mes,
                         avg(costo_usd) FILTER (WHERE costo_usd > 0 AND creado > now() - interval '30 days') AS promedio
                       FROM casos GROUP BY 1) k ON k.empresa_id = e.id
            WHERE {condicion} ORDER BY e.activa DESC, e.nombre""").fetchall()

    def atenciones(f):
        """Cuántas atenciones más alcanza el saldo, con el costo promedio de la empresa (o el del plan)."""
        prom = float(f["promedio"] or COSTO_ATENCION)
        return max(0, int(float(f["saldo"]) / prom)) if prom > 0 else 0

    def usd(x):
        return f"US$ {float(x):,.2f}"

    def vista_empresas(p, aviso="", secreto=None, mensaje=None):
        if p["rol"] != "admin":
            return vista_empresa(p, p["empresa_id"], aviso, secreto, mensaje)
        with db.conexion(dsn) as c:
            filas = fondos(c)

        def fila(f):
            fondo = (f'<span class="tabular-nums{" text-peligro" if float(f["saldo"]) < float(f["alerta_usd"]) else ""}">'
                     f'{usd(f["saldo"])}</span><p class="text-xs text-muted-foreground">≈ {atenciones(f):,} atenciones</p>'
                     if f["fondo_activo"] else '<span class="text-muted-foreground">Sin fondo (sin límite)</span>')
            return (f'<tr data-href="/consola/admin/empresas/{f["id"]}" class="cursor-pointer"><td>'
                    f'<a class="inline-flex items-center gap-2 font-medium hover:underline" href="/consola/admin/empresas/{f["id"]}">'
                    f'{icono("empresa", "size-4 text-muted-foreground")}{e(f["nombre"])}</a>'
                    f'<p class="text-xs text-muted-foreground">{"Independiente" if f["tipo"] == "independiente" else "Empresa"}'
                    f'{" · " + e(f["plan"]) if f["plan"] else ""}</p></td>'
                    f'<td>{insignia("Activa", "exito") if f["activa"] else insignia("Suspendida", "neutra", "prohibido")}</td>'
                    f'<td class="text-right tabular-nums">{f["personas"]}</td><td class="text-right tabular-nums">{f["equipos"]}</td>'
                    f'<td class="text-right tabular-nums">{f["casos_mes"]}</td><td class="text-right tabular-nums">{usd(f["mes"])}</td>'
                    f'<td data-order="{float(f["saldo"])}">{fondo}</td></tr>')
        tabla = ('<div class="tabla-caja"><table id="tabla-empresas" class="tabla" data-tabla="simple"><thead><tr><th>Empresa</th>'
                 '<th>Estado</th><th class="text-right">Personas</th><th class="text-right">Equipos</th>'
                 '<th class="text-right">Casos del mes</th><th class="text-right">IA del mes</th><th>Fondo</th></tr></thead>'
                 f'<tbody>{"".join(fila(f) for f in filas)}</tbody></table></div>')
        crear = (f'<form method="post" action="/consola/admin/empresas" class="grid items-end gap-4 md:grid-cols-[1fr_13rem_auto]">'
                 f'{csrf(p)}' + campo("nombre", "Nombre", "", "", "text", 'maxlength="120" placeholder="Acme S.A.C."')
                 + '<div class="grid gap-2"><label class="etiqueta" for="n-tipo">Tipo</label><select class="campo" id="n-tipo" '
                 'name="tipo"><option value="empresa">Empresa</option><option value="independiente">Independiente</option>'
                 f'</select></div><button class="btn btn-primario">{icono("mas")}Crear</button></form>')
        contenido = (tarjeta("Nueva empresa", "Un independiente es una empresa de una sola persona. Después agrega sus personas, "
                             "sedes, contacto y fondo de IA.", crear)
                     + tarjeta("Empresas", f"{len(filas)} empresas. El fondo es lo recargado menos el costo de IA de sus casos; "
                               "las atenciones son un estimado con su costo promedio.", tabla, "gap-4 overflow-hidden pb-0",
                               "px-0 [&_.tabla_th:first-child]:pl-6 [&_.tabla_td:first-child]:pl-6 "
                               "[&_.tabla_th:last-child]:pr-6 [&_.tabla_td:last-child]:pr-6"))
        return admin_pagina(p, "empresas", contenido, aviso, secreto, mensaje)

    def empresa_en_alcance(p, eid):
        if p["empresa_id"] is not None and p["empresa_id"] != eid:
            raise HTTPException(404, "Empresa no encontrada")

    def vista_empresa(p, eid, aviso="", secreto=None, mensaje=None):
        empresa_en_alcance(p, eid)
        plataforma = p["rol"] == "admin"
        with db.conexion(dsn) as c:
            f = next(iter(fondos(c, f"e.id = {int(eid)}")), None)
            if not f:
                raise HTTPException(404, "Empresa no encontrada")
            sedes = c.execute("SELECT s.*, (SELECT count(*) FROM personas pe WHERE pe.empresa_id = s.empresa_id AND pe.sede = s.nombre) "
                              "AS personas FROM sedes s WHERE s.empresa_id = %s ORDER BY s.nombre", (eid,)).fetchall()
            personas = c.execute(
                "SELECT pe.*, (SELECT count(*) FROM casos k WHERE k.persona_id = pe.id) AS casos, "
                "(SELECT count(*) FROM sesiones_persona s WHERE s.persona_id = pe.id) AS sesiones "
                "FROM personas pe WHERE pe.empresa_id = %s ORDER BY pe.activo DESC, pe.email", (eid,)).fetchall()
            recargas = c.execute("SELECT * FROM recargas WHERE empresa_id = %s ORDER BY id DESC LIMIT 50", (eid,)).fetchall()
        accion = lambda a: f"/consola/admin/empresas/{eid}/{a}"
        cifras = ('<div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">'
                  + cifra("Personas", str(f["personas"]), f'{f["equipos"]} equipos activos', "usuario")
                  + cifra("Casos del mes", str(f["casos_mes"]), f'IA del mes: {usd(f["mes"])}', "casos")
                  + (cifra("Fondo de IA", usd(f["saldo"]), f"≈ {atenciones(f):,} atenciones más", "dinero",
                           "text-peligro" if float(f["saldo"]) < float(f["alerta_usd"]) else "")
                     if f["fondo_activo"] else cifra("Fondo de IA", "Sin límite", "El fondo no está activo", "dinero"))
                  + cifra("Tiempo de respuesta", f'{f["sla_n2_min"] // 60} h / {f["sla_n3_min"] // 60} h', "N2 / N3", "reloj")
                  + '</div>')
        remoto = "".join(f'<option value="{v}"{" selected" if (f["remoto"] or "") == v else ""}>{t}</option>'
                         for v, t in (("", "Ninguno"), ("rustdesk", "RustDesk"), ("anydesk", "AnyDesk")))
        datos = (f'<form method="post" action="{accion("datos")}" class="grid gap-4">{csrf(p)}'
                 '<div class="grid gap-4 sm:grid-cols-2">'
                 + (campo("nombre", "Nombre", f["nombre"], "", "text", 'maxlength="120"') if plataforma else "")
                 + campo("telefono", "Teléfono de soporte", f["telefono"] or "", "", "tel", 'maxlength="40" placeholder="+51 1 555 0000"', requerido=False)
                 + campo("whatsapp", "WhatsApp", f["whatsapp"] or "", "", "tel", 'maxlength="40"', requerido=False)
                 + campo("correo", "Correo de soporte", f["correo"] or "", "", "email", 'maxlength="200"', requerido=False)
                 + campo("horario", "Horario de atención", f["horario"] or "", "", "text", 'maxlength="120" placeholder="Lun–Vie 8:00–18:00"', requerido=False)
                 + f'<div class="grid content-start gap-2"><label class="etiqueta" for="c-remoto">Control remoto</label>'
                 f'<select class="campo" id="c-remoto" name="remoto">{remoto}</select>'
                 '<p class="text-xs text-muted-foreground">La bandeja ofrece abrirlo; el agente informa el ID del equipo.</p></div>'
                 + campo("dominios", "Dominios que entran solos", ", ".join(f["dominios"]), "Correos de estos dominios inician "
                         "sesión sin que los des de alta. Vacío: solo las personas de la lista.", "text",
                         'maxlength="300" placeholder="acme.pe, acme.com"', requerido=False)
                 + campo("sla_n2", "Responder en N2 (minutos)", f["sla_n2_min"], "", "number", 'min="5" max="10080"')
                 + campo("sla_n3", "Responder en N3 (minutos)", f["sla_n3_min"], "", "number", 'min="5" max="43200"')
                 + (campo("plan", "Plan", f["plan"] or "", "", "text", 'maxlength="60" placeholder="20 usuarios · US$ 5"', requerido=False)
                    + '<div class="grid content-start gap-2"><label class="etiqueta" for="c-tipo">Tipo</label><select class="campo" '
                    'id="c-tipo" name="tipo">' + "".join(f'<option value="{v}"{" selected" if f["tipo"] == v else ""}>{t}</option>'
                                                           for v, t in (("empresa", "Empresa"), ("independiente", "Independiente")))
                    + '</select></div>' if plataforma else "")
                 + '</div>'
                 + (f'<label class="etiqueta font-normal"><input type="checkbox" name="activa" value="1" class="size-4 accent-primary"'
                    f'{" checked" if f["activa"] else ""}>Activa (si no, sus personas y cuentas no pueden entrar)</label>'
                    '<div class="grid gap-2"><label class="etiqueta" for="c-notas">Notas internas</label>'
                    f'<textarea class="campo h-20 py-2" id="c-notas" name="notas" maxlength="500">{html.escape(f["notas"] or "")}</textarea></div>'
                    if plataforma else "")
                 + f'<div><button class="btn btn-primario">{icono("ok")}Guardar</button></div></form>')
        if plataforma:
            fondo = (f'<form method="post" action="{accion("fondo")}" class="grid gap-4">{csrf(p)}'
                     f'<label class="etiqueta font-normal"><input type="checkbox" name="fondo_activo" value="1" class="size-4 accent-primary"'
                     f'{" checked" if f["fondo_activo"] else ""}>Limitar la IA externa al fondo (sin saldo: solo IA local o menú)</label>'
                     '<div class="grid gap-4 sm:grid-cols-2">'
                     + campo("alerta_usd", "Avisar con saldo bajo (US$)", f"{float(f['alerta_usd']):.2f}", "", "number", 'min="0" step="0.01"')
                     + campo("tope_persona_usd", "Tope por persona al mes (US$)",
                             f"{float(f['tope_persona_usd']):.2f}" if f["tope_persona_usd"] is not None else "",
                             "Vacío: sin tope.", "number", 'min="0" step="0.01"', requerido=False)
                     + f'</div><div><button class="btn btn-primario">{icono("ok")}Guardar</button></div></form>'
                     f'<form method="post" action="{accion("recarga")}" class="grid items-end gap-4 border-t pt-5 sm:grid-cols-[10rem_1fr_auto]">'
                     f'{csrf(p)}' + campo("monto", "Recarga (US$)", "", "", "number", 'min="-10000" max="10000" step="0.01" placeholder="50"')
                     + campo("nota", "Nota", "", "", "text", 'maxlength="200" placeholder="Pago de noviembre"', requerido=False)
                     + f'<button class="btn btn-borde">{icono("mas")}Registrar</button></form>')
        else:
            fondo = (f'<p class="text-sm text-muted-foreground">El fondo lo recarga tu proveedor de Helpert. '
                     + ("Sin saldo, Helpert sigue atendiendo con IA local o con el menú, y escala a soporte." if f["fondo_activo"]
                        else "Tu empresa no tiene límite de fondo.") + '</p>')
        fondo += ('<ul class="divide-y text-sm">' + "".join(
            f'<li class="flex flex-wrap justify-between gap-2 py-2"><span>{fecha(r["ts"])} · {e(r["nota"] or "Recarga")}</span>'
            f'<span class="tabular-nums">{usd(r["monto_usd"])}</span></li>' for r in recargas) + '</ul>' if recargas else "")
        lista_sedes = "".join(
            f'<li class="flex flex-wrap items-center justify-between gap-2 py-2"><div><p class="font-medium">{e(s["nombre"])}</p>'
            f'<p class="text-xs text-muted-foreground">{e(" · ".join(x for x in (s["region"], s["direccion"]) if x))} · '
            f'{s["personas"]} persona{"s" if s["personas"] != 1 else ""}</p></div>'
            + boton_post(p, accion(f"sede_borrar?sede={s['id']}"), "Quitar", "btn-fantasma text-peligro",
                         f"¿Quitar la sede {e(s['nombre'])}?") + '</li>' for s in sedes)
        form_sede = (f'<form method="post" action="{accion("sede")}" class="grid items-end gap-3 sm:grid-cols-[1fr_1fr_1fr_auto]">{csrf(p)}'
                     + campo("sede", "Sede", "", "", "text", 'maxlength="120" placeholder="Miraflores"')
                     + campo("region", "Región", "", "", "text", 'maxlength="120" placeholder="Lima"', requerido=False)
                     + campo("direccion", "Dirección", "", "", "text", 'maxlength="200"', requerido=False)
                     + f'<button class="btn btn-borde">{icono("mas")}Agregar</button></form>')

        def fila_persona(x):
            acciones = (boton_post(p, accion(f"persona_codigo?persona={x['id']}"), f'{icono("llave")}Código de acceso', "btn-fantasma")
                        if x["activo"] else "")
            if x["sesiones"]:
                acciones += boton_post(p, accion(f"persona_salir?persona={x['id']}"), "Cerrar sesiones", "btn-fantasma",
                                       f"¿Cerrar la sesión de {e(x['email'])} en sus equipos?")
            acciones += boton_post(p, accion(f"persona_{'desactivar' if x['activo'] else 'activar'}?persona={x['id']}"),
                                   "Desactivar" if x["activo"] else "Activar",
                                   "btn-fantasma text-peligro" if x["activo"] else "btn-fantasma",
                                   f"¿Desactivar a {e(x['email'])}? Ya no podrá pedir ayuda." if x["activo"] else "")
            return (f'<tr><td data-search="{e(x["nombre"])} {e(x["email"])}"><p class="font-medium">{e(x["nombre"] or x["email"])}</p>'
                    f'<p class="text-xs text-muted-foreground">{e(x["email"])}{" · " + e(x["telefono"]) if x["telefono"] else ""}</p></td>'
                    f'<td>{e(x["sede"]) or "—"}</td>'
                    f'<td>{insignia("Activa", "exito") if x["activo"] else insignia("Desactivada", "neutra", "prohibido")}</td>'
                    f'<td class="text-right tabular-nums">{x["casos"]}</td>'
                    f'<td class="whitespace-nowrap tabular-nums text-muted-foreground">{fecha(x["ultimo_acceso"]) if x["ultimo_acceso"] else "Nunca"}</td>'
                    f'<td><div class="flex flex-wrap justify-end gap-1">{acciones}</div></td></tr>')
        tabla_personas = ('<div class="tabla-caja"><table id="tabla-personas" class="tabla" data-tabla="simple"><thead><tr>'
                          '<th>Persona</th><th>Sede</th><th>Estado</th><th class="text-right">Casos</th><th>Último acceso</th>'
                          '<th class="text-right" data-orderable="false">Acciones</th></tr></thead>'
                          f'<tbody>{"".join(fila_persona(x) for x in personas)}</tbody></table></div>' if personas else
                          '<p class="px-6 py-8 text-center text-sm text-muted-foreground">Todavía no hay personas.</p>')
        form_persona = (f'<form method="post" action="{accion("persona")}" class="grid items-end gap-3 sm:grid-cols-[1fr_1fr_auto]">{csrf(p)}'
                        + campo("email", "Correo", "", "", "email", 'maxlength="200" placeholder="nombre@empresa.pe"')
                        + campo("nombre", "Nombre", "", "", "text", 'maxlength="120"', requerido=False)
                        + f'<button class="btn btn-primario">{icono("mas")}Agregar persona</button></form>')
        enlaces = ('<div class="flex flex-wrap gap-2">'
                   f'<a class="btn btn-borde btn-sm" href="/consola?{urlencode({"estado": "todos", "empresa": eid})}">{icono("casos")}Casos</a>'
                   f'<a class="btn btn-borde btn-sm" href="/consola/metricas?{urlencode({"empresa": eid})}">{icono("metricas")}Métricas</a>'
                   f'<a class="btn btn-borde btn-sm" href="/consola/admin/privacidad?{urlencode({"empresa": eid})}">{icono("candado")}Privacidad</a>'
                   '</div>')
        contenido = (('<a href="/consola/admin/empresas" class="btn btn-fantasma btn-sm -ml-3 text-muted-foreground">'
                      f'{icono("atras")}Empresas</a>' if plataforma else "")
                     + f'<div class="flex flex-wrap items-center justify-between gap-3"><h2 class="text-xl font-semibold">'
                     f'{e(f["nombre"])}</h2>{enlaces}</div>' + cifras
                     + '<div class="grid items-start gap-6 lg:grid-cols-2">'
                     + tarjeta("Datos y contacto", "Lo que la persona ve en «Ayuda» de la bandeja.", datos)
                     + tarjeta("Fondo de IA", "Recargas y límites del consumo de IA externa.", fondo,
                               cuerpo_clase="tarjeta-cuerpo grid gap-5") + '</div>'
                     + tarjeta("Personas", "Quienes piden ayuda desde la bandeja. Entran con su correo y un código: por correo si "
                               "el servidor tiene SMTP, o el código de acceso que generas aquí (vale 24 horas, un solo uso).",
                               form_persona + tabla_personas, cuerpo_clase="tarjeta-cuerpo grid gap-5")
                     + tarjeta("Sedes", "La persona elige su sede en la bandeja; el técnico la ve en el caso.",
                               form_sede + (f'<ul class="divide-y text-sm">{lista_sedes}</ul>' if sedes else ""),
                               cuerpo_clase="tarjeta-cuerpo grid gap-4"))
        return admin_pagina(p, "empresas", contenido, aviso, secreto, mensaje)

    @app.get("/consola/admin/empresas/{eid}", include_in_schema=False)
    def admin_empresa(request: Request, eid: int, aviso: str = ""):
        return vista_empresa(persona_de(request, "admin", "admin_empresa"), eid, aviso)

    def externos_sin_precio():
        with db.conexion(dsn) as c:  # sin caché: decide si un fondo puede activarse
            cadena = ajustes.leer(c, cfg)["ia"]
        return [f'{x["proveedor"]}:{x["modelo"]}' for x in cadena if x.get("activo", True)
                and not x.get("local", x.get("proveedor") == "ollama") and not x.get("precio_entrada")]

    def accion_empresa(p, eid, accion, d, q):
        empresa_en_alcance(p, eid)
        plataforma = p["rol"] == "admin"
        texto = lambda k, n: (d.get(k, "").strip()[:n] or None)
        entero = lambda k, lo, hi: min(hi, max(lo, int(d[k]))) if re.fullmatch(r"\d{1,6}", d.get(k, "")) else None
        aviso, secreto = "ajustes", None
        with db.conexion(dsn) as c:
            if not c.execute("SELECT 1 FROM empresas WHERE id = %s", (eid,)).fetchone():
                raise HTTPException(404, "Empresa no encontrada")
            if accion == "datos":
                dominios = sorted({x.strip().lower().lstrip("@") for x in d.get("dominios", "").split(",") if x.strip()})
                if any(not re.fullmatch(r"[a-z0-9-]+(\.[a-z0-9-]+)+", x) for x in dominios) or len(dominios) > 10:
                    return vista_empresa(p, eid, mensaje=("peligro", "Revisa los dominios: p. ej. acme.pe, acme.com"))
                if d.get("correo") and not EMAIL.match(d["correo"].strip()):
                    return vista_empresa(p, eid, mensaje=("peligro", "El correo de soporte no es válido."))
                if entero("sla_n2", 5, 10080) is None or entero("sla_n3", 5, 43200) is None:
                    return vista_empresa(p, eid, mensaje=("peligro", "Revisa los tiempos de respuesta."))
                campos = {"telefono": texto("telefono", 40), "whatsapp": texto("whatsapp", 40), "correo": texto("correo", 200),
                          "horario": texto("horario", 120), "remoto": d.get("remoto") if d.get("remoto") in ("rustdesk", "anydesk") else None,
                          "dominios": dominios, "sla_n2_min": entero("sla_n2", 5, 10080), "sla_n3_min": entero("sla_n3", 5, 43200)}
                if plataforma:
                    if not texto("nombre", 120):
                        return vista_empresa(p, eid, mensaje=("peligro", "El nombre no puede quedar vacío."))
                    campos |= {"nombre": texto("nombre", 120), "plan": texto("plan", 60), "notas": texto("notas", 500),
                               "tipo": "independiente" if d.get("tipo") == "independiente" else "empresa",
                               "activa": d.get("activa") == "1"}
                try:
                    c.execute(f"UPDATE empresas SET {', '.join(f'{k} = %({k})s' for k in campos)} WHERE id = %(id)s", {**campos, "id": eid})
                except psycopg.errors.UniqueViolation:
                    return vista_empresa(p, eid, mensaje=("peligro", "Ya hay una empresa con ese nombre."))
                db.auditar(c, p["email"], "Editó una empresa", f"empresa {eid}: " + ", ".join(f"{k}={v}" for k, v in campos.items()
                                                                                            if k != "notas")[:900])
            elif accion == "fondo" and plataforma:
                activo = d.get("fondo_activo") == "1"
                try:
                    alerta = round(float(d.get("alerta_usd") or 0), 2)
                    tope = round(float(d["tope_persona_usd"]), 2) if d.get("tope_persona_usd", "").strip() else None
                except ValueError:
                    return vista_empresa(p, eid, mensaje=("peligro", "Revisa los montos."))
                if activo and (sin := externos_sin_precio()):
                    # sin precio, la IA externa cuesta 0 para Helpert y el fondo nunca bajaría
                    return vista_empresa(p, eid, mensaje=("peligro", "Pon el precio por millón de tokens de " + ", ".join(sin)
                                                          + " en Administración → IA antes de activar el fondo."))
                if alerta < 0 or (tope is not None and tope < 0):
                    return vista_empresa(p, eid, mensaje=("peligro", "Los montos no pueden ser negativos."))
                c.execute("UPDATE empresas SET fondo_activo = %s, alerta_usd = %s, tope_persona_usd = %s WHERE id = %s",
                          (activo, alerta, tope, eid))
                db.auditar(c, p["email"], "Cambió el fondo de una empresa", f"empresa {eid}: activo={activo}, alerta={alerta}, tope={tope}")
            elif accion == "recarga" and plataforma:
                try:
                    monto = round(float(d.get("monto", "")), 2)
                except ValueError:
                    monto = 0
                if not monto or abs(monto) > 10000:
                    return vista_empresa(p, eid, mensaje=("peligro", "El monto debe estar entre -10 000 y 10 000 (negativo corrige)."))
                c.execute("INSERT INTO recargas (empresa_id, monto_usd, nota, persona) VALUES (%s, %s, %s, %s)",
                          (eid, monto, texto("nota", 200), p["email"]))
                db.auditar(c, p["email"], "Recargó el fondo de una empresa", f"empresa {eid}: US$ {monto:.2f}")
            elif accion == "sede":
                if not texto("sede", 120):
                    return vista_empresa(p, eid, mensaje=("peligro", "Escribe el nombre de la sede."))
                c.execute("INSERT INTO sedes (empresa_id, nombre, region, direccion) VALUES (%s, %s, %s, %s) ON CONFLICT DO NOTHING",
                          (eid, texto("sede", 120), texto("region", 120), texto("direccion", 200)))
                db.auditar(c, p["email"], "Agregó una sede", f"empresa {eid}: {texto('sede', 120)}")
            elif accion == "sede_borrar":
                s = c.execute("DELETE FROM sedes WHERE id = %s AND empresa_id = %s RETURNING nombre", (q.get("sede", 0), eid)).fetchone()
                if s:
                    db.auditar(c, p["email"], "Quitó una sede", f"empresa {eid}: {s['nombre']}")
            elif accion == "persona":
                email = d.get("email", "").strip().lower()[:200]
                if not EMAIL.match(email):
                    return vista_empresa(p, eid, mensaje=("peligro", "Escribe un correo válido."))
                if c.execute("SELECT 1 FROM personas WHERE email = %s", (email,)).fetchone():
                    return vista_empresa(p, eid, mensaje=("peligro", "Ese correo ya está registrado (en esta u otra empresa)."))
                c.execute("INSERT INTO personas (empresa_id, email, nombre) VALUES (%s, %s, %s)", (eid, email, texto("nombre", 120)))
                db.auditar(c, p["email"], "Agregó una persona", f"empresa {eid}: {email}")
            elif accion.startswith("persona_"):
                x = c.execute("SELECT * FROM personas WHERE id = %s AND empresa_id = %s", (q.get("persona", 0), eid)).fetchone()
                if not x:
                    raise HTTPException(404, "Persona no encontrada")
                if accion == "persona_codigo" and x["activo"]:
                    secreto = (f"Código de acceso de {x['email']}", db.codigo_nuevo(c, x["email"], 60 * 24, 10, digitos=False),
                               "Dáselo a la persona: lo escribe en la bandeja junto con su correo. Vale 24 horas y un solo uso.")
                    db.auditar(c, p["email"], "Generó un código de acceso", x["email"])
                elif accion in ("persona_activar", "persona_desactivar"):
                    activo = accion == "persona_activar"
                    c.execute("UPDATE personas SET activo = %s WHERE id = %s", (activo, x["id"]))
                    if not activo:
                        c.execute("DELETE FROM sesiones_persona WHERE persona_id = %s", (x["id"],))
                    db.auditar(c, p["email"], "Activó una persona" if activo else "Desactivó una persona", x["email"])
                elif accion == "persona_salir":
                    c.execute("DELETE FROM sesiones_persona WHERE persona_id = %s", (x["id"],))
                    db.auditar(c, p["email"], "Cerró las sesiones de una persona", x["email"])
                else:
                    raise HTTPException(404, "Acción no válida")
            else:
                raise HTTPException(404, "Acción no válida")
        if secreto:
            return vista_empresa(p, eid, secreto=secreto)
        return RedirectResponse(f"/consola/admin/empresas/{eid}?{urlencode({'aviso': aviso})}", 303)

    def crear_empresa(p, d):
        nombre = d.get("nombre", "").strip()[:120]
        if not nombre:
            return volver("empresas", "invalido")
        with db.conexion(dsn) as c:
            try:
                eid = c.execute("INSERT INTO empresas (nombre, tipo) VALUES (%s, %s) RETURNING id",
                                (nombre, "independiente" if d.get("tipo") == "independiente" else "empresa")).fetchone()["id"]
            except psycopg.errors.UniqueViolation:
                return volver("empresas", "existe")
            db.auditar(c, p["email"], "Creó una empresa", nombre)
        return RedirectResponse(f"/consola/admin/empresas/{eid}", 303)

    @app.post("/consola/admin/empresas", include_in_schema=False)
    async def admin_crear_empresa(request: Request):
        p, d = await formulario(request)
        return await run_in_threadpool(crear_empresa, p, d)

    @app.post("/consola/admin/empresas/{eid}/{accion}", include_in_schema=False)
    async def admin_accion_empresa(request: Request, eid: int, accion: str):
        p, d = await formulario(request, ("admin", "admin_empresa"))
        q = {k: int(v) for k, v in request.query_params.items() if k in ("sede", "persona") and v.isdigit()}
        return await run_in_threadpool(accion_empresa, p, eid, accion, d, q)

    VISTAS = {"empresas": vista_empresas, "privacidad": vista_privacidad, "general": vista_general, "categorias": vista_categorias, "usuarios": vista_usuarios, "equipos": vista_equipos, "playbooks": vista_playbooks,
              "ia": vista_ia, "auditoria": vista_auditoria}

    @app.get("/consola/admin", include_in_schema=False)
    def admin_raiz(request: Request):
        p = persona_de(request, "admin", "admin_empresa")
        return RedirectResponse("/consola/admin/general" if p["rol"] == "admin" else "/consola/admin/empresas", 303)

    @app.get("/consola/admin/{seccion}", include_in_schema=False)
    def admin_seccion(request: Request, seccion: str, aviso: str = "", empresa: int = 0):
        p = persona_de(request, "admin", "admin_empresa")
        if seccion not in VISTAS or seccion not in secciones(p):
            raise HTTPException(404, "Sección no encontrada")
        if seccion == "privacidad":
            return VISTAS[seccion](p, aviso, empresa=empresa)
        return VISTAS[seccion](p, aviso)

    def guardar_ajuste(p, clave, valor):
        """Guarda un ajuste (validado y auditado) y vacía la caché de la consola."""
        with db.conexion(dsn) as c:
            r = ajustes.guardar(c, cfg, clave, valor, p["email"], tuple(catalogo))
        cache.clear()
        return r

    def con_error(seccion, p, err):
        return VISTAS[seccion](p, mensaje=("peligro", f"No se guardó: {err}"))

    @app.post("/consola/admin/general/interruptor", include_in_schema=False)
    async def admin_interruptor(request: Request):
        p, d = await formulario(request)
        if d.get("clave") not in ("agentes_pausados", "ia_activa") or d.get("valor") not in ("0", "1"):
            raise HTTPException(400, "Interruptor no válido")
        await run_in_threadpool(guardar_ajuste, p, d["clave"], d["valor"] == "1")
        return volver("general", "ajustes")

    @app.post("/consola/admin/general/ajustes", include_in_schema=False)
    async def admin_ajustes(request: Request):
        p, d = await formulario(request)
        nuevos = {"umbral_confianza": d.get("umbral_confianza"), "zona_horaria": d.get("zona_horaria"),
                  "sesion_horas": d.get("sesion_horas"), "login_intentos": d.get("login_intentos"),
                  "metas": {k: d.get(f"meta_{k}") for k in ajustes.METAS}}
        nombres = {"umbral_confianza": "umbral de confianza", "zona_horaria": "zona horaria", "sesion_horas": "duración de la sesión",
                   "login_intentos": "intentos de entrada", "metas": "metas del piloto"}

        def aplicar():
            # Se valida todo antes de guardar nada: o se guardan todos los cambios o ninguno.
            limpios = {}
            for k, val in nuevos.items():
                try:
                    limpios[k] = ajustes.validar(k, val, cfg)
                except ajustes.AjusteInvalido as err:
                    return con_error("general", p, f"{nombres[k]}: {err}")
            actual = aj()
            for k, val in limpios.items():
                if val != actual[k]:
                    guardar_ajuste(p, k, val)
            return volver("general", "ajustes")
        return await run_in_threadpool(aplicar)

    @app.post("/consola/admin/playbooks/{pid}/{accion}", include_in_schema=False)
    async def admin_playbook(request: Request, pid: str, accion: str):
        p, _ = await formulario(request)
        if pid not in catalogo or accion not in ("activar", "desactivar"):
            raise HTTPException(404, "Playbook o acción no encontrados")
        inactivos = set(aj()["playbooks_inactivos"])
        inactivos = inactivos - {pid} if accion == "activar" else inactivos | {pid}
        await run_in_threadpool(guardar_ajuste, p, "playbooks_inactivos", sorted(inactivos))
        return volver("playbooks", "pb_" + accion)

    def proveedor_de_formulario(d):
        x = {"proveedor": d.get("proveedor"), "modelo": d.get("modelo", "").strip(), "url": d.get("url", "").strip(),
             "clave_env": d.get("clave_env", "").strip(), "timeout": d.get("timeout", 60), "activo": d.get("activo") == "1",
             "precio_entrada": d.get("precio_entrada", "").strip(), "precio_salida": d.get("precio_salida", "").strip(),
             "tareas": [t for t in ajustes.TAREAS if d.get(f"tarea_{t}") == "1"], "local": d.get("local") == "1"}
        if x["proveedor"] == "ollama":
            x["contexto"] = d.get("contexto", 8192)
        return {k: v for k, v in x.items() if v != ""}

    def cambiar_cadena(p, d, i, accion):
        cadena = [dict(x) for x in aj()["ia"]]
        if d.get("v") != version_cadena(cadena):
            return con_error("ia", p, "la cadena cambió mientras la editabas; revisa y vuelve a intentarlo")
        if i is not None and not 0 <= i < len(cadena):
            raise HTTPException(404, "Proveedor no encontrado")
        if accion in ("agregar", "guardar"):
            x = proveedor_de_formulario(d)
            antes = None if accion == "agregar" else cadena[i]
            nueva = d.get("clave", "").strip()
            try:
                if nueva:  # la clave en claro solo vive en esta petición: se cifra y se descarta
                    x["clave_cifrada"], x["clave_pista"] = ajustes.cifrar(nueva), re.sub(r"[^A-Za-z0-9_-]", "", nueva[-4:])
                elif antes and antes.get("clave_cifrada") and d.get("borrar_clave") != "1":
                    if (antes.get("url"), antes["proveedor"]) != (x.get("url"), x["proveedor"]):
                        # la clave guardada no viaja sola a otro servidor: quien cambia la URL la vuelve a escribir
                        raise ajustes.AjusteInvalido("cambiaste la URL o el adaptador: vuelve a escribir la clave de API "
                                                     "(o marca «Borrar la clave guardada»)")
                    x["clave_cifrada"], x["clave_pista"] = antes["clave_cifrada"], antes.get("clave_pista", "")
                x = ajustes.validar("ia", [x], cfg)[0]
            except ajustes.AjusteInvalido as err:
                return con_error("ia", p, str(err))
            se_activa = x["activo"] and (antes is None or not antes.get("activo", True)
                                         or (antes["proveedor"], antes["modelo"]) != (x["proveedor"], x["modelo"]))
            if se_activa and not aprobada(evaluaciones().get(f'{x["proveedor"]}:{x["modelo"]}')) and d.get("sin_evaluar") != "1":
                return con_error("ia", p, f"{x['modelo']} no tiene una evaluación aprobada (el plan pide pasarla antes de "
                                          "usar un modelo). Evalúalo con «helpert-server evaluar» o marca la casilla para activarlo igual.")
            if accion == "agregar":
                cadena.append(x)
            else:
                cadena[i] = x
        elif accion == "quitar":
            cadena.pop(i)
        elif accion in ("subir", "bajar"):
            j = i - 1 if accion == "subir" else i + 1
            if 0 <= j < len(cadena):
                cadena[i], cadena[j] = cadena[j], cadena[i]
        else:
            raise HTTPException(404, "Acción no válida")
        try:
            guardar_ajuste(p, "ia", cadena)
        except ajustes.AjusteInvalido as err:
            return con_error("ia", p, str(err))
        return volver("ia", "ia_" + accion)

    def probar(p, d, i):
        cadena = aj()["ia"]
        if d.get("v") != version_cadena(cadena) or not 0 <= i < len(cadena):
            return con_error("ia", p, "la cadena cambió; recarga la página")
        x = dict(cadena[i])
        x["timeout"] = min(int(x.get("timeout", 60)), 30)
        llamar = ia.PROVEEDORES.get(x["proveedor"])
        inicio = time.monotonic()
        try:
            llamar(x, [{"role": "system", "content": "Responde solo con la palabra ok."}, {"role": "user", "content": "ok"}])
        except ia.ErrorProveedor as err:
            texto = str(err)
            clase = (texto.split(":")[0] if texto.startswith("HTTP ") else "falta la clave" if "falta la clave" in texto
                     else "no responde (red, URL o tiempo agotado)")
            mensaje = ("peligro", f"{x['modelo']}: {clase}.")  # solo la clase de error, nunca el cuerpo de la respuesta
        else:
            mensaje = ("exito", f"{x['modelo']} respondió en {time.monotonic() - inicio:.1f} s.")
        with db.conexion(dsn) as c:
            db.auditar(c, p["email"], "Probó un proveedor de IA", f"{x['proveedor']}:{x['modelo']} → {mensaje[1]}")
        return vista_ia(p, mensaje=mensaje)

    @app.post("/consola/admin/ia/agregar", include_in_schema=False)
    async def admin_ia_agregar(request: Request):
        p, d = await formulario(request)
        return await run_in_threadpool(cambiar_cadena, p, d, None, "agregar")

    @app.post("/consola/admin/ia/{i}/{accion}", include_in_schema=False)
    async def admin_ia(request: Request, i: int, accion: str):
        p, d = await formulario(request)
        if accion == "probar":
            return await run_in_threadpool(probar, p, d, i)
        return await run_in_threadpool(cambiar_cadena, p, d, i, accion)

    def admins_activos(c, sin_id):
        return c.execute("SELECT count(*) AS n FROM usuarios_consola WHERE rol = 'admin' AND activo AND id <> %s",
                         (sin_id,)).fetchone()["n"]

    def empresa_de_cuenta(p, rol, d):
        """Empresa de una cuenta nueva o editada; None = plataforma. Lanza ValueError si la combinación no vale."""
        if p["rol"] != "admin":
            emp = p["empresa_id"]  # la administración de una empresa solo crea cuentas de la suya
        else:
            emp = int(d["empresa"]) if str(d.get("empresa", "")).isdigit() else None
        if (rol not in ROLES or (rol == "admin" and (p["rol"] != "admin" or emp is not None))
                or (rol == "admin_empresa" and emp is None)):
            raise ValueError
        return emp

    def crear_usuario(p, d):
        email, nombre, rol = d.get("email", "").strip().lower()[:200], d.get("nombre", "").strip()[:100] or None, d.get("rol")
        try:
            emp = empresa_de_cuenta(p, rol, d)
        except ValueError:
            return volver("usuarios", "invalido")
        if not EMAIL.match(email):
            return volver("usuarios", "invalido")
        with db.conexion(dsn) as c:
            if c.execute("SELECT 1 FROM usuarios_consola WHERE email = %s", (email,)).fetchone():
                return volver("usuarios", "existe")
        clave = secrets.token_urlsafe(12)
        try:
            db.usuario_consola(dsn, email, rol, clave, nombre, emp)
        except psycopg.errors.IntegrityError:  # empresa que no existe
            return volver("usuarios", "invalido")
        with db.conexion(dsn) as c:
            db.auditar(c, p["email"], "Creó una cuenta", f"{email} · {ROLES[rol]}" + (f" · empresa {emp}" if emp else ""))
        return vista_usuarios(p, secreto=(f"Contraseña temporal de {email}", clave,
                                          "Compártela por un canal seguro. Solo se muestra ahora."))

    def accion_usuario(p, uid, accion, d):
        with db.conexion(dsn) as c:
            u = c.execute(f"SELECT * FROM usuarios_consola WHERE id = %s AND {alc(p, 'empresa_id')} FOR UPDATE", (uid,)).fetchone()
            if not u:
                raise HTTPException(404, "Cuenta no encontrada")
            if accion == "sesiones":  # en la propia cuenta, todas menos la actual
                n = c.execute("DELETE FROM sesiones WHERE usuario_id = %s AND token_sha <> %s",
                              (uid, p["sesion_sha"])).rowcount
                db.auditar(c, p["email"], "Cerró sesiones", f"{u['email']}: {n}")
                return volver("usuarios", "sesiones")
            if accion == "clave":
                clave = secrets.token_urlsafe(12)
                guardar = True
            elif u["id"] == p["id"]:
                return volver("usuarios", "propio")
            elif accion == "rol":
                rol = d.get("rol")
                if rol not in ROLES or (rol == "admin" and (p["rol"] != "admin" or u["empresa_id"])) \
                        or (rol == "admin_empresa" and not u["empresa_id"]):
                    return volver("usuarios", "invalido")
                if u["rol"] == "admin" and rol != "admin" and not admins_activos(c, uid):
                    return volver("usuarios", "ultimo")
                c.execute("UPDATE usuarios_consola SET rol = %s WHERE id = %s", (rol, uid))
                c.execute("DELETE FROM sesiones WHERE usuario_id = %s", (uid,))
                db.auditar(c, p["email"], "Cambió un rol", f"{u['email']}: {ROLES.get(u['rol'])} → {ROLES[rol]}")
                return volver("usuarios", "rol")
            elif accion in ("activar", "desactivar"):
                activo = accion == "activar"
                if not activo and u["rol"] == "admin" and not admins_activos(c, uid):
                    return volver("usuarios", "ultimo")
                c.execute("UPDATE usuarios_consola SET activo = %s WHERE id = %s", (activo, uid))
                c.execute("DELETE FROM sesiones WHERE usuario_id = %s", (uid,))
                db.auditar(c, p["email"], "Activó una cuenta" if activo else "Desactivó una cuenta", u["email"])
                return volver("usuarios", "activo" if activo else "inactivo")
            else:
                raise HTTPException(404, "Acción no válida")
        if guardar:
            db.usuario_consola(dsn, u["email"], u["rol"], clave, None, u["empresa_id"])
            with db.conexion(dsn) as c:
                db.auditar(c, p["email"], "Generó una contraseña", u["email"])
            return vista_usuarios(p, secreto=(f"Contraseña nueva de {u['email']}", clave,
                                              "La anterior ya no sirve y sus sesiones se cerraron. Solo se muestra ahora."))

    def crear_equipo(p, d):
        nombre = d.get("nombre", "").strip()
        if not NOMBRE_EQUIPO.match(nombre):
            return volver("equipos", "invalido")
        try:
            token = db.equipo_nuevo(dsn, nombre)
        except psycopg.errors.UniqueViolation:
            return volver("equipos", "existe")
        with db.conexion(dsn) as c:
            db.auditar(c, p["email"], "Registró un equipo", nombre)
        return vista_equipos(p, secreto=(f"Token de {nombre}", token, "Guárdalo en un archivo y úsalo con "
                                         "instalar-agente-linux.sh --token-archivo. Solo se muestra ahora."))

    def accion_equipo(p, eid, accion, d):
        with db.conexion(dsn) as c:
            q = c.execute(f"SELECT * FROM equipos WHERE id = %s AND {alc(p, 'empresa_id')}", (eid,)).fetchone()
            if not q or accion not in ("token", "revocar", "datos", "piloto") or (accion == "piloto" and p["rol"] != "admin"):
                raise HTTPException(404, "Equipo o acción no encontrados")
            if accion == "piloto":
                c.execute("UPDATE equipos SET piloto = NOT piloto WHERE id = %s", (eid,))
                db.auditar(c, p["email"], "Cambió el grupo piloto", f"{q['nombre']}: {'sale' if q['piloto'] else 'entra'}")
                return RedirectResponse(f"/consola/admin/equipos/{eid}", 303)
            if accion == "datos":
                campos = {k: (d.get(k, "").strip()[:200] or None) for k in ("area", "sede", "piso", "notas")}
                c.execute("UPDATE equipos SET area = %(area)s, sede = %(sede)s, piso = %(piso)s, notas = %(notas)s "
                          "WHERE id = %(id)s", {**campos, "id": eid})
                if p["rol"] == "admin" and "empresa" in d:  # mover el equipo de empresa: sus sesiones abiertas se cierran
                    emp = int(d["empresa"]) if d["empresa"].isdigit() else None
                    if emp != q["empresa_id"]:
                        if emp and not c.execute("SELECT 1 FROM empresas WHERE id = %s", (emp,)).fetchone():
                            raise HTTPException(422, "Empresa no encontrada")
                        c.execute("UPDATE equipos SET empresa_id = %s WHERE id = %s", (emp, eid))
                        c.execute("DELETE FROM sesiones_persona WHERE equipo_id = %s", (eid,))
                        campos["empresa"] = str(emp or "ninguna")
                db.auditar(c, p["email"], "Editó los datos de un equipo",
                           f"{q['nombre']}: " + ", ".join(f"{k}={v or '—'}" for k, v in campos.items() if k != "notas"))
                return RedirectResponse(f"/consola/admin/equipos/{eid}?{urlencode({'aviso': 'datos'})}", 303)
            if accion == "revocar":
                c.execute("UPDATE equipos SET revocado = now() WHERE id = %s", (eid,))
                db.auditar(c, p["email"], "Revocó un equipo", q["nombre"])
                return volver("equipos", "revocado")
        token = db.rotar_token(dsn, eid)
        with db.conexion(dsn) as c:
            db.auditar(c, p["email"], "Generó un token nuevo", q["nombre"])
        return vista_equipos(p, secreto=(f"Token nuevo de {q['nombre']}", token,
                                         "El anterior ya no sirve: reinstala el agente con este. Solo se muestra ahora."))

    @app.post("/consola/admin/usuarios", include_in_schema=False)
    async def admin_crear_usuario(request: Request):
        p, d = await formulario(request, ("admin", "admin_empresa"))
        return await run_in_threadpool(crear_usuario, p, d)

    @app.post("/consola/admin/usuarios/{uid}/{accion}", include_in_schema=False)
    async def admin_accion_usuario(request: Request, uid: int, accion: str):
        p, d = await formulario(request, ("admin", "admin_empresa"))
        return await run_in_threadpool(accion_usuario, p, uid, accion, d)

    @app.post("/consola/admin/equipos", include_in_schema=False)
    async def admin_crear_equipo(request: Request):
        p, d = await formulario(request)
        return await run_in_threadpool(crear_equipo, p, d)

    @app.post("/consola/admin/equipos/{eid}/{accion}", include_in_schema=False)
    async def admin_accion_equipo(request: Request, eid: int, accion: str):
        p, d = await formulario(request, ("admin", "admin_empresa"))
        return await run_in_threadpool(accion_equipo, p, eid, accion, d)

    def vista_equipo(p, eid, aviso=""):
        with db.conexion(dsn) as c:
            q = c.execute(f"SELECT * FROM equipos WHERE id = %s AND {alc(p, 'empresa_id')}", (eid,)).fetchone()
            if not q:
                raise HTTPException(404, "Equipo no encontrado")
            empresas = empresas_de(c, p) if p["rol"] == "admin" else []
            sedes = c.execute("SELECT nombre FROM sedes WHERE empresa_id = %s ORDER BY nombre", (q["empresa_id"],)).fetchall()
            casos = c.execute("SELECT id, creado, usuario, so, estado, categoria, subcategoria, playbook, costo_usd "
                              "FROM casos WHERE equipo_id = %s ORDER BY id DESC LIMIT 200", (eid,)).fetchall()
            tot = c.execute("""SELECT count(*) AS total, count(*) FILTER (WHERE estado = 'cerrado' AND resuelto) AS resueltos,
                                 count(*) FILTER (WHERE estado = 'escalado') AS escalados, coalesce(sum(costo_usd), 0) AS costo,
                                 count(DISTINCT usuario) AS usuarios
                               FROM casos WHERE equipo_id = %s""", (eid,)).fetchone()
        so = casos[0]["so"].capitalize() if casos and casos[0]["so"] else "—"
        cifras = ('<div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">'
                  + cifra("Casos", str(tot["total"]), f'{tot["usuarios"]} usuarios distintos', "casos")
                  + cifra("Resueltos por Helpert", str(tot["resueltos"]), "Cerrados como resueltos", "ok", "text-exito")
                  + cifra("Escalados", str(tot["escalados"]), "Pasaron a soporte (N2 o N3)", "escalar")
                  + cifra("Costo de IA", f'US$ {float(tot["costo"]):.4f}', "Con los precios configurados", "ia") + '</div>')
        datos = (f'<form method="post" action="/consola/admin/equipos/{eid}/datos" class="grid gap-4">{csrf(p)}'
                 '<div class="grid gap-4 sm:grid-cols-3">'
                 + campo("area", "Área", q["area"] or "", "", "text", 'maxlength="200" placeholder="Contabilidad"', requerido=False)
                 + campo("sede", "Sede", q["sede"] or "", "", "text", 'maxlength="200" placeholder="Sede central" list="sedes-empresa"',
                         requerido=False)
                 + campo("piso", "Piso", q["piso"] or "", "", "text", 'maxlength="20" placeholder="3"', requerido=False)
                 + '</div><datalist id="sedes-empresa">' + "".join(f'<option value="{e(s["nombre"])}">' for s in sedes) + '</datalist>'
                 + ('<div class="grid gap-2"><label class="etiqueta" for="c-empresa">Empresa</label>'
                    '<select class="campo" id="c-empresa" name="empresa"><option value="">Sin empresa (la toma quien inicie sesión)</option>'
                    + "".join(f'<option value="{x["id"]}"{" selected" if x["id"] == q["empresa_id"] else ""}>{e(x["nombre"])}</option>'
                              for x in empresas)
                    + '</select><p class="text-xs text-muted-foreground">Al cambiarla se cierran las sesiones abiertas en la bandeja.</p></div>'
                    if p["rol"] == "admin" else "")
                 + '<div class="grid gap-2"><label class="etiqueta" for="c-notas">Notas internas</label>'
                   f'<textarea class="campo h-24 py-2" id="c-notas" name="notas" maxlength="200">{html.escape(q["notas"] or "")}</textarea></div>'
                 f'<div><button class="btn btn-primario">{icono("ok")}Guardar datos</button></div></form>')
        estado = (insignia("Revocado", "peligro", "prohibido") if q["revocado"] else insignia("Habilitado", "exito", "ok"))
        ficha_q = ('<dl class="-my-2 divide-y text-sm">' + "".join(
            f'<div class="grid grid-cols-[9rem_1fr] gap-3 py-2.5"><dt class="text-muted-foreground">{t}</dt><dd>{v}</dd></div>'
            for t, v in (("Estado", estado), ("Sistema", e((q["so"] or "").capitalize() or so)),
                         ("Control remoto", f'<span class="codigo select-all">{e(q["remoto"])}</span>' if q["remoto"] else "—"),
                         ("Versión del agente", e(q["version"])),
                         ("Piloto", "Sí: recibe primero las versiones nuevas" if q["piloto"] else "No"),
                         ("Último contacto", fecha(q["visto"])),
                         ("Registrado", fecha(q["creado"])), ("Revocado", fecha(q["revocado"])))) + '</dl>'
            + '<div class="mt-4 flex flex-wrap gap-2">'
            + boton_post(p, f"/consola/admin/equipos/{eid}/token", f'{icono("llave")}Nuevo token', "btn-borde",
                         "¿Generar un token nuevo? El actual deja de servir y hay que reinstalar el agente con el nuevo.")
            + ("" if q["revocado"] else boton_post(p, f"/consola/admin/equipos/{eid}/revocar", "Revocar", "btn-borde text-peligro",
                                                   "¿Revocar este equipo? Su agente deja de poder hablar con el servidor."))
            + (boton_post(p, f"/consola/admin/equipos/{eid}/piloto", "Quitar de piloto" if q["piloto"] else "Marcar como piloto",
                          "btn-fantasma") if p["rol"] == "admin" else "")
            + '</div>')
        filas = "".join(
            f'<tr data-href="/consola/caso/{k["id"]}" class="cursor-pointer"><td><a class="font-medium hover:underline" '
            f'href="/consola/caso/{k["id"]}">#{k["id"]}</a></td><td data-order="{k["creado"].isoformat()}" '
            f'class="whitespace-nowrap tabular-nums text-muted-foreground">{fecha(k["creado"])}</td><td>{e(k["usuario"])}</td>'
            f'<td>{e(k["categoria"])}<p class="text-xs text-muted-foreground">{e(k["subcategoria"])}</p></td>'
            f'<td>{estado_caso(k["estado"])}</td><td class="text-right tabular-nums">{float(k["costo_usd"]):.4f}</td></tr>' for k in casos)
        tabla = ('<div class="tabla-caja"><table id="tabla-casos-equipo" class="tabla" data-tabla="completa"><thead><tr><th>Caso</th>'
                 '<th>Abierto</th><th>Usuario</th><th>Categoría</th><th>Estado</th><th class="text-right">Costo (US$)</th></tr></thead>'
                 f'<tbody>{filas}</tbody></table></div>' if casos else
                 '<p class="px-6 py-10 text-center text-sm text-muted-foreground">Este equipo todavía no tiene casos.</p>')
        aviso_html = (f'<div class="alerta border-primary/30 bg-primario-suave/40 text-sobre-primario-suave" role="status">'
                      f'{icono("ok")}<p>Datos del equipo guardados.</p></div>' if aviso == "datos" else "")
        cuerpo = (encabezado(f'{icono("equipo", "size-6 text-muted-foreground")}{e(q["nombre"])}',
                             '<a class="hover:underline" href="/consola/admin/equipos">← Volver a Equipos</a>')
                  + aviso_html + cifras
                  + '<div class="grid items-start gap-6 lg:grid-cols-3">'
                  + tarjeta("Ubicación y notas", "Sirven al técnico de campo y para filtrar por área.", datos, "lg:col-span-2")
                  + tarjeta("Agente", "Estado del equipo en el servidor.", ficha_q) + '</div>'
                  + tarjeta("Casos de este equipo", "Los últimos 200.", tabla, "gap-4 overflow-hidden pb-0",
                            "px-0 [&_.tabla_th:first-child]:pl-6 [&_.tabla_td:first-child]:pl-6 "
                            "[&_.tabla_th:last-child]:pr-6 [&_.tabla_td:last-child]:pr-6"))
        return pagina(f"Equipo {q['nombre']}", cuerpo, p, "admin:equipos", libs=("datatables",))

    @app.get("/consola/admin/equipos/{eid}", include_in_schema=False)
    def admin_equipo(request: Request, eid: int, aviso: str = ""):
        return vista_equipo(persona_de(request, "admin", "admin_empresa"), eid, aviso)

    def accion_inscripcion(p, accion):
        with db.conexion(dsn) as c:
            ins = dict(ajustes.leer(c, cfg)["inscripcion"])
        clave = None
        if accion in ("activar", "desactivar"):
            ins["activa"] = accion == "activar"
        elif accion == "clave":
            clave = secrets.token_urlsafe(24)
            ins = {"activa": True, "clave_sha": db.sha(clave)}  # solo la huella: la clave se muestra una vez y no se guarda
        elif accion == "servidor":
            ins["clave_sha"] = None
        else:
            raise HTTPException(404, "Acción no válida")
        guardar_ajuste(p, "inscripcion", ins)
        if clave:
            return vista_equipos(p, secreto=("Clave de inscripción nueva", clave,
                                             "Guárdala en un archivo y empaqueta el instalador con "
                                             "empaquetar-linux.sh --inscripcion-archivo. La anterior ya no sirve. Solo se muestra ahora."))
        return volver("equipos", "ajustes")

    @app.post("/consola/admin/inscripcion/{accion}", include_in_schema=False)
    async def admin_inscripcion(request: Request, accion: str):
        p, _ = await formulario(request)
        return await run_in_threadpool(accion_inscripcion, p, accion)
