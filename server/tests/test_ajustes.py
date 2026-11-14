"""Lo que se cambia en Administración tiene efecto real en el servidor (interruptores, IA, playbooks, ajustes)."""
import json

from fastapi.testclient import TestClient

from conftest import contrato
from helpert_server import ajustes, db, ia
from test_consola import consola, csrf_de, entrar
from test_flujo import ELIGE_DEMO, enviar, resultado


def admin(servidor):
    api, web = consola(servidor, rol="admin")
    entrar(web)
    return api, web


def interruptor(web, clave, valor):
    return web.post("/consola/admin/general/interruptor",
                    data={"clave": clave, "valor": valor, "csrf": csrf_de(web, "/consola/admin/general")})


def test_pausa_de_emergencia(servidor, falso):
    api, web = admin(servidor)
    interruptor(web, "agentes_pausados", "1")
    r = api.post("/v1/mensaje", json={"texto": "hola", "usuario": "u", "so": "linux"})
    assert r.status_code == 503 and "pausa" in r.json()["detail"]
    interruptor(web, "agentes_pausados", "0")
    falso["a"].append(ELIGE_DEMO)
    assert enviar(api)["trabajo"]["paso"] == "diagnosticar"
    assert "agentes_pausados: false → true" in web.get("/consola/admin/auditoria").text


def test_ia_apagada_ofrece_el_menu(servidor, falso):
    api, web = admin(servidor)
    interruptor(web, "ia_activa", "0")
    r = enviar(api)
    assert r["estado"] == "menu" and not falso["a"]  # ni se llamó al proveedor


def test_playbook_desactivado_corta_casos_en_curso(servidor, falso):
    api, web = admin(servidor)
    falso["a"].append(ELIGE_DEMO)
    r = enviar(api)
    r = resultado(api, r["trabajo"])  # diagnóstico: hay algo que corregir → pide confirmación
    assert r.get("confirmar")
    web.post("/consola/admin/playbooks/demo.archivo/desactivar", data={"csrf": csrf_de(web, "/consola/admin/playbooks")})
    r = api.post("/v1/confirmar", json={"usuario": "ana", "caso_id": r["caso_id"], "acepta": True}).json()
    assert r["estado"] == "escalado" and "trabajo" not in r
    falso["a"].append(ELIGE_DEMO)  # y la IA ya no puede elegirlo
    assert enviar(api)["estado"] == "escalado"


def test_ajustes_validados_y_aplicados(servidor):
    api, web = admin(servidor)
    base = {"umbral_confianza": "0.8", "zona_horaria": "Europe/Madrid", "sesion_horas": "2", "login_intentos": "5",
            **{f"meta_{k}": str(v) for k, v in ajustes.METAS.items()}}
    r = web.post("/consola/admin/general/ajustes", data={**base, "umbral_confianza": "2", "csrf": csrf_de(web, "/consola/admin/general")})
    assert "No se guardó" in r.text
    with db.conexion(api.ruta_db) as c:
        assert not c.execute("SELECT 1 FROM ajustes").fetchone()  # nada a medias
    web.post("/consola/admin/general/ajustes", data={**base, "csrf": csrf_de(web, "/consola/admin/general")})
    with db.conexion(api.ruta_db) as c:
        aj = ajustes.leer(c, {})
        c.execute("INSERT INTO ajustes (clave, valor) VALUES ('sesion_horas', '0') ON CONFLICT (clave) DO UPDATE SET valor = '0'")
        assert ajustes.leer(c, {})["sesion_horas"] == 12  # un valor guardado inválido vuelve al de fábrica
    assert aj["umbral_confianza"] == 0.8 and aj["zona_horaria"] == "Europe/Madrid"


def test_cadena_de_ia_editable_y_segura(servidor, falso):
    api, web = admin(servidor)
    pagina = web.get("/consola/admin/ia").text
    assert 'value="—"' not in pagina  # un campo vacío va vacío, no con el guion de «sin dato»
    v = pagina.split('name="v" value="')[1].split('"')[0]
    nuevo = {"proveedor": "openai-compatible", "modelo": "otro", "url": "https://api.ejemplo.com/v1", "timeout": "30",
             "activo": "1", "tarea_conversar": "1", "v": v}
    r = web.post("/consola/admin/ia/agregar", data={**nuevo, "clave_env": "HELPERT_DB", "sin_evaluar": "1",
                                                     "csrf": csrf_de(web, "/consola/admin/ia")})
    assert "HELPERT_IA_" in r.text  # no puede apuntar la clave a otra variable del servidor
    r = web.post("/consola/admin/ia/agregar", data={**nuevo, "csrf": csrf_de(web, "/consola/admin/ia")})
    assert "evaluación aprobada" in r.text  # un modelo sin evaluar pide confirmación explícita
    web.post("/consola/admin/ia/agregar", data={**nuevo, "sin_evaluar": "1", "csrf": csrf_de(web, "/consola/admin/ia")})
    v = web.get("/consola/admin/ia").text.split('name="v" value="')[1].split('"')[0]
    web.post("/consola/admin/ia/1/quitar", data={"v": v, "csrf": csrf_de(web, "/consola/admin/ia")})  # quita «b»
    v = web.get("/consola/admin/ia").text.split('name="v" value="')[1].split('"')[0]
    web.post("/consola/admin/ia/1/subir", data={"v": v, "csrf": csrf_de(web, "/consola/admin/ia")})  # «otro» pasa primero
    with db.conexion(api.ruta_db) as c:
        cadena = c.execute("SELECT valor FROM ajustes WHERE clave = 'ia'").fetchone()["valor"]
    assert [x["modelo"] for x in cadena] == ["otro", "a"]


