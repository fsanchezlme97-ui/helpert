from fastapi.testclient import TestClient

from helpert_server import db
from conftest import contrato, sesion
from test_flujo import enviar, resultado

XSS = "<script>alert(1)</script>"


def entrar(cli, email="ana@empresa.pe", clave="clave-larga-123"):
    return cli.post("/consola/login", data={"email": email, "clave": clave}, follow_redirects=False)


def consola(servidor, rol="analista"):
    api = servidor()
    db.usuario_consola(api.ruta_db, "ana@empresa.pe", rol, "clave-larga-123", "Ana")
    web = TestClient(api.app, base_url="https://helpert.ejemplo.pe")  # https: la cookie es Secure
    return api, web


def test_sin_sesion_redirige_al_login(servidor):
    _, web = consola(servidor)
    for ruta in ("/consola", "/consola/metricas", "/consola/caso/1"):
        r = web.get(ruta, follow_redirects=False)
        assert r.status_code == 303 and r.headers["location"] == "/consola/login"


def test_login_cookie_segura_y_salir(servidor):
    _, web = consola(servidor)
    assert entrar(web, clave="otra-clave-mala").status_code == 401
    r = entrar(web)
    assert r.status_code == 303
    cookie = r.headers["set-cookie"].lower()
    assert "httponly" in cookie and "samesite=strict" in cookie and "secure" in cookie
    assert web.get("/consola").status_code == 200
    web.post("/consola/salir", follow_redirects=False)
    assert web.get("/consola", follow_redirects=False).status_code == 303


def test_sesion_robada_no_sirve_tras_salir(servidor):
    _, web = consola(servidor)
    entrar(web)
    token = web.cookies.get("helpert_sesion")
    web.post("/consola/salir")
    web.cookies.set("helpert_sesion", token, domain="helpert.ejemplo.pe")
    assert web.get("/consola", follow_redirects=False).status_code == 303


def test_limita_intentos_por_ip(servidor):
    _, web = consola(servidor)
    for _ in range(5):
        entrar(web, clave="mala-mala-mala")
    assert entrar(web).status_code == 429  # ni con la clave correcta, desde esa IP


def test_escapa_todo_lo_que_no_escribimos(servidor, falso):
    api, web = consola(servidor)
    falso["a"].append(contrato(subcategoria=XSS, respuesta=XSS,
                               playbook={"id": "demo.archivo", "parametros": {"nombre": "x1"}}))
    sesion(api.ruta_db, "pc-1", XSS, "otra@empresa.pe")
    r = api.post("/v1/mensaje", json={"texto": XSS + " x1", "usuario": XSS, "so": "linux"}).json()  # x1: el archivo elegido
    resultado(api, r["trabajo"], salida=XSS)
    entrar(web)
    for ruta in ("/consola?estado=todos", f"/consola/caso/{r['caso_id']}", "/consola/metricas"):
        html = web.get(ruta).text
        assert XSS not in html and "<script>" not in html, ruta  # solo hay <script src=…> propios
    assert "&lt;script&gt;" in web.get(f"/consola/caso/{r['caso_id']}").text


def test_cabeceras_de_seguridad(servidor):
    _, web = consola(servidor)
    entrar(web)
    r = web.get("/consola")
    csp = r.headers["content-security-policy"]
    assert "default-src 'none'" in csp and "script-src 'self';" in csp and "unsafe-inline" not in csp
    assert all(t.startswith(' src="/consola/estatico/') for t in r.text.split("<script")[1:])  # sin código en línea
    assert r.headers["cache-control"] == "no-store" and r.headers["x-frame-options"] == "DENY"


def test_gerencia_solo_ve_metricas(servidor, falso):
    api, web = consola(servidor, rol="gerencia")
    falso["a"].append(contrato(escalar=True))
    enviar(api)
    entrar(web)
    assert web.get("/consola", follow_redirects=False).headers["location"] == "/consola/metricas"
    assert web.get("/consola/caso/1").status_code == 403
    m = web.get("/consola/metricas").text
    assert "Metas del piloto" in m and "Escalados" in m


def test_metricas_con_un_caso_resuelto(servidor, falso):
    api, web = consola(servidor)
    falso["a"].append(contrato(playbook={"id": "demo.archivo", "parametros": {"nombre": "x1"}}))
    r = resultado(api, enviar(api)["trabajo"])
    r = api.post("/v1/confirmar", json={"usuario": "ana", "caso_id": r["caso_id"], "acepta": True}).json()
    for _ in range(3):
        r = resultado(api, r["trabajo"])
    api.post("/v1/cierre", json={"usuario": "ana", "caso_id": r["caso_id"], "resuelto": True, "calificacion": 5})
    entrar(web)
    m = web.get("/consola/metricas").text
    assert "100.0%" in m and "5.0 / 5" in m and "demo.archivo" in m


