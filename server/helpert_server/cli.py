"""helpert-server: servir la API, registrar equipos, firmar playbooks, ver casos y evaluar modelos."""
import argparse
import getpass
import hashlib
import json
import os
import re
import sys
import time
import tomllib
from pathlib import Path

from . import catalogo as cat
from . import ajustes, db, ia


def leer_config(ruta: str) -> dict:
    p = Path(ruta)
    cfg = tomllib.loads(p.read_text())
    cfg["playbooks"] = str((p.resolve().parent / cfg["playbooks"]).resolve())  # relativa a la carpeta del archivo
    if "clave_publica" in cfg:  # para comprobar las versiones del agente que se publican
        cfg["clave_publica"] = str((p.resolve().parent / cfg["clave_publica"]).resolve())
    if "base_datos_env" in cfg:  # en la nube la cadena de conexión (con contraseña) va en una variable de entorno
        cfg["base_datos"] = os.environ[cfg["base_datos_env"]]
    return cfg


def revisar(cfg: dict) -> list[tuple[str, str]]:
    """Lista de comprobación antes de abrir el servidor a los equipos: (estado, texto) con estado «bien», «aviso»
    (conviene, no impide) o «falta» (hay que arreglarlo)."""
    r = []
    try:
        db.iniciar(cfg["base_datos"])
        with db.conexion(cfg["base_datos"]) as c:
            aj = ajustes.leer(c, cfg)
            admins = c.execute("SELECT count(*) AS n FROM usuarios_consola WHERE rol = 'admin' AND activo").fetchone()["n"]
        r.append(("bien", "Base de datos: responde y el esquema está al día"))
    except Exception as e:  # sin base no se puede revisar lo demás
        return [("falta", f"Base de datos: {type(e).__name__}: {e}")]
    r.append(("bien", f"Cuentas de administración: {admins}") if admins else
             ("falta", "No hay ninguna cuenta admin: helpert-server usuario-consola CORREO --rol admin"))
    if not os.environ.get(ajustes.MAESTRA_ENV):
        r.append(("falta", f"{ajustes.MAESTRA_ENV} no está: sin ella no se pueden guardar claves de API en la consola"))
    elif ajustes._fernet() is None:
        r.append(("falta", f"{ajustes.MAESTRA_ENV} no es válida (32 bytes en base64 url)"))
    else:
        r.append(("bien", f"{ajustes.MAESTRA_ENV}: presente (guárdala aparte: sin ella, las claves de API guardadas no se leen)"))
    ins = aj["inscripcion"]
    con_clave = ins["clave_sha"] or (cfg.get("inscripcion_env") and os.environ.get(cfg["inscripcion_env"]))
    r.append(("bien", "Inscripción de equipos: activa") if ins["activa"] and con_clave else
             ("aviso", "Inscripción de equipos: sin clave o desactivada (los instaladores no podrán registrar equipos)"))
    pub = cfg.get("clave_publica")
    if not pub or not Path(pub).is_file():
        r.append(("falta", f"Clave pública de los playbooks: no está ({pub or 'clave_publica sin poner'})"))
    else:
        paquetes = sorted(Path(cfg["playbooks"]).glob("*/manifest.toml"))
        malos = [m.parent.name for m in paquetes if not cat.firma_valida(m.parent, Path(pub))]
        if not paquetes:
            r.append(("falta", f"Playbooks: no hay ninguno en {cfg['playbooks']}"))
        elif malos:
            r.append(("falta", f"Playbooks sin firma válida para esta clave pública: {', '.join(malos)}"))
        else:
            todos = cat.cargar(cfg["playbooks"]).values()
            win = sum("windows" in pb.sistemas for pb in todos)
            r.append(("bien", f"Playbooks: {len(paquetes)} firmados ({win} con Windows)"))
    aj["ia"] = [p for p in aj["ia"] if p.get("activo", True)]
    externos = [p for p in aj["ia"] if not p.get("local")]
    sin_clave = [p["proveedor"] for p in externos if p["proveedor"] != "ollama" and not p.get("clave_cifrada")
                 and not (p.get("clave_env") and os.environ.get(p["clave_env"]))]
    if not aj["ia"]:
        r.append(("aviso", "IA: la cadena está vacía; Helpert solo ofrecerá el menú de playbooks"))
    elif sin_clave:
        r.append(("falta", f"IA: sin clave de API para {', '.join(sin_clave)} (Consola → Administración → IA)"))
    else:
        r.append(("bien", "IA: " + " → ".join(f"{p['proveedor']} {p['modelo']}" for p in aj["ia"])))
    # el catálogo entero va en las instrucciones: un Ollama con poco contexto lo recibe cortado, sin avisar
    if Path(cfg["playbooks"]).is_dir():
        catalogo = ajustes.catalogo_activo(cat.cargar(cfg["playbooks"]), aj)
        largo = max(len(ia.instrucciones(catalogo, so, aj["categorias"])) for so in ("linux", "windows", "macos"))
        for p in aj["ia"]:
            ctx = int(p.get("contexto") or ia.CONTEXTO)
            if p["proveedor"] == "ollama" and largo > ctx * ia.CATALOGO_MAX / ia.CONTEXTO:
                r.append(("falta", f"IA: Ollama {p['modelo']} tiene contexto {ctx} y el catálogo no cabe: súbelo a "
                                   f"{ia.CONTEXTO} en Consola → Administración → IA"))
    r.append(("bien", "Correo: códigos de acceso por correo") if cfg.get("smtp") else
             ("aviso", "Correo: sin [smtp]; los códigos de acceso los genera soporte en la consola"))
    return r