def test_inscripcion_con_clave_de_la_consola(servidor):
    api, web = admin(servidor)
    assert api.post("/v1/inscribir", json={"nombre": "pc-9", "clave": "x"}).status_code == 404  # sin clave: no existe
    r = web.post("/consola/admin/inscripcion/clave", data={"csrf": csrf_de(web, "/consola/admin/equipos")})
    clave = r.text.split('id="secreto"')[1].split(">")[1].split("<")[0]
    with db.conexion(api.ruta_db) as c:
        assert clave not in json.dumps(ajustes.leer(c, {})["inscripcion"])  # solo se guarda la huella
    assert api.post("/v1/inscribir", json={"nombre": "pc-9", "clave": "otra"}).status_code == 401
    assert "token" in api.post("/v1/inscribir", json={"nombre": "pc-9", "clave": clave}).json()
    assert api.post("/v1/inscribir", json={"nombre": "pc-9", "clave": clave}).status_code == 409  # nombre repetido
    web.post("/consola/admin/inscripcion/desactivar", data={"csrf": csrf_de(web, "/consola/admin/equipos")})
    assert api.post("/v1/inscribir", json={"nombre": "pc-10", "clave": clave}).status_code == 404


def test_ficha_del_equipo_editable(servidor):
    api, web = admin(servidor)
    with db.conexion(api.ruta_db) as c:
        eid = c.execute("SELECT id FROM equipos").fetchone()["id"]
    web.post(f"/consola/admin/equipos/{eid}/datos", data={"area": "Contabilidad", "sede": "<b>Central</b>", "piso": "3",
                                                          "notas": "", "csrf": csrf_de(web, f"/consola/admin/equipos/{eid}")})
    html = web.get("/consola/admin/equipos").text
    assert "Contabilidad · &lt;b&gt;Central&lt;/b&gt; · piso 3" in html


def test_tokens_y_costo_por_caso(servidor, falso):
    api = servidor(ia_cfg=[{"proveedor": "falso-a", "modelo": "a", "precio_entrada": 2, "precio_salida": 10}])
    falso["a"].append(ia.respuesta(ELIGE_DEMO, 1000, 200))
    cid = enviar(api)["caso_id"]
    with db.conexion(api.ruta_db) as c:
        k = c.execute("SELECT tokens_entrada, tokens_salida, costo_usd FROM casos WHERE id = %s", (cid,)).fetchone()
    assert (k["tokens_entrada"], k["tokens_salida"], float(k["costo_usd"])) == (1000, 200, 0.004)



def test_costo_por_area(servidor, falso):
    api, web = admin(servidor)
    falso["a"].append(ia.respuesta(ELIGE_DEMO, 10, 10))
    enviar(api)
    with db.conexion(api.ruta_db) as c:
        c.execute("UPDATE equipos SET area = 'Contabilidad <b>'")
        c.execute("UPDATE casos SET costo_usd = 0.0125")
    pagina = web.get("/consola/admin/ia").text
    assert "Contabilidad &lt;b&gt;" in pagina and "0.0125" in pagina


def test_categorias_editables(servidor, falso):
    api, web = admin(servidor)
    datos = {"nombre_0": "Impresoras", "ejemplos_0": "tóner, atasco", "nombre_1": "Archivos y carpetas", "ejemplos_1": "",
             "csrf": csrf_de(web, "/consola/admin/categorias")}
    web.post("/consola/admin/categorias", data=datos)
    falso["a"] += [contrato(categoria="Hardware"), contrato(categoria="Hardware")]  # ya no existe: salida inválida
    assert enviar(api)["estado"] == "escalado"
    falso["a"].append(contrato(categoria="Impresoras", playbook={"id": "demo.archivo", "parametros": {"nombre": "x1"}}))
    assert enviar(api)["trabajo"]["paso"] == "diagnosticar"


def test_cerrar_sesiones_de_otra_cuenta(servidor):
    api, web = admin(servidor)
    db.usuario_consola(api.ruta_db, "beto@empresa.pe", "analista", "clave-larga-456")
    otro = TestClient(api.app, base_url="https://helpert.ejemplo.pe")
    entrar(otro, "beto@empresa.pe", "clave-larga-456")
    assert otro.get("/consola").status_code == 200
    with db.conexion(api.ruta_db) as c:
        uid = c.execute("SELECT id FROM usuarios_consola WHERE email = 'beto@empresa.pe'").fetchone()["id"]
    web.post(f"/consola/admin/usuarios/{uid}/sesiones", data={"csrf": csrf_de(web)})
    assert otro.get("/consola", follow_redirects=False).status_code == 303
    assert web.get("/consola").status_code == 200  # la sesión de quien lo hizo sigue


def test_latido_guarda_version_y_sistema(servidor):
    api, web = admin(servidor)
    cab = {"X-Helpert-Version": "0.3.0", "X-Helpert-SO": "linux"}
    assert api.post("/v1/latido", json={}, headers=cab).json() == {"ok": True, "avisos": []}
    assert api.post("/v1/latido", json={}, headers={"X-Helpert-Version": "<script>", "X-Helpert-SO": "dos"}).status_code == 200
    with db.conexion(api.ruta_db) as c:
        q = c.execute("SELECT version, so, visto FROM equipos").fetchone()
        assert (q["version"], q["so"]) == ("0.3.0", "linux") and q["visto"]  # lo inválido no se guarda
        c.execute("UPDATE equipos SET visto = now() - interval '1 hour'")
    assert "Sin señal" in web.get("/consola/admin/equipos").text
    interruptor(web, "agentes_pausados", "1")
    assert api.post("/v1/latido", json={}, headers=cab).status_code == 503
    assert "En línea" in web.get("/consola/admin/equipos").text  # en pausa, pero consta como vivo
