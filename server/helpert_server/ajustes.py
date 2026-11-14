"""Ajustes que se cambian desde la consola (Administración → General, IA y Playbooks).

Se guardan en la tabla `ajustes` y se leen en cada petición, para que los interruptores de emergencia actúen en
segundos. El archivo TOML solo da los valores iniciales. Se valida al guardar, y al leer un valor guardado que ya
no es válido (por ejemplo, de una versión anterior) se usa el valor por defecto: un ajuste roto no tumba el servicio.
"""
import json
import os
import re
import unicodedata
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

METAS = {"sin_humano": 50.0, "minutos": 10.0, "satisfaccion": 4.3, "reapertura": 10.0, "revertidas": 2.0}
RANGO_METAS = {"sin_humano": (0, 100), "minutos": (1, 240), "satisfaccion": (1, 5), "reapertura": (0, 100),
               "revertidas": (0, 100)}
PROVEEDORES = ("gemini", "openai-compatible", "ollama")
# Las claves de API viven en variables de entorno del servidor; la consola solo elige cuál, y solo de este prefijo.
# Si fuera texto libre, una sesión robada podría mandar HELPERT_DB (con la contraseña de la base) a su propio servidor.
CLAVE_ENV = re.compile(r"^HELPERT_IA_[A-Z0-9_]{1,40}$")
MODELO = re.compile(r"^[A-Za-z0-9._:/@+-]{1,120}$")
URL = re.compile(r"^https?://[^\s\"'<>]{1,200}$")
FERNET = re.compile(r"^[A-Za-z0-9_=-]{80,4000}$")
# Tareas de la IA (plan, «Modelo por tarea»): conversar y clasificar; «complejo» da una segunda opinión cuando el
# primero duda (confianza bajo el umbral o salida inválida); «vision» describe las capturas.
TAREAS = ("conversar", "complejo", "vision")
# Clave maestra para cifrar las claves de API guardadas desde la consola (Fernet, 32 bytes en base64 url).
MAESTRA_ENV = "HELPERT_CLAVE_MAESTRA"


class AjusteInvalido(ValueError):
    pass


def defectos(cfg: dict) -> dict:
    from .ia import EJEMPLOS  # aquí para no importar la capa de IA al cargar el módulo
    var = cfg.get("inscripcion_env")
    return {
        "agentes_pausados": False,
        "ia_activa": True,
        "playbooks_inactivos": [],
        "umbral_confianza": float(cfg.get("umbral_confianza", 0.7)),
        "zona_horaria": cfg.get("zona_horaria", "America/Lima"),
        "sesion_horas": 12,
        "login_intentos": 5,
        "metas": dict(METAS),
        "ia": [{**p, "activo": p.get("activo", True)} for p in cfg.get("ia", [])],
        "categorias": dict(EJEMPLOS),
        # clave_sha None: se usa la clave de la variable de entorno; con valor, la que se generó en la consola.
        "inscripcion": {"activa": bool(var and os.environ.get(var)), "clave_sha": None},
        # Reglas por área del equipo (plan: «ciertas áreas, por ejemplo RR. HH., usen solo Ollama»).
        "reglas_area": [],
        # Capturas: apagadas hasta tener ocultamiento automático; la persona ve la captura antes de enviarla.
        "capturas": {"activas": False, "dias": 90, "ia_externa": False},
        "categorias_fisicas": ["Hardware", "Impresión"],  # al escalar, abren una visita de un técnico
        # Actualización del agente por etapas: huellas (sha256) de versiones publicadas.
        "despliegue": {"estable": None, "nueva": None, "porcentaje": 0},
    }


def _numero(v, minimo, maximo, entero=False):
    try:
        n = int(v) if entero else float(v)
    except (TypeError, ValueError):
        raise AjusteInvalido("debe ser un número") from None
    if not minimo <= n <= maximo:
        raise AjusteInvalido(f"debe estar entre {minimo} y {maximo}")
    return n


