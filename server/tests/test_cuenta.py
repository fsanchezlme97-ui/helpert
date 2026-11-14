"""Multiempresa en la API: inicio de sesión en la bandeja, calificación obligatoria, niveles y fondo de IA."""
from helpert_server import app as app_mod
from helpert_server import db
import re

from conftest import RAIZ, contrato, sesion
from test_flujo import ELIGE_DEMO, enviar, resultado
from test_areas_y_claves import poner


def cuenta(api, accion, **k):
    return api.post(f"/v1/cuenta/{accion}", json={"usuario": "luis", **k})


def codigo_de_consola(api, email):
    with db.conexion(api.ruta_db) as c:
        return db.codigo_nuevo(c, email, 60 * 24, 10, digitos=False)


def test_inicio_de_sesion_con_codigo(servidor):
    api = servidor()
    with db.conexion(api.ruta_db) as c:
        emp = c.execute("INSERT INTO empresas (nombre, telefono, remoto) VALUES ('Acme', '+51 1 555', 'rustdesk') RETURNING id").fetchone()["id"]
        c.execute("INSERT INTO sedes (empresa_id, nombre, region) VALUES (%s, 'Miraflores', 'Lima')", (emp,))
        c.execute("UPDATE equipos SET empresa_id = NULL")  # equipo recién inscrito
        c.execute("DELETE FROM sesiones_persona")
    db.persona_nueva(api.ruta_db, emp, "luis@acme.pe", "Luis")
    assert cuenta(api, "estado").json() == {"sesion": False, "correo_activo": False}
    assert api.post("/v1/mensaje", json={"texto": "hola", "usuario": "luis", "so": "linux"}).status_code == 401
    # sin SMTP no se genera nada por la API: el código lo da soporte desde la consola
    assert "Pide tu código" in cuenta(api, "codigo", email="luis@acme.pe").json()["respuesta"]
    codigo = codigo_de_consola(api, "luis@acme.pe")
    assert cuenta(api, "entrar", email="luis@acme.pe", codigo="MAL").status_code == 401
    r = cuenta(api, "entrar", email="LUIS@acme.pe", codigo=codigo.lower()).json()
    assert r["sesion"] and r["empresa"]["nombre"] == "Acme" and r["sedes"] == [{"nombre": "Miraflores", "region": "Lima"}]
    assert cuenta(api, "entrar", email="luis@acme.pe", codigo=codigo).status_code == 401  # un solo uso
    with db.conexion(api.ruta_db) as c:
        assert c.execute("SELECT empresa_id FROM equipos").fetchone()["empresa_id"] == emp  # el equipo pasó a Acme
    assert cuenta(api, "perfil", nombre="Luis P.", sede="Otra").status_code == 422
    assert cuenta(api, "perfil", nombre="Luis P.", telefono="999", sede="Miraflores").json()["persona"]["sede"] == "Miraflores"
    # alguien de otra empresa no puede usar este equipo
    with db.conexion(api.ruta_db) as c:
        otra = c.execute("INSERT INTO empresas (nombre) VALUES ('Otra SAC') RETURNING id").fetchone()["id"]
    db.persona_nueva(api.ruta_db, otra, "eva@otra.pe")
    r = api.post("/v1/cuenta/entrar", json={"usuario": "eva", "email": "eva@otra.pe", "codigo": codigo_de_consola(api, "eva@otra.pe")})
    assert r.status_code == 403
    assert cuenta(api, "salir").json() == {"sesion": False}
    assert cuenta(api, "casos").status_code == 401