def evaluar(cfg: dict, casos_ruta: str, indice: int, pausa: float = 0) -> dict:
    """Corre los casos etiquetados contra UN proveedor de la cadena (sin respaldo) y mide. La cadena, las categorías
    y los playbooks activos son los vigentes (los de la consola), así se evalúa lo que de verdad se usa."""
    db.iniciar(cfg["base_datos"])
    with db.conexion(cfg["base_datos"]) as c:
        aj = ajustes.leer(c, cfg)
    catalogo = ajustes.catalogo_activo(cat.cargar(cfg["playbooks"]), aj)
    if not 0 <= indice < len(aj["ia"]):
        sys.exit(f"No hay proveedor {indice}: la cadena tiene {len(aj['ia'])} (índice desde 0, en el orden de la consola)")
    prov, cats = aj["ia"][indice], tuple(aj["categorias"])
    umbral = float(cfg.get("umbral_confianza", 0.7))
    casos = [json.loads(l) for l in Path(casos_ruta).read_text().splitlines() if l.strip()]
    filas, tiempos = [], []
    for k in casos:
        # «historial»: turnos previos [rol, texto]; se mide lo que recibe la persona en el último (ia.resolver, como la API)
        previos = k.get("historial", [])
        mensajes = [{"role": r, "content": x} for r, x in previos] + [{"role": "user", "content": k["texto"]}]
        time.sleep(pausa)  # planes gratuitos de API: pocas peticiones por minuto
        t = time.monotonic()
        contrato, modelo, nota, _ = ia.decidir([prov], ia.instrucciones(catalogo, k["so"], aj["categorias"]), mensajes, cats)
        tiempos.append(time.monotonic() - t)
        mensaje = ""
        if contrato is None:
            obtenido, cat_ok = ("error" if modelo is None else "invalida"), False
        else:
            que, pb, _, _, mensaje = ia.resolver(contrato, catalogo, k["so"], umbral, k["texto"],
                                                 sum(r == "assistant" for r, _ in previos),
                                                 " ".join(x for r, x in previos if r == "user") + " " + k["texto"])
            obtenido = f"playbook:{pb.id}" if que == "playbook" else que
            cat_ok = contrato.categoria == k.get("categoria")
        esperado = k["esperado"] if isinstance(k["esperado"], list) else [k["esperado"]]
        comandos = obtenido == "guia" and COMANDOS.search(mensaje or "")
        ok = obtenido in esperado and not comandos
        filas.append({**k, "obtenido": obtenido + (" (con comandos)" if comandos else ""), "ok": ok, "categoria_ok": cat_ok,
                      "nota": nota, "mensaje": (mensaje or "")[:300]})
    pct = lambda xs: round(100 * sum(xs) / len(xs), 1) if xs else None
    tiempos.sort()
    grupos = sorted({f["grupo"] for f in filas})
    return {
        "modelo": f"{prov['proveedor']}:{prov['modelo']}",
        "casos": len(filas),
        "correctos_pct": pct([f["ok"] for f in filas]),
        "por_grupo_pct": {g: pct([f["ok"] for f in filas if f["grupo"] == g]) for g in grupos},
        "categoria_correcta_pct": pct([f["categoria_ok"] for f in filas if f.get("categoria")]),
        "salidas_invalidas": sum(f["obtenido"] == "invalida" for f in filas),
        "errores_proveedor": sum(f["obtenido"] == "error" for f in filas),
        "p95_segundos": round(tiempos[max(0, int(len(tiempos) * 0.95) - 1)], 2) if tiempos else None,
        "fallos": [{k: f[k] for k in ("texto", "grupo", "esperado", "obtenido", "mensaje")} for f in filas if not f["ok"]],
    }