def _proveedor(p: dict, claves_iniciales: set[str], tipos_iniciales: set[str]) -> dict:
    if not isinstance(p, dict):
        raise AjusteInvalido("proveedor mal formado")
    if p.get("proveedor") not in PROVEEDORES and p.get("proveedor") not in tipos_iniciales:
        raise AjusteInvalido(f"tipo de proveedor no válido: {p.get('proveedor')}")
    if not MODELO.match(str(p.get("modelo", ""))):
        raise AjusteInvalido("el modelo solo admite letras, números y . _ : / @ + -")
    tareas = p.get("tareas", ["conversar"])
    if not isinstance(tareas, list) or not tareas or set(tareas) - set(TAREAS):
        raise AjusteInvalido("elige al menos una tarea: conversar, complejo o visión")
    limpio = {"proveedor": p["proveedor"], "modelo": p["modelo"], "activo": bool(p.get("activo", True)),
              "timeout": _numero(p.get("timeout", 60), 5, 300, entero=True),
              "tareas": [t for t in TAREAS if t in tareas],
              # local: corre en infraestructura propia (los datos no salen); lo exigen las áreas «solo local»
              "local": bool(p.get("local", p["proveedor"] == "ollama"))}
    if p.get("url"):
        if not URL.match(p["url"]):
            raise AjusteInvalido("la URL debe empezar con http:// o https://")
        limpio["url"] = p["url"]
    if p.get("clave_env"):
        if not (CLAVE_ENV.match(p["clave_env"]) or p["clave_env"] in claves_iniciales):
            raise AjusteInvalido("la variable de la clave debe empezar con HELPERT_IA_ (solo mayúsculas, números y _)")
        limpio["clave_env"] = p["clave_env"]
    if p.get("clave_cifrada"):
        if not FERNET.match(str(p["clave_cifrada"])) or not re.fullmatch(r"[A-Za-z0-9_-]{0,4}", str(p.get("clave_pista", ""))):
            raise AjusteInvalido("clave cifrada mal formada")
        limpio["clave_cifrada"], limpio["clave_pista"] = p["clave_cifrada"], p.get("clave_pista", "")
    for k in ("precio_entrada", "precio_salida"):  # USD por millón de tokens, para el costo por caso
        if p.get(k) not in (None, ""):
            limpio[k] = _numero(p[k], 0, 1000)
    if p["proveedor"] == "ollama":
        limpio["contexto"] = _numero(p.get("contexto", 8192), 1024, 131072, entero=True)
    return limpio