def test_codigo_por_correo_y_limites(servidor, monkeypatch):
    api = servidor()
    enviados = []
    monkeypatch.setattr(app_mod, "correo", lambda cfg, para, asunto, texto: enviados.append((para, re.search(r"\d{6}", texto)[0])) or True)
    with db.conexion(api.ruta_db) as c:
        c.execute("INSERT INTO empresas (nombre, dominios) VALUES ('Acme', '{acme.pe}')")
        c.execute("UPDATE equipos SET empresa_id = NULL")
    from helpert_server.app import crear_app
    from fastapi.testclient import TestClient
    cfg = {"base_datos": api.ruta_db, "playbooks": str(RAIZ / "pruebas" / "playbooks"), "ia": [], "smtp": {"host": "x", "remitente": "h@x"}}
    cli = TestClient(crear_app(cfg), headers=dict(api.headers))
    misma = cli.post("/v1/cuenta/codigo", json={"usuario": "u", "email": "nadie@fuera.pe"}).json()
    assert not enviados  # correo sin cuenta ni dominio: nada se envía, y la respuesta es la misma
    r = cli.post("/v1/cuenta/codigo", json={"usuario": "u", "email": "nueva@acme.pe"}).json()
    assert r == misma and enviados[0][0] == "nueva@acme.pe"
    for _ in range(5):  # cinco intentos fallidos agotan los códigos vigentes
        cli.post("/v1/cuenta/entrar", json={"usuario": "u", "email": "nueva@acme.pe", "codigo": "000000"})
    assert cli.post("/v1/cuenta/entrar", json={"usuario": "u", "email": "nueva@acme.pe", "codigo": enviados[0][1]}).status_code == 401
    for _ in range(4):
        cli.post("/v1/cuenta/codigo", json={"usuario": "u", "email": "nueva@acme.pe"})
    assert len(enviados) == 3  # como mucho 3 códigos cada 15 minutos
    r = cli.post("/v1/cuenta/entrar", json={"usuario": "u", "email": "nueva@acme.pe", "codigo": enviados[-1][1]}).json()
    assert r["sesion"] and r["empresa"]["nombre"] == "Acme"  # su dominio la deja entrar sola: se creó la persona


def test_calificacion_obligatoria_y_cierre_automatico(servidor, falso):
    api = servidor()
    falso["a"].append(ELIGE_DEMO)
    r = resultado(api, enviar(api)["trabajo"], codigo=10, salida="Nada que corregir")
    cid = r["caso_id"]
    assert r["cierre"]
    r = enviar(api, "otro problema")  # no abre un caso nuevo: primero se califica el anterior
    assert r["caso_id"] == cid and r["cierre"] and r["pendiente"]
    assert api.post("/v1/cierre", json={"caso_id": cid, "resuelto": True}).status_code == 422  # sin nota no se cierra
    assert api.post("/v1/cierre", json={"caso_id": cid, "resuelto": True, "calificacion": 4}).json()["estado"] == "cerrado"
    historial = api.post("/v1/cuenta/casos", json={"usuario": "ana"}).json()["casos"]
    assert historial[0]["id"] == cid and historial[0]["titulo"] == "no funciona el archivo x1" and historial[0]["calificacion"] == 4

    falso["a"].append(ELIGE_DEMO)
    cid = resultado(api, enviar(api)["trabajo"], codigo=10)["caso_id"]
    with db.conexion(api.ruta_db) as c:
        c.execute("UPDATE mensajes SET ts = now() - interval '8 days' WHERE caso_id = %s", (cid,))
    from helpert_server.app import crear_app
    crear_app({"base_datos": api.ruta_db, "playbooks": str(RAIZ / "pruebas" / "playbooks"), "ia": []})  # la purga corre al arrancar
    with db.conexion(api.ruta_db) as c:
        k = c.execute("SELECT estado, nota, calificacion FROM casos WHERE id = %s", (cid,)).fetchone()
    assert k["estado"] == "cerrado" and "sin calificación" in k["nota"] and k["calificacion"] is None


def test_escalar_pasa_a_nivel_2(servidor, falso):
    api = servidor()
    falso["a"].append(contrato(escalar=True, respuesta="Necesita a una persona."))
    r = enviar(api)
    with db.conexion(api.ruta_db) as c:
        k = c.execute("SELECT nivel, escalado, empresa_id, persona_id FROM casos WHERE id = %s", (r["caso_id"],)).fetchone()
    assert k["nivel"] == 2 and k["escalado"] and k["empresa_id"] and k["persona_id"]