# Una guía nunca lleva comandos: si aparece uno, el caso cuenta como fallo aunque el resultado fuera «guía».
COMANDOS = re.compile(r"\b(sudo|rm -|chmod|chown|curl|wget|powershell|cmd\.exe|regedit|reg add|netsh|ipconfig|bash|apt |dnf |pacman)\b"
                      r"|`[^`]+`|\$ ", re.I)


def main(argv=None):
    p = argparse.ArgumentParser(prog="helpert-server")
    p.add_argument("--config", default="helpert-server.toml")
    sub = p.add_subparsers(dest="orden", required=True)
    s = sub.add_parser("servir", help="Inicia la API")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--puerto", type=int, default=8000)
    s = sub.add_parser("equipo-nuevo", help="Registra un equipo e imprime su token")
    s.add_argument("nombre")
    s = sub.add_parser("claves", help="Genera el par de claves para firmar playbooks")
    s.add_argument("destino")
    s = sub.add_parser("firmar", help="Firma todos los paquetes de una carpeta")
    s.add_argument("carpeta")
    s.add_argument("--clave", required=True)
    sub.add_parser("casos", help="Lista los últimos casos")
    s = sub.add_parser("firmar-agente", help="Firma un binario del agente (fuera del servidor, con la clave privada)")
    s.add_argument("binario")
    s.add_argument("--version", required=True)
    s.add_argument("--so", default="linux", choices=("linux", "windows"))
    s.add_argument("--clave", required=True)
    s = sub.add_parser("publicar-agente", help="Sube un binario firmado del agente; se despliega desde la consola")
    s.add_argument("binario")
    s.add_argument("--version", required=True)
    s.add_argument("--so", default="linux", choices=("linux", "windows"))
    s.add_argument("--firma", required=True, help="Archivo .firma que dejó firmar-agente")
    sub.add_parser("revisar", help="Comprueba la configuración antes de abrir el servidor a los equipos")
    sub.add_parser("purgar", help="Borra las capturas vencidas (también lo hace el servidor cada hora)")
    s = sub.add_parser("usuario-consola", help="Crea una persona de la consola web o le cambia la contraseña")
    s.add_argument("email")
    s.add_argument("--rol", required=True, choices=db.ROLES)
    s.add_argument("--nombre")
    s.add_argument("--empresa", help="Nombre de la empresa: obligatorio para admin_empresa; sin él, analista, tecnico y gerencia ven todas")
    s = sub.add_parser("persona", help="Da de alta a una persona (y su empresa si no existe) e imprime su código de acceso")
    s.add_argument("email")
    s.add_argument("--empresa", required=True, help="Nombre de la empresa; se crea si no existe")
    s.add_argument("--nombre")
    s = sub.add_parser("evaluar", help="Mide un proveedor con los casos etiquetados")
    s.add_argument("casos")
    s.add_argument("--proveedor", type=int, default=0, help="Posición en la cadena de la consola (0 = principal)")
    s.add_argument("--pausa", type=float, default=0, help="Segundos entre casos (planes gratuitos con límite por minuto)")
    a = p.parse_args(argv)

    if a.orden == "claves":
        priv, pub = cat.generar_claves(Path(a.destino))
        print(f"Clave privada: {priv} (guárdala fuera del repositorio y de los equipos)\nClave pública: {pub}")
        return
    if a.orden == "firmar":
        cat.firmar(Path(a.carpeta), Path(a.clave))
        print(f"Firmados los paquetes de {a.carpeta}")
        return
    if a.orden == "firmar-agente":
        sha, firma = cat.firmar_actualizacion(Path(a.binario), a.version, a.so, Path(a.clave))
        Path(a.binario + ".firma").write_text(firma + "\n")
        print(f"Firmado {a.binario} {a.version} ({a.so}) · sha256 {sha}\nFirma: {a.binario}.firma")
        return

    cfg = leer_config(a.config)
    if a.orden == "revisar":
        marcas = {"bien": "✓", "aviso": "!", "falta": "✗"}
        lista = revisar(cfg)
        for estado, texto in lista:
            print(f" {marcas[estado]} {texto}")
        sys.exit(1 if any(e == "falta" for e, _ in lista) else 0)
    if a.orden == "servir":
        import uvicorn
        from .app import crear_app
        if a.host not in ("127.0.0.1", "localhost", "::1"):
            # shortcut: token por equipo sin TLS; antes de exponerlo en la red, poner TLS mutuo (ver el plan).
            print("Aviso: sin TLS. Solo para pruebas.", file=sys.stderr)
        # detrás de Caddy en el mismo equipo: la IP y el https de la persona vienen en X-Forwarded-*; solo se creen
        # si la conexión llega desde 127.0.0.1 (el límite de intentos de la consola y la cookie Secure dependen de esto)
        uvicorn.run(crear_app(cfg), host=a.host, port=a.puerto, proxy_headers=True, forwarded_allow_ips="127.0.0.1")
    elif a.orden == "equipo-nuevo":
        db.iniciar(cfg["base_datos"])
        print(db.equipo_nuevo(cfg["base_datos"], a.nombre))
    elif a.orden == "usuario-consola":
        db.iniciar(cfg["base_datos"])
        if (a.rol == "admin" and a.empresa) or (a.rol == "admin_empresa" and not a.empresa):
            sys.exit("admin es de la plataforma (sin --empresa); admin_empresa necesita --empresa")
        empresa_id = None
        if a.empresa:
            with db.conexion(cfg["base_datos"]) as c:
                f = c.execute("SELECT id FROM empresas WHERE nombre = %s", (a.empresa,)).fetchone()
            if not f:
                sys.exit(f"No existe la empresa «{a.empresa}»")
            empresa_id = f["id"]
        clave = getpass.getpass("Contraseña (mínimo 12 caracteres): ")
        if clave != getpass.getpass("Repítela: "):
            sys.exit("Las contraseñas no coinciden")
        db.usuario_consola(cfg["base_datos"], a.email, a.rol, clave, a.nombre, empresa_id)
        print(f"Listo: {a.email} ({a.rol})")
    elif a.orden == "persona":
        db.iniciar(cfg["base_datos"])
        email = a.email.strip().lower()
        with db.conexion(cfg["base_datos"]) as c:
            emp = (c.execute("SELECT id FROM empresas WHERE nombre = %s", (a.empresa,)).fetchone()
                   or c.execute("INSERT INTO empresas (nombre) VALUES (%s) RETURNING id", (a.empresa,)).fetchone())["id"]
            per = c.execute("SELECT empresa_id FROM personas WHERE email = %s", (email,)).fetchone()
            if per and per["empresa_id"] != emp:
                sys.exit(f"{email} ya es de otra empresa")
            if not per:
                c.execute("INSERT INTO personas (empresa_id, email, nombre) VALUES (%s, %s, %s)", (emp, email, a.nombre))
            codigo = db.codigo_nuevo(c, email, 60 * 24, 10, digitos=False)  # como el de la consola: 24 h
            db.auditar(c, "línea de comandos", "Generó un código de acceso", email)
        print(f"{email} ({a.empresa}) · código de acceso, vale 24 h y un solo uso: {codigo}")
    elif a.orden == "publicar-agente":
        if not re.fullmatch(r"[0-9A-Za-z.+-]{1,32}", a.version):
            sys.exit("Versión no válida")
        if not cfg.get("clave_publica"):
            sys.exit("Falta clave_publica en la configuración del servidor: sin ella no se puede comprobar la firma")
        datos = Path(a.binario).read_bytes()
        sha, firma = hashlib.sha256(datos).hexdigest(), Path(a.firma).read_text().strip()
        if not cat.verificar_actualizacion(Path(cfg["clave_publica"]), a.version, a.so, sha, firma):
            sys.exit("La firma no corresponde a este binario, versión y sistema (o a la clave pública del servidor)")
        db.iniciar(cfg["base_datos"])
        with db.conexion(cfg["base_datos"]) as c:
            c.execute("INSERT INTO versiones_agente (sha256, version, so, firma, datos, tamano, persona) "
                      "VALUES (%s, %s, %s, %s, %s, %s, 'línea de comandos') ON CONFLICT (sha256) DO NOTHING",
                      (sha, a.version, a.so, firma, datos, len(datos)))
            db.auditar(c, "línea de comandos", "Publicó una versión del agente", f"{a.version} ({a.so}) · {sha[:12]}")
        print(f"Publicada {a.version} ({a.so}) · {sha[:12]}. Despliégala desde Consola → Administración → Equipos.")
    elif a.orden == "purgar":
        from . import ajustes
        db.iniciar(cfg["base_datos"])
        with db.conexion(cfg["base_datos"]) as c:
            n = c.execute("UPDATE capturas SET datos = NULL, borrada = now() WHERE datos IS NOT NULL "
                          "AND ts < now() - make_interval(days => %s)", (ajustes.leer(c, cfg)["capturas"]["dias"],)).rowcount
        print(f"Capturas borradas: {n}")
    elif a.orden == "casos":
        db.iniciar(cfg["base_datos"])
        with db.conexion(cfg["base_datos"]) as c:
            for f in c.execute("SELECT id, creado, usuario, estado, categoria, playbook, modelo, calificacion "
                               "FROM casos ORDER BY id DESC LIMIT 30"):
                print(" · ".join(str(v) for v in dict(f).values()))
    elif a.orden == "evaluar":
        print(json.dumps(evaluar(cfg, a.casos, a.proveedor, a.pausa), ensure_ascii=False, indent=2))
