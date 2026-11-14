"""Aislamiento entre empresas en la consola: nadie ve ni toca lo de otra empresa, ni por id."""
from fastapi.testclient import TestClient

from conftest import contrato, sesion
from helpert_server import db
from test_ajustes import admin
from test_campo import PNG, csrf_sesion
from test_consola import csrf_de, entrar
from test_flujo import enviar


def empresa_b(api, falso):
    """Empresa B con su equipo, una persona, un caso escalado con visita y captura."""
    token = db.equipo_nuevo(api.ruta_db, "pc-b")
    emp, _ = sesion(api.ruta_db, "pc-b", "bea", "bea@beta.pe", "Beta SAC")
    cli = TestClient(api.app, headers={"Authorization": f"Bearer {token}"})
    falso["a"].append(contrato(escalar=True, categoria="Hardware", respuesta="Hay que revisarlo."))
    cid = cli.post("/v1/mensaje", json={"texto": "secreto de beta", "usuario": "bea", "so": "linux"}).json()["caso_id"]
    with db.conexion(api.ruta_db) as c:
        c.execute("INSERT INTO capturas (caso_id, acepta, tipo, datos, tamano) VALUES (%s, true, 'image/png', %s, 72)", (cid, PNG))
        ids = {"caso": cid, "empresa": emp,
               "captura": c.execute("SELECT id FROM capturas WHERE caso_id = %s", (cid,)).fetchone()["id"],
               "visita": c.execute("SELECT id FROM visitas WHERE caso_id = %s", (cid,)).fetchone()["id"],
               "equipo": c.execute("SELECT id FROM equipos WHERE nombre = 'pc-b'").fetchone()["id"]}
    db.usuario_consola(api.ruta_db, "jefa@beta.pe", "admin_empresa", "clave-larga-456", "Jefa B", emp)
    with db.conexion(api.ruta_db) as c:
        ids["cuenta"] = c.execute("SELECT id FROM usuarios_consola WHERE email = 'jefa@beta.pe'").fetchone()["id"]
    return ids


