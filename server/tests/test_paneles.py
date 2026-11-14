"""Vistas por rol de la consola: a dónde llega cada uno, la cola de escalados, «Mi día» del técnico, el resumen de la
empresa y las páginas de error."""
from fastapi.testclient import TestClient

from conftest import contrato
from helpert_server import db
from test_ajustes import admin
from test_consola import consola, entrar
from test_flujo import enviar
from test_multiempresa import empresa_b


def cuenta(api, email, rol, empresa_id=None):
    db.usuario_consola(api.ruta_db, email, rol, "clave-larga-555", None, empresa_id)
    web = TestClient(api.app, base_url="https://helpert.ejemplo.pe")
    return web, entrar(web, email, "clave-larga-555")


def empresa_a(api):
    with db.conexion(api.ruta_db) as c:
        return c.execute("SELECT id FROM empresas WHERE nombre = 'Mi organización'").fetchone()["id"]


def test_cada_rol_llega_a_su_trabajo(servidor):
    api, _ = consola(servidor)
    destinos = {"tecnico": "/consola/visitas", "gerencia": "/consola/metricas", "analista": "/consola", "admin": "/consola"}
    for rol, destino in destinos.items():
        _, r = cuenta(api, f"{rol}@empresa.pe", rol)
        assert r.status_code == 303 and r.headers["location"] == destino, rol
    tec, _ = cuenta(api, "tecnico@empresa.pe", "tecnico")
    assert tec.get("/consola").status_code == 200  # el técnico sigue viendo Casos para tomar los N2


def test_cola_de_escalados_por_plazo_y_solo_de_su_empresa(servidor, falso):
    api, web = admin(servidor)
    b = empresa_b(api, falso)
    falso["a"].extend([contrato(escalar=True)] * 3)
    viejo = enviar(api, "primero")["caso_id"]
    with db.conexion(api.ruta_db) as c:  # cerrado: no está en la cola
        c.execute("UPDATE casos SET estado = 'cerrado' WHERE id = %s", (viejo,))
    nuevo = enviar(api, "segundo")["caso_id"]
    viejo2 = enviar(api, "tercero")["caso_id"]
    with db.conexion(api.ruta_db) as c:
        c.execute("UPDATE casos SET nivel = 3, escalado = now() - interval '3 days' WHERE id = %s", (viejo2,))  # N3 vencido: va primero
        c.execute("UPDATE casos SET escalado = now() - interval '5 minutes' WHERE id = %s", (nuevo,))
    jefe, _ = cuenta(api, "jefe@alfa.pe", "admin_empresa", empresa_a(api))
    cola = jefe.get("/consola").text.split("Cola de escalados")[1].split("</section>")[0]
    assert cola.index(f"Caso #{viejo2}") < cola.index(f"Caso #{nuevo}")
    assert "Vencido hace 2 d" in cola and f"Caso #{b['caso']}<" not in cola  # nada de la empresa B
    assert f"Caso #{b['caso']}" in web.get("/consola").text  # la plataforma sí la ve


