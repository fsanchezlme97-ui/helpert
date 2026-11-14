"""Claves de API cifradas, reglas por área y modelo por tarea (segunda opinión)."""
import json

from cryptography.fernet import Fernet

from conftest import contrato
from helpert_server import ajustes, db, ia
from test_ajustes import admin
from test_consola import csrf_de
from test_flujo import ELIGE_DEMO, enviar


def poner(api, clave, valor):
    """Guarda un ajuste tal cual (la API lo valida al leerlo, con los proveedores falsos del cfg de pruebas)."""
    with db.conexion(api.ruta_db) as c:
        c.execute("INSERT INTO ajustes (clave, valor) VALUES (%s, %s) ON CONFLICT (clave) DO UPDATE SET valor = excluded.valor",
                  (clave, json.dumps(valor)))


def area(api, nombre):
    with db.conexion(api.ruta_db) as c:
        c.execute("UPDATE equipos SET area = %s", (nombre,))


def test_clave_de_api_cifrada(servidor, monkeypatch):
    monkeypatch.setenv(ajustes.MAESTRA_ENV, Fernet.generate_key().decode())
    api, web = admin(servidor)
    v = web.get("/consola/admin/ia").text.split('name="v" value="')[1].split('"')[0]
    datos = {"proveedor": "openai-compatible", "modelo": "nube", "url": "https://api.ejemplo.com/v1", "timeout": "30",
             "activo": "1", "tarea_conversar": "1", "sin_evaluar": "1", "clave": "sk-secreta-9876", "v": v}
    web.post("/consola/admin/ia/agregar", data={**datos, "csrf": csrf_de(web, "/consola/admin/ia")})
    with db.conexion(api.ruta_db) as c:
        crudo = json.dumps([dict(f) for f in c.execute("SELECT * FROM ajustes")], default=str)
        auditoria = json.dumps([dict(f) for f in c.execute("SELECT * FROM auditoria")], default=str)
        prov = c.execute("SELECT valor FROM ajustes WHERE clave = 'ia'").fetchone()["valor"][-1]
    assert "sk-secreta" not in crudo and "sk-secreta" not in auditoria  # ni en la base ni en la auditoría
    assert prov["clave_pista"] == "9876" and ajustes.descifrar(prov["clave_cifrada"]) == "sk-secreta-9876"
    pagina = web.get("/consola/admin/ia").text
    assert "sk-secreta" not in pagina and "··9876" in pagina

    llamadas = []
    monkeypatch.setattr(ia, "_post", lambda url, cuerpo, cab, t: llamadas.append(cab) or
                        {"choices": [{"message": {"content": "ok"}}]})
    ia.llamar_openai(prov, [{"role": "user", "content": "ok"}])
    assert llamadas[-1]["Authorization"] == "Bearer sk-secreta-9876"

    # guardar sin escribirla la conserva; subir la conserva; «borrar» la quita
    v = web.get("/consola/admin/ia").text.split('name="v" value="')[1].split('"')[0]
    web.post("/consola/admin/ia/2/guardar", data={**datos, "clave": "", "v": v, "csrf": csrf_de(web, "/consola/admin/ia")})
    v = web.get("/consola/admin/ia").text.split('name="v" value="')[1].split('"')[0]
    web.post("/consola/admin/ia/2/subir", data={"v": v, "csrf": csrf_de(web, "/consola/admin/ia")})
    with db.conexion(api.ruta_db) as c:
        assert c.execute("SELECT valor FROM ajustes WHERE clave = 'ia'").fetchone()["valor"][1].get("clave_cifrada")
    v = web.get("/consola/admin/ia").text.split('name="v" value="')[1].split('"')[0]
    r = web.post("/consola/admin/ia/1/guardar", data={**datos, "url": "https://otro.ejemplo.com/v1", "clave": "", "v": v,
                                                      "csrf": csrf_de(web, "/consola/admin/ia")})
    assert "vuelve a escribir la clave" in r.text  # la clave guardada no se va sola a otro servidor
    web.post("/consola/admin/ia/1/guardar", data={**datos, "clave": "", "borrar_clave": "1", "v": v,
                                                  "csrf": csrf_de(web, "/consola/admin/ia")})
    with db.conexion(api.ruta_db) as c:
        assert not c.execute("SELECT valor FROM ajustes WHERE clave = 'ia'").fetchone()["valor"][1].get("clave_cifrada")

    # sin la clave maestra correcta, el proveedor falla como una clave que falta (pasa al respaldo), sin error 500
    monkeypatch.setenv(ajustes.MAESTRA_ENV, Fernet.generate_key().decode())
    try:
        ia.llamar_openai(prov, [])
        assert False
    except ia.ErrorProveedor as err:
        assert "falta la clave" in str(err)


def test_area_solo_local_nunca_usa_la_nube(servidor, falso):
    api, web = admin(servidor)
    area(api, "RR. HH.")
    web.post("/consola/admin/privacidad/reglas", data={"area_0": "rrhh", "local_0": "1", "cap_0": "1",
                                                        "csrf": csrf_de(web, "/consola/admin/privacidad")})
    r = enviar(api)  # a y b no son locales: menú sin IA, ningún proveedor llamado
    assert r["estado"] == "menu" and not falso["a"] and not falso["b"]
    poner(api, "ia", [{"proveedor": "falso-a", "modelo": "a", "local": True}, {"proveedor": "falso-b", "modelo": "b"}])
    falso["a"].append(ELIGE_DEMO)
    assert enviar(api)["trabajo"]["paso"] == "diagnosticar"
    falso["a"].append(ia.ErrorProveedor("caído"))  # el local falla: no se pasa a la nube
    assert enviar(api)["estado"] == "menu"
    assert "1 equipo" in web.get("/consola/admin/privacidad").text  # la regla dice a cuántos equipos protege


def test_area_con_playbooks_bloqueados(servidor, falso):
    api, _ = admin(servidor)
    area(api, "Contabilidad")
    poner(api, "reglas_area", [{"area": "Contabilidad", "playbooks_bloqueados": ["demo.archivo"]}])
    vistos = []
    original = ia.PROVEEDORES["falso-a"]
    ia.PROVEEDORES["falso-a"] = lambda cfg, m: vistos.append(m[0]["content"]) or original(cfg, m)
    falso["a"].append(ELIGE_DEMO)
    r = enviar(api)
    assert r["estado"] == "escalado" and "demo.archivo" not in vistos[0]  # ni se ofrece ni se acepta


def test_segunda_opinion_solo_cuando_duda(servidor, falso):
    api, _ = admin(servidor)
    poner(api, "ia", [{"proveedor": "falso-a", "modelo": "a"}, {"proveedor": "falso-b", "modelo": "b", "tareas": ["complejo"]}])
    duda = json.loads(ELIGE_DEMO) | {"confianza": 0.4}
    falso["a"].append(json.dumps(duda))
    falso["b"].append(ia.respuesta(ELIGE_DEMO, 100, 20))
    r = enviar(api)
    assert r["trabajo"]["paso"] == "diagnosticar"
    with db.conexion(api.ruta_db) as c:
        k = c.execute("SELECT modelo, nota, tokens_entrada FROM casos WHERE id = %s", (r["caso_id"],)).fetchone()
    assert k["modelo"] == "falso-b:b" and "segunda opinión" in k["nota"] and k["tokens_entrada"] == 100
    falso["a"].append(contrato(escalar=True, confianza=0.9))  # pidió escalar: no se consulta a «b» (su cola está vacía)
    assert enviar(api)["estado"] == "escalado"