def test_admin_de_empresa_solo_ve_la_suya(servidor, falso):
    api, web = admin(servidor)  # administración de la plataforma
    b = empresa_b(api, falso)
    falso["a"].append(contrato(pregunta="¿Qué ves?"))
    caso_a = enviar(api, "problema de alfa")["caso_id"]
    with db.conexion(api.ruta_db) as c:
        emp_a = c.execute("SELECT empresa_id FROM casos WHERE id = %s", (caso_a,)).fetchone()["empresa_id"]
        eq_a = c.execute("SELECT id FROM equipos WHERE nombre = 'pc-1'").fetchone()["id"]
    db.usuario_consola(api.ruta_db, "jefe@alfa.pe", "admin_empresa", "clave-larga-789", "Jefe A", emp_a)
    jefe = TestClient(api.app, base_url="https://helpert.ejemplo.pe")
    assert entrar(jefe, "jefe@alfa.pe", "clave-larga-789").status_code == 303

    lista = jefe.get("/consola?estado=todos").text
    assert f"#{caso_a}" in lista and f"#{b['caso']}" not in lista
    for ruta in (f"/consola/caso/{b['caso']}", f"/consola/caso/{b['caso']}/captura/{b['captura']}",
                 f"/consola/admin/equipos/{b['equipo']}", f"/consola/admin/empresas/{b['empresa']}",
                 "/consola/admin/general", "/consola/admin/ia", "/consola/admin/auditoria", "/consola/admin/categorias"):
        assert jefe.get(ruta).status_code == 404, ruta
    assert "secreto de beta" not in jefe.get("/consola/visitas").text
    assert "Beta SAC" not in jefe.get("/consola/metricas").text
    csv = jefe.get("/consola/metricas/casos.csv").text
    assert "problema" not in csv and "bea@beta.pe" not in csv and "ana@empresa.pe" in csv
    t = csrf_sesion(jefe)
    for ruta in (f"/consola/visitas/{b['visita']}/cancelar", f"/consola/caso/{b['caso']}/tomar",
                 f"/consola/caso/{b['caso']}/visita", f"/consola/admin/equipos/{b['equipo']}/revocar",
                 f"/consola/admin/usuarios/{b['cuenta']}/desactivar", f"/consola/admin/empresas/{b['empresa']}/sede"):
        assert jefe.post(ruta, data={"csrf": t, "sede": "X"}).status_code == 404, ruta
    # no puede crear una cuenta de la plataforma, ni de otra empresa
    jefe.post("/consola/admin/usuarios", data={"email": "x@alfa.pe", "rol": "admin", "csrf": t})
    jefe.post("/consola/admin/usuarios", data={"email": "y@alfa.pe", "rol": "tecnico", "empresa": str(b["empresa"]), "csrf": t})
    with db.conexion(api.ruta_db) as c:
        assert not c.execute("SELECT 1 FROM usuarios_consola WHERE email = 'x@alfa.pe'").fetchone()
        assert c.execute("SELECT empresa_id FROM usuarios_consola WHERE email = 'y@alfa.pe'").fetchone()["empresa_id"] == emp_a
    # su privacidad queda solo para su empresa
    jefe.post("/consola/admin/privacidad/capturas", data={"activas": "1", "dias": "30", "csrf": t, "empresa": str(b["empresa"])})
    with db.conexion(api.ruta_db) as c:
        propias = c.execute("SELECT empresa_id FROM ajustes_empresa").fetchall()
    assert [x["empresa_id"] for x in propias] == [emp_a]
    # sí gestiona lo suyo: equipo, personas y código de acceso
    assert jefe.get(f"/consola/admin/equipos/{eq_a}").status_code == 200
    jefe.post(f"/consola/admin/empresas/{emp_a}/persona", data={"email": "nuevo@alfa.pe", "csrf": t})
    with db.conexion(api.ruta_db) as c:
        pid = c.execute("SELECT id FROM personas WHERE email = 'nuevo@alfa.pe'").fetchone()["id"]
    r = jefe.post(f"/consola/admin/empresas/{emp_a}/persona_codigo?persona={pid}", data={"csrf": t})
    codigo = r.text.split('id="secreto"')[1].split(">")[1].split("<")[0]
    assert api.post("/v1/cuenta/entrar", json={"usuario": "nuevo", "email": "nuevo@alfa.pe", "codigo": codigo}).json()["sesion"]

    # el servidor vuelve a arrancar con cuentas de empresa ya creadas (el esquema corre en cada arranque)
    db.iniciar(api.ruta_db)
    # la plataforma ve las dos
    todo = web.get("/consola?estado=todos").text
    assert f"#{caso_a}" in todo and f"#{b['caso']}" in todo
    assert web.get(f"/consola/caso/{b['caso']}/captura/{b['captura']}").content == PNG


def test_tecnico_de_empresa_y_visitas(servidor, falso):
    api, web = admin(servidor)
    b = empresa_b(api, falso)
    db.usuario_consola(api.ruta_db, "tec@beta.pe", "tecnico", "clave-larga-321", "Tec B", b["empresa"])
    with db.conexion(api.ruta_db) as c:
        tec_b = c.execute("SELECT id FROM usuarios_consola WHERE email = 'tec@beta.pe'").fetchone()["id"]
        emp_a = c.execute("SELECT id FROM empresas WHERE nombre = 'Mi organización'").fetchone()["id"]
    db.usuario_consola(api.ruta_db, "tec@alfa.pe", "tecnico", "clave-larga-321", "Tec A", emp_a)
    with db.conexion(api.ruta_db) as c:
        tec_a = c.execute("SELECT id FROM usuarios_consola WHERE email = 'tec@alfa.pe'").fetchone()["id"]
    t = csrf_de(web, "/consola/visitas")
    # un técnico de A no puede atender una visita de B
    assert web.post(f"/consola/visitas/{b['visita']}/asignar", data={"tecnico": tec_a, "minutos": "30", "prioridad": "alta",
                                                                    "csrf": t}).status_code == 422
    r = web.post(f"/consola/visitas/{b['visita']}/asignar", data={"tecnico": tec_b, "minutos": "30", "prioridad": "alta", "csrf": t},
                 follow_redirects=False)
    assert r.status_code == 303