def test_mi_dia_del_tecnico(servidor, falso):
    api, web = admin(servidor)
    b = empresa_b(api, falso)
    emp_a = empresa_a(api)
    with db.conexion(api.ruta_db) as c:  # misma sede en dos empresas, con direcciones distintas
        c.execute("INSERT INTO sedes (empresa_id, nombre, direccion) VALUES (%s, 'Central', 'Av. Alfa 100'), "
                  "(%s, 'Central', 'Jr. Beta 200')", (emp_a, b["empresa"]))
        c.execute("UPDATE personas SET sede = 'Central', telefono = '+51 999 111 222' WHERE email = 'ana@empresa.pe'")
        c.execute("UPDATE equipos SET so = 'windows' WHERE nombre = 'pc-1'")
    falso["a"].append(contrato(escalar=True, categoria="Hardware", respuesta="Hay que revisarlo."))
    cid = enviar(api, "la impresora no prende")["caso_id"]
    tec, _ = cuenta(api, "tec@alfa.pe", "tecnico", emp_a)
    pagina = tec.get("/consola/visitas").text
    assert "No tienes visitas asignadas" in pagina and f"Caso #{cid}" in pagina  # su caso N2 espera en la cola
    assert 'title="Tus visitas por atender"' not in pagina  # la visita por asignar no cuenta para el técnico
    with db.conexion(api.ruta_db) as c:
        tid = c.execute("SELECT id FROM usuarios_consola WHERE email = 'tec@alfa.pe'").fetchone()["id"]
        vid = c.execute("SELECT id FROM visitas WHERE caso_id = %s", (cid,)).fetchone()["id"]
    t = web.get("/consola/visitas").text.split('name="csrf" value="')[1].split('"')[0]
    web.post(f"/consola/visitas/{vid}/asignar", data={"tecnico": tid, "minutos": "30", "prioridad": "alta", "csrf": t})
    pagina = tec.get("/consola/visitas").text
    assert "Av. Alfa 100" in pagina and "Jr. Beta 200" not in pagina
    assert 'href="tel:+51999111222"' in pagina and "pc-1 (Windows)" in pagina and "la impresora no prende" in pagina
    assert 'title="Tus visitas por atender"' in pagina and "Cerrar la visita" in pagina
    cola = pagina.split("Casos N2 que esperan")[1].split("</section>")[0]
    assert f"Caso #{cid}" not in cola and "Ningún caso N2 espera" in cola  # ya es su visita: no se repite en la cola


def test_resumen_de_mi_empresa(servidor, falso):
    api, _ = admin(servidor)
    empresa_b(api, falso)  # su caso escalado y su equipo no cuentan para A
    emp_a = empresa_a(api)
    with db.conexion(api.ruta_db) as c:
        c.execute("UPDATE equipos SET so = 'linux', version = '0.9.0', visto = now() WHERE nombre = 'pc-1'")
        c.execute("UPDATE equipos SET so = 'windows', version = '0.9.0', visto = now() - interval '2 hours' WHERE nombre = 'pc-b'")
    jefe, _ = cuenta(api, "jefe@alfa.pe", "admin_empresa", emp_a)
    pagina = jefe.get("/consola/admin/empresas").text
    equipos = pagina.split("Equipos en línea")[1][:1500]
    assert "1 / 1" in equipos and "Ninguno sin señal" in equipos and "1 Linux" in equipos and "Windows" not in equipos
    assert "Escalados abiertos" in pagina and 'href="#personas"' in pagina and 'id="personas"' in pagina


def test_general_muestra_agentes_por_sistema(servidor):
    api, web = admin(servidor)
    with db.conexion(api.ruta_db) as c:
        c.execute("UPDATE equipos SET so = 'windows', version = '0.9.1', visto = now() WHERE nombre = 'pc-1'")
    pagina = web.get("/consola/admin/general").text
    assert "Agentes por sistema y versión" in pagina and "Windows" in pagina and "0.9.1" in pagina
    assert "Cadena de IA" in pagina and "Ninguna empresa con fondo bajo" in pagina


def test_errores_de_la_consola_en_html_y_api_en_json(servidor):
    api, web = consola(servidor)
    entrar(web)
    for ruta, codigo in (("/consola/caso/9999", 404), ("/consola/caso/abc", 422), ("/consola/no-existe", 404)):
        r = web.get(ruta)
        assert r.status_code == codigo and r.headers["content-type"].startswith("text/html"), ruta
        assert "Volver a la consola" in r.text and r.headers["content-security-policy"]
    assert web.get("/consola/admin/usuarios").status_code == 403  # sigue siendo 403, ahora como página
    sin = TestClient(api.app, base_url="https://helpert.ejemplo.pe")
    r = sin.get("/consola", follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/consola/login"
    r = TestClient(api.app).post("/v1/latido", json={}, headers={"Authorization": "Bearer malo"})
    assert r.status_code == 401 and r.headers["content-type"].startswith("application/json")