def test_fondo_agotado_usa_solo_ia_local(servidor, falso):
    api = servidor()
    with db.conexion(api.ruta_db) as c:
        emp = c.execute("SELECT empresa_id FROM equipos").fetchone()["empresa_id"]
        c.execute("UPDATE empresas SET fondo_activo = true WHERE id = %s", (emp,))
    r = enviar(api)  # sin saldo: ni a ni b (externos) se llaman; menú sin IA
    assert r["estado"] == "menu" and not falso["a"] and not falso["b"]
    poner(api, "ia", [{"proveedor": "falso-a", "modelo": "a", "precio_entrada": 1000, "precio_salida": 1000},
                      {"proveedor": "falso-b", "modelo": "b", "local": True}])
    falso["b"].append(ELIGE_DEMO)
    assert enviar(api)["trabajo"]["paso"] == "diagnosticar"  # el local sí atiende
    with db.conexion(api.ruta_db) as c:
        c.execute("INSERT INTO recargas (empresa_id, monto_usd) VALUES (%s, 1)", (emp,))
        c.execute("DELETE FROM trabajos")
        c.execute("UPDATE casos SET estado = 'cerrado'")
    from helpert_server import ia
    falso["a"].append(ia.respuesta(contrato(pregunta="¿Qué ves?"), 2000, 0))  # 2000 tokens a USD 1000/M = USD 2
    assert enviar(api)["respuesta"] == "¿Qué ves?"
    with db.conexion(api.ruta_db) as c:
        assert db.saldo(c, emp) == -1.0
    falso["b"].append(contrato(pregunta="¿Y ahora?"))
    assert enviar(api, "sigue")["respuesta"] == "¿Y ahora?"  # saldo negativo: de nuevo solo el local


def test_tope_por_persona(servidor, falso):
    api = servidor()
    poner(api, "ia", [{"proveedor": "falso-a", "modelo": "a", "precio_entrada": 1000}])
    with db.conexion(api.ruta_db) as c:
        c.execute("UPDATE empresas SET tope_persona_usd = 1")
    from helpert_server import ia
    falso["a"].append(ia.respuesta(contrato(pregunta="¿Qué ves?"), 1000, 0))
    cid = enviar(api)["caso_id"]
    r = enviar(api, "veo un error", cid)  # ya gastó USD 1 este mes: sin IA externa
    assert r["estado"] == "menu" and not falso["a"]
    # otra persona de la misma empresa sigue con IA
    with db.conexion(api.ruta_db) as c:
        c.execute("UPDATE casos SET estado = 'cerrado'")
    sesion(api.ruta_db, "pc-1", "beto", "beto@empresa.pe")
    falso["a"].append(contrato(pregunta="¿Hola?"))
    r = api.post("/v1/mensaje", json={"texto": "hola", "usuario": "beto", "so": "linux"}).json()
    assert r["respuesta"] == "¿Hola?"


def test_cli_persona_da_un_codigo(servidor, tmp_path, capsys):
    from helpert_server import cli
    api = servidor()
    conf = tmp_path / "s.toml"
    conf.write_text(f'base_datos = "{api.ruta_db}"\nplaybooks = "{RAIZ / "pruebas" / "playbooks"}"\n')
    cli.main(["--config", str(conf), "persona", "Rosa@Nueva.pe", "--empresa", "Nueva SAC", "--nombre", "Rosa"])
    codigo = capsys.readouterr().out.rsplit(" ", 1)[1].strip()
    with db.conexion(api.ruta_db) as c:
        c.execute("DELETE FROM sesiones_persona")
        c.execute("UPDATE equipos SET empresa_id = NULL")
    r = api.post("/v1/cuenta/entrar", json={"usuario": "rosa", "email": "rosa@nueva.pe", "codigo": codigo}).json()
    assert r["sesion"] and r["empresa"]["nombre"] == "Nueva SAC" and r["persona"]["nombre"] == "Rosa"