def test_n2_pasa_a_n3_y_resuelve(servidor, falso):
    api, web = admin(servidor)
    falso["a"].append(contrato(escalar=True, respuesta="Necesita a alguien."))
    cid = enviar(api)["caso_id"]
    t = csrf_de(web, f"/consola/caso/{cid}")
    web.post(f"/consola/caso/{cid}/tomar", data={"csrf": t})
    web.post(f"/consola/caso/{cid}/n3", data={"csrf": t})
    with db.conexion(api.ruta_db) as c:
        k = c.execute("SELECT nivel, asignado_id FROM casos WHERE id = %s", (cid,)).fetchone()
    assert k["nivel"] == 3 and k["asignado_id"] is None
    assert "N3 · Analista" in web.get(f"/consola/caso/{cid}").text
    assert web.post(f"/consola/caso/{cid}/resolver", data={"solucion": "", "csrf": t}).status_code == 422
    web.post(f"/consola/caso/{cid}/resolver", data={"solucion": "Reinstalé el controlador", "csrf": t})
    aviso = api.post("/v1/latido", json={}).json()["avisos"][0]
    assert aviso["cierre"] and "Reinstalé el controlador" in aviso["texto"]
    r = api.post("/v1/cierre", json={"usuario": "ana", "caso_id": cid, "resuelto": True, "calificacion": 5}).json()
    assert r["estado"] == "cerrado"


def test_empresa_fondo_y_recargas(servidor, falso):
    api, web = admin(servidor)
    with db.conexion(api.ruta_db) as c:
        emp = c.execute("SELECT id FROM empresas WHERE nombre = 'Mi organización'").fetchone()["id"]
    t = csrf_de(web, f"/consola/admin/empresas/{emp}")
    # el fondo no se activa si un proveedor externo no tiene precio: nunca bajaría
    from test_areas_y_claves import poner
    poner(api, "ia", [{"proveedor": "falso-a", "modelo": "a"}])
    r = web.post(f"/consola/admin/empresas/{emp}/fondo", data={"fondo_activo": "1", "alerta_usd": "5", "csrf": t})
    assert "Pon el precio" in r.text
    poner(api, "ia", [{"proveedor": "falso-a", "modelo": "a", "precio_entrada": 1, "precio_salida": 5}])
    web.post(f"/consola/admin/empresas/{emp}/fondo", data={"fondo_activo": "1", "alerta_usd": "5", "csrf": t})
    web.post(f"/consola/admin/empresas/{emp}/recarga", data={"monto": "3", "nota": "Prueba", "csrf": t})
    pagina = web.get(f"/consola/admin/empresas/{emp}").text
    assert "US$ 3.00" in pagina and "Fondo de IA bajo" in pagina  # 3 < alerta de 5
    web.post(f"/consola/admin/empresas/{emp}/sede", data={"sede": "Miraflores", "region": "Lima", "csrf": t})
    web.post(f"/consola/admin/empresas/{emp}/datos", data={"nombre": "Alfa", "telefono": "+51 1 555", "remoto": "rustdesk",
                                                           "dominios": "alfa.pe", "sla_n2": "60", "sla_n3": "480", "activa": "1",
                                                           "csrf": t})
    r = api.post("/v1/cuenta/estado", json={"usuario": "ana"}).json()
    assert r["empresa"]["telefono"] == "+51 1 555" and r["empresa"]["remoto"] == "rustdesk"
    assert r["sedes"] == [{"nombre": "Miraflores", "region": "Lima"}]
    # el agente informa el ID de control remoto; el técnico lo ve en el caso
    api.post("/v1/latido", json={}, headers={"X-Helpert-Remoto": "rustdesk:123456789"})
    assert api.post("/v1/cuenta/estado", json={"usuario": "ana"}).json()["remoto_id"] == "rustdesk:123456789"