def validar(clave: str, valor, cfg: dict, catalogo_ids=()):
    """Devuelve el valor limpio o lanza AjusteInvalido."""
    if clave in ("agentes_pausados", "ia_activa"):
        if not isinstance(valor, bool):
            raise AjusteInvalido("debe ser sí o no")
        return valor
    if clave == "playbooks_inactivos":
        if not isinstance(valor, list) or not all(isinstance(x, str) for x in valor):
            raise AjusteInvalido("lista de playbooks mal formada")
        if catalogo_ids and set(valor) - set(catalogo_ids):
            raise AjusteInvalido("playbook desconocido")
        return sorted(set(valor))
    if clave == "umbral_confianza":
        return _numero(valor, 0, 1)
    if clave == "zona_horaria":
        try:
            ZoneInfo(str(valor))
        except (ZoneInfoNotFoundError, ValueError):
            raise AjusteInvalido("zona horaria desconocida") from None
        return str(valor)
    if clave == "sesion_horas":
        return _numero(valor, 1, 168, entero=True)
    if clave == "login_intentos":
        return _numero(valor, 3, 50, entero=True)
    if clave == "metas":
        if not isinstance(valor, dict) or set(valor) != set(METAS):
            raise AjusteInvalido("metas mal formadas")
        return {k: _numero(valor[k], *RANGO_METAS[k]) for k in METAS}
    if clave == "ia":
        if not isinstance(valor, list) or len(valor) > 8:
            raise AjusteInvalido("la cadena admite hasta 8 proveedores")
        iniciales = {p.get("clave_env") for p in cfg.get("ia", []) if p.get("clave_env")}
        tipos = {p.get("proveedor") for p in cfg.get("ia", [])}  # los del TOML valen aunque la consola no los ofrezca
        return [_proveedor(p, iniciales, tipos) for p in valor]
    if clave == "categorias":
        if not isinstance(valor, dict) or not 1 <= len(valor) <= 30:
            raise AjusteInvalido("debe haber entre 1 y 30 categorías")
        limpio = {}
        for nombre, ejemplos in valor.items():
            nombre, ejemplos = str(nombre).strip(), str(ejemplos).strip()
            if not 1 <= len(nombre) <= 60 or len(ejemplos) > 300 or any(ch in nombre + ejemplos for ch in "{}\n"):
                raise AjusteInvalido("cada categoría: nombre de 1 a 60 caracteres y ejemplos de hasta 300, en una línea")
            limpio[nombre] = ejemplos
        return limpio
    if clave == "inscripcion":
        if not isinstance(valor, dict) or not isinstance(valor.get("activa"), bool):
            raise AjusteInvalido("inscripción mal formada")
        sha = valor.get("clave_sha")
        if sha is not None and not re.fullmatch(r"[0-9a-f]{64}", str(sha)):
            raise AjusteInvalido("huella de la clave mal formada")
        return {"activa": valor["activa"], "clave_sha": sha}
    if clave == "reglas_area":
        if not isinstance(valor, list) or len(valor) > 50:
            raise AjusteInvalido("hasta 50 reglas por área")
        limpio, vistas = [], set()
        for r in valor:
            if not isinstance(r, dict):
                raise AjusteInvalido("regla mal formada")
            area = str(r.get("area", "")).strip()
            if not 1 <= len(area) <= 60 or not norma_area(area) or norma_area(area) in vistas:
                raise AjusteInvalido("cada regla necesita un área distinta, de 1 a 60 caracteres")
            vistas.add(norma_area(area))
            bloq = r.get("playbooks_bloqueados", [])
            if not isinstance(bloq, list) or not all(isinstance(x, str) for x in bloq):
                raise AjusteInvalido("lista de playbooks mal formada")
            if catalogo_ids and set(bloq) - set(catalogo_ids):
                raise AjusteInvalido("playbook desconocido")
            limpio.append({"area": area, "solo_local": bool(r.get("solo_local")), "capturas": bool(r.get("capturas", True)),
                           "playbooks_bloqueados": sorted(set(bloq))})
        return limpio
    if clave == "capturas":
        if not isinstance(valor, dict):
            raise AjusteInvalido("capturas mal formadas")
        return {"activas": bool(valor.get("activas")), "dias": _numero(valor.get("dias", 90), 1, 365, entero=True),
                "ia_externa": bool(valor.get("ia_externa"))}
    if clave == "categorias_fisicas":
        if not isinstance(valor, list) or len(valor) > 30 or not all(isinstance(x, str) and 1 <= len(x) <= 60 for x in valor):
            raise AjusteInvalido("lista de categorías mal formada")
        return sorted(set(valor))
    if clave == "despliegue":
        sha = lambda x: x is None or bool(re.fullmatch(r"[0-9a-f]{64}", str(x)))
        if not isinstance(valor, dict) or not sha(valor.get("estable")) or not sha(valor.get("nueva")):
            raise AjusteInvalido("despliegue mal formado")
        return {"estable": valor.get("estable"), "nueva": valor.get("nueva"),
                "porcentaje": _numero(valor.get("porcentaje", 0), 0, 100, entero=True)}
    raise AjusteInvalido(f"ajuste desconocido: {clave}")


# Lo que cada empresa decide por sí misma (privacidad); el resto es de la plataforma.
DE_EMPRESA = ("reglas_area", "capturas")


def leer(c, cfg: dict, empresa_id=None) -> dict:
    """Ajustes vigentes: los guardados que siguen siendo válidos, sobre los valores por defecto; con empresa_id,
    los propios de esa empresa pisan a los de la plataforma."""
    actual = defectos(cfg)
    filas = list(c.execute("SELECT clave, valor FROM ajustes"))
    if empresa_id:
        filas += c.execute("SELECT clave, valor FROM ajustes_empresa WHERE empresa_id = %s AND clave = ANY(%s)",
                           (empresa_id, list(DE_EMPRESA))).fetchall()
    for fila in filas:
        if fila["clave"] in actual:
            try:
                actual[fila["clave"]] = validar(fila["clave"], fila["valor"], cfg)
            except AjusteInvalido:
                pass
    return actual