def test_sin_documentacion_publica(servidor):
    api = servidor()
    for ruta in ("/docs", "/redoc", "/openapi.json"):
        assert api.get(ruta).status_code == 404


def test_estaticos_propios(servidor):
    _, web = consola(servidor)
    for archivo in ("consola.css", "consola.js", "datatables.js", "choices.js", "echarts.js", "icono.png", "mascota.png", "fuentes/inter.woff2"):
        r = web.get(f"/consola/estatico/{archivo}")
        assert r.status_code == 200 and r.headers["x-content-type-options"] == "nosniff", archivo
    assert web.get("/consola/estatico/../app.py").status_code == 404


def test_datos_de_graficos_escapados(servidor, falso):
    import html as h, json, re
    api, web = consola(servidor)
    falso["a"].append(contrato(escalar=True))
    enviar(api)
    entrar(web)
    m = web.get("/consola/metricas").text
    atributos = re.findall(r'data-grafico="([^"]*)"', m)
    assert len(atributos) == 4  # fechas, resultado, categorías por empresa y por categoría
    assert json.loads(h.unescape(atributos[1]))["datos"][1] == {"nombre": "Escalados", "valor": 1, "color": "peligro"}


def csrf_de(web, ruta="/consola/admin/usuarios"):
    html = web.get(ruta).text
    return html.split('name="csrf" value="')[1].split('"')[0]


def test_admin_solo_para_administracion(servidor):
    _, web = consola(servidor, rol="analista")
    entrar(web)
    assert web.get("/consola/admin/usuarios").status_code == 403
    assert "/consola/admin" not in web.get("/consola").text  # ni aparece en el menú


def test_admin_crea_cuenta_y_audita(servidor):
    api, web = consola(servidor, rol="admin")
    entrar(web)
    for s in ("general", "ia", "playbooks", "equipos", "usuarios", "auditoria"):
        assert web.get(f"/consola/admin/{s}").status_code == 200, s
    datos = {"email": "Luis@Empresa.pe", "nombre": XSS, "rol": "tecnico"}
    assert web.post("/consola/admin/usuarios", data=datos).status_code == 403  # sin token CSRF
    r = web.post("/consola/admin/usuarios", data={**datos, "csrf": csrf_de(web)})
    clave = r.text.split('id="secreto"')[1].split(">")[1].split("<")[0]
    assert XSS not in r.text and db.verificar_clave(api.ruta_db, "luis@empresa.pe", clave)
    r = web.post("/consola/admin/usuarios", data={**datos, "csrf": csrf_de(web)}, follow_redirects=False)
    assert r.headers["location"].endswith("aviso=existe")
    assert "luis@empresa.pe · Asistente N2 (en sitio)" in web.get("/consola/admin/auditoria").text


def test_admin_no_se_quita_a_si_mismo(servidor):
    api, web = consola(servidor, rol="admin")
    entrar(web)
    with db.conexion(api.ruta_db) as c:
        yo = c.execute("SELECT id FROM usuarios_consola").fetchone()["id"]
    r = web.post(f"/consola/admin/usuarios/{yo}/rol", data={"rol": "analista", "csrf": csrf_de(web)}, follow_redirects=False)
    assert r.headers["location"].endswith("aviso=propio")
    db.usuario_consola(api.ruta_db, "beto@empresa.pe", "admin", "clave-larga-456")
    entrar(web, "beto@empresa.pe", "clave-larga-456")
    r = web.post(f"/consola/admin/usuarios/{yo}/rol", data={"rol": "analista", "csrf": csrf_de(web)}, follow_redirects=False)
    assert r.headers["location"].endswith("aviso=rol")
    with db.conexion(api.ruta_db) as c:
        assert c.execute("SELECT rol FROM usuarios_consola WHERE id = %s", (yo,)).fetchone()["rol"] == "analista"
        assert not c.execute("SELECT 1 FROM sesiones WHERE usuario_id = %s", (yo,)).fetchone()  # se cerró su sesión


def test_equipo_revocado_no_habla_con_el_servidor(servidor):
    api, web = consola(servidor, rol="admin")
    assert api.post("/v1/mensaje", json={"texto": "hola", "usuario": "ana", "so": "linux"}).status_code == 200
    entrar(web)
    assert "En línea" in web.get("/consola/admin/equipos").text  # el mensaje dejó su último contacto
    with db.conexion(api.ruta_db) as c:
        eid = c.execute("SELECT id FROM equipos WHERE visto IS NOT NULL").fetchone()["id"]
    web.post(f"/consola/admin/equipos/{eid}/revocar", data={"csrf": csrf_de(web, "/consola/admin/equipos")})
    assert api.post("/v1/mensaje", json={"texto": "hola", "usuario": "ana", "so": "linux"}).status_code == 401
    assert "Revocado" in web.get("/consola/admin/equipos").text