def guardar_empresa(c, cfg: dict, empresa_id: int, clave: str, valor, persona: str, catalogo_ids=()) -> tuple:
    """Como guardar, para un ajuste propio de una empresa. valor None vuelve a los de la plataforma."""
    if clave not in DE_EMPRESA:
        raise AjusteInvalido(f"ajuste de la plataforma: {clave}")
    antes = leer(c, cfg, empresa_id)[clave]
    if valor is None:
        c.execute("DELETE FROM ajustes_empresa WHERE empresa_id = %s AND clave = %s", (empresa_id, clave))
        limpio = leer(c, cfg)[clave]
    else:
        limpio = validar(clave, valor, cfg, catalogo_ids)
        c.execute("INSERT INTO ajustes_empresa (empresa_id, clave, valor, persona) VALUES (%s, %s, %s, %s) "
                  "ON CONFLICT (empresa_id, clave) DO UPDATE SET valor = excluded.valor, persona = excluded.persona, "
                  "actualizado = now()", (empresa_id, clave, json.dumps(limpio), persona))
    c.execute("INSERT INTO auditoria (persona, accion, detalle) VALUES (%s, %s, %s)",
              (persona, "Cambió un ajuste de empresa", f"empresa {empresa_id} · {clave}: {_corto(antes)} → {_corto(limpio)}"[:1000]))
    return antes, limpio


def guardar(c, cfg: dict, clave: str, valor, persona: str, catalogo_ids=()) -> tuple:
    """Valida, guarda y audita. Devuelve (antes, después)."""
    limpio = validar(clave, valor, cfg, catalogo_ids)
    antes = leer(c, cfg)[clave]
    c.execute("INSERT INTO ajustes (clave, valor, persona) VALUES (%s, %s, %s) ON CONFLICT (clave) DO UPDATE "
              "SET valor = excluded.valor, persona = excluded.persona, actualizado = now()",
              (clave, json.dumps(limpio), persona))
    c.execute("INSERT INTO auditoria (persona, accion, detalle) VALUES (%s, %s, %s)",
              (persona, "Cambió un ajuste", f"{clave}: {_corto(antes)} → {_corto(limpio)}"[:1000]))
    return antes, limpio


def _corto(v) -> str:
    if isinstance(v, list):  # la cadena de IA: la auditoría nunca guarda las claves, ni cifradas
        v = [{**x, "clave_cifrada": "(cifrada)"} if isinstance(x, dict) and x.get("clave_cifrada") else x for x in v]
    return json.dumps(v, ensure_ascii=False, sort_keys=True)


def norma_area(texto) -> str:
    """«RR. HH.», «rrhh» y «RRHH» son la misma área: sin tildes, espacios ni signos, en minúsculas."""
    t = unicodedata.normalize("NFKD", str(texto or "")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", t)


SIN_REGLA = {"area": None, "solo_local": False, "capturas": True, "playbooks_bloqueados": []}


def regla_de(aj: dict, area) -> dict:
    n = norma_area(area)
    return next((r for r in aj["reglas_area"] if n and norma_area(r["area"]) == n), SIN_REGLA)


def cadena_activa(aj: dict, tarea: str = "conversar", regla: dict = SIN_REGLA, externa: bool = True) -> list[dict]:
    """Proveedores para una tarea: ninguno si la IA está apagada (el servidor ofrece el menú sin IA).
    Un área «solo local», o externa=False, deja solo los proveedores locales; si no hay, no hay IA (nunca la nube)."""
    if not aj["ia_activa"]:
        return []
    solo_local = regla["solo_local"] or not externa
    return [p for p in aj["ia"] if p.get("activo", True) and tarea in p.get("tareas", ["conversar"])
            and (p.get("local", p.get("proveedor") == "ollama") or not solo_local)]


def catalogo_activo(catalogo: dict, aj: dict, regla: dict = SIN_REGLA) -> dict:
    fuera = set(aj["playbooks_inactivos"]) | set(regla["playbooks_bloqueados"])
    return {k: pb for k, pb in catalogo.items() if k not in fuera}


def _fernet():
    from cryptography.fernet import Fernet
    clave = os.environ.get(MAESTRA_ENV, "")
    try:
        return Fernet(clave.encode()) if clave else None
    except ValueError:
        return None


def puede_cifrar() -> bool:
    return _fernet() is not None


def cifrar(texto: str) -> str:
    f = _fernet()
    if not f:
        raise AjusteInvalido(f"falta {MAESTRA_ENV} en el servidor (o no es válida): no se pueden guardar claves aquí")
    return f.encrypt(texto.encode()).decode()


def descifrar(token: str) -> str | None:
    """La clave en claro, o None si falta la clave maestra o no corresponde (la llamada pasa al respaldo)."""
    from cryptography.fernet import InvalidToken
    f = _fernet()
    try:
        return f.decrypt(token.encode()).decode() if f else None
    except InvalidToken:
        return None
