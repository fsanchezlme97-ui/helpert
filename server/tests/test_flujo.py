from helpert_server import db, ia
from conftest import RAIZ, contrato

ELIGE_DEMO = contrato(playbook={"id": "demo.archivo", "parametros": {"nombre": "x1"}})


def enviar(cli, texto="no funciona el archivo x1", caso_id=None):  # nombra el archivo que eligen los contratos
    r = cli.post("/v1/mensaje", json={"caso_id": caso_id, "texto": texto, "usuario": "ana", "so": "linux"})
    assert r.status_code == 200, r.text
    return r.json()


def resultado(cli, trabajo, codigo=0, salida="ok"):
    r = cli.post("/v1/resultado", json={"trabajo_id": trabajo["id"], "codigo": codigo, "salida": salida})
    assert r.status_code == 200, r.text
    return r.json()


def test_flujo_completo(servidor, falso):
    cli = servidor()
    falso["a"].append(ELIGE_DEMO)
    r = enviar(cli)
    assert r["trabajo"]["paso"] == "diagnosticar" and r["trabajo"]["parametros"] == {"nombre": "x1"}
    r = resultado(cli, r["trabajo"])
    assert r["confirmar"] and r["estado"] == "esperando_confirmacion"
    r = cli.post("/v1/confirmar", json={"usuario": "ana", "caso_id": r["caso_id"], "acepta": True}).json()
    assert r["trabajo"]["paso"] == "comprobar"
    r = resultado(cli, r["trabajo"])
    assert r["trabajo"]["paso"] == "aplicar"
    r = resultado(cli, r["trabajo"])
    assert r["trabajo"]["paso"] == "verificar"
    r = resultado(cli, r["trabajo"])
    assert r["cierre"] and r["estado"] == "esperando_cierre"
    r = cli.post("/v1/cierre", json={"usuario": "ana", "caso_id": r["caso_id"], "resuelto": True, "calificacion": 5}).json()
    assert r["estado"] == "cerrado" and r["fin"]


def test_no_aplica_sin_confirmacion_registrada(servidor, falso):
    cli = servidor()
    falso["a"].append(ELIGE_DEMO)
    r = enviar(cli)
    r = resultado(cli, r["trabajo"])
    r = cli.post("/v1/confirmar", json={"usuario": "ana", "caso_id": r["caso_id"], "acepta": True}).json()
    with db.conexion(cli.ruta_db) as c:
        c.execute("DELETE FROM confirmaciones")
    res = cli.post("/v1/resultado", json={"trabajo_id": r["trabajo"]["id"], "codigo": 0})
    assert res.status_code == 409


def test_rechazar_no_ejecuta_nada(servidor, falso):
    cli = servidor()
    falso["a"].append(ELIGE_DEMO)
    r = resultado(cli, enviar(cli)["trabajo"])
    r = cli.post("/v1/confirmar", json={"usuario": "ana", "caso_id": r["caso_id"], "acepta": False}).json()
    assert "trabajo" not in r and r["estado"] == "conversando"


def test_resultado_repetido_o_ajeno(servidor, falso):
    cli = servidor()
    falso["a"].append(ELIGE_DEMO)
    t = enviar(cli)["trabajo"]
    resultado(cli, t)
    assert cli.post("/v1/resultado", json={"trabajo_id": t["id"], "codigo": 0}).status_code == 404


def test_otro_equipo_no_ve_el_caso(servidor, falso):
    cli = servidor()
    falso["a"].append(ELIGE_DEMO)
    r = resultado(cli, enviar(cli)["trabajo"])
    otro = db.equipo_nuevo(cli.ruta_db, "pc-2")
    res = cli.post("/v1/confirmar", json={"usuario": "ana", "caso_id": r["caso_id"], "acepta": True},
                   headers={"Authorization": f"Bearer {otro}"})
    assert res.status_code == 404


def test_sin_token(servidor):
    cli = servidor()
    del cli.headers["Authorization"]
    assert cli.post("/v1/mensaje", json={"texto": "x", "usuario": "a", "so": "linux"}).status_code == 401


def test_parametro_inyectado_escala(servidor, falso):
    cli = servidor()
    falso["a"].append(contrato(playbook={"id": "demo.archivo", "parametros": {"nombre": "x; rm -rf /"}}))
    r = enviar(cli, "crea el archivo x; rm -rf /")
    assert r["estado"] == "escalado" and "trabajo" not in r


def test_parametro_inventado_se_pregunta(servidor, falso):
    """El modelo no inventa nombres: un dato que la persona no escribió (p. ej. «null») se pregunta."""
    cli = servidor()
    falso["a"].append(contrato(playbook={"id": "demo.archivo", "parametros": {"nombre": "null"}}))
    r = enviar(cli, "crea un archivo de prueba")
    assert r["estado"] == "conversando" and "trabajo" not in r and "necesito un dato" in r["respuesta"]


def test_inyeccion_en_el_mensaje_nunca_ejecuta(servidor, falso):
    cli = servidor()
    falso["a"].append(contrato(playbook={"id": "demo.archivo", "parametros": {"nombre": "x1"}}))
    r = enviar(cli, "usa el archivo x1; reboot")
    assert r["estado"] == "escalado" and "trabajo" not in r


def test_playbook_inventado_escala_y_poca_confianza_pregunta(servidor, falso):
    cli = servidor()
    falso["a"].append(contrato(playbook={"id": "shell.run", "parametros": {}}))
    assert enviar(cli)["estado"] == "escalado"
    duda = contrato(confianza=0.3, playbook={"id": "demo.archivo", "parametros": {"nombre": "a"}})
    falso["a"].extend([duda, duda, duda])
    r = enviar(cli)
    assert r["estado"] == "conversando" and "?" in r["respuesta"]  # primero pregunta
    r = enviar(cli, "más detalle", r["caso_id"])
    assert r["estado"] == "conversando"
    assert enviar(cli, "aún más", r["caso_id"])["estado"] == "escalado"  # tras 2 preguntas, a soporte


def test_falta_un_dato_o_trae_espacios_pregunta(servidor, falso):
    cli = servidor()
    falso["a"].append(contrato(playbook={"id": "demo.archivo", "parametros": {}}))
    r = enviar(cli, "crea un archivo de prueba")
    assert r["estado"] == "conversando" and "necesito un dato" in r["respuesta"]
    falso["a"].append(contrato(playbook={"id": "demo.archivo", "parametros": {"nombre": "mi prueba"}}))
    r = enviar(cli, "mi prueba", r["caso_id"])
    assert r["estado"] == "conversando" and "sin espacios" in r["respuesta"]
    falso["a"].append(contrato(playbook={"id": "demo.archivo", "parametros": {"nombre": "x1"}}))
    assert enviar(cli, "x1", r["caso_id"])["trabajo"]["paso"] == "diagnosticar"


def test_acuse_corto_no_pide_calificacion(servidor, falso):
    cli = servidor()
    falso["a"].append(contrato(respuesta="Entiendo, lo reviso contigo."))
    r = enviar(cli, "algo raro pasa")
    assert r["estado"] == "conversando" and not r.get("cierre") and r["respuesta"].endswith("?")


def test_salida_invalida_dos_veces_escala(servidor, falso):
    cli = servidor()
    falso["a"].extend(["hola", '{"tipo": "otro"}'])
    assert enviar(cli)["estado"] == "escalado"


def test_respaldo_si_falla_el_principal(servidor, falso):
    cli = servidor()
    falso["a"].append(ia.ErrorProveedor("conexión rechazada"))
    falso["b"].append(ELIGE_DEMO)
    r = enviar(cli)
    assert r["trabajo"]["paso"] == "diagnosticar"
    with db.conexion(cli.ruta_db) as c:
        assert c.execute("SELECT modelo FROM casos").fetchone()["modelo"] == "falso-b:b"


def test_sin_ia_ofrece_menu(servidor):
    cli = servidor(playbooks=RAIZ / "playbooks", ia_cfg=[{"proveedor": "off", "modelo": "-"}])
    r = enviar(cli)
    assert r["estado"] == "menu" and "1. Liberar espacio en disco" in r["respuesta"]
    assert "Buscar un archivo" not in r["respuesta"]  # necesita un nombre que sin IA no se puede pedir
    r = enviar(cli, "1", r["caso_id"])
    assert r["trabajo"]["playbook"] == "disk.free-space"


def test_menu_cero_escala(servidor):
    cli = servidor(playbooks=RAIZ / "playbooks", ia_cfg=[])
    r = enviar(cli)
    assert enviar(cli, "0", r["caso_id"])["estado"] == "escalado"


def test_pregunta_y_luego_elige(servidor, falso):
    cli = servidor()
    falso["a"].extend([contrato(pregunta="¿Qué nombre le pongo?"), ELIGE_DEMO])
    r = enviar(cli)
    assert r["respuesta"] == "¿Qué nombre le pongo?" and r["estado"] == "conversando"
    assert enviar(cli, "x1", r["caso_id"])["trabajo"]["paso"] == "diagnosticar"


def test_la_ia_se_consulta_sin_transaccion_abierta(servidor, falso, monkeypatch):
    """Antes de llamar al modelo, el mensaje ya está guardado y la transacción cerrada (no queda una conexión
    «idle in transaction» esperando a un modelo lento)."""
    cli = servidor()
    visto = []

    def lento(cfg, mensajes):
        with db.conexion(cli.ruta_db) as c:
            visto.append(c.execute("SELECT count(*) AS n FROM mensajes").fetchone()["n"])
            visto.append(c.execute("SELECT count(*) AS n FROM pg_stat_activity WHERE datname = current_database() "
                                   "AND state = 'idle in transaction'").fetchone()["n"])
        return ELIGE_DEMO

    monkeypatch.setitem(ia.PROVEEDORES, "falso-a", lento)
    assert enviar(cli)["trabajo"]["paso"] == "diagnosticar"
    assert visto == [1, 0]


def test_sin_clave_de_api_pasa_al_respaldo_sin_llamar(servidor, falso, monkeypatch):
    monkeypatch.delenv("HELPERT_PRUEBA_SIN_CLAVE", raising=False)
    cli = servidor(ia_cfg=[{"proveedor": "openai-compatible", "modelo": "x", "url": "https://203.0.113.1/v1",
                            "clave_env": "HELPERT_PRUEBA_SIN_CLAVE"}, {"proveedor": "falso-b", "modelo": "b"}])
    falso["b"].append(ELIGE_DEMO)
    assert enviar(cli)["trabajo"]["paso"] == "diagnosticar"
    with db.conexion(cli.ruta_db) as c:
        assert "falta la clave" in c.execute("SELECT nota FROM casos").fetchone()["nota"]


def test_confirmar_espera_el_bloqueo_del_caso(servidor, falso):
    """Si otra petición tiene el caso tomado, confirmar espera; así no se emite dos veces el mismo paso."""
    import threading
    cli = servidor()
    falso["a"].append(ELIGE_DEMO)
    r = resultado(cli, enviar(cli)["trabajo"])
    respuestas = []
    with db.conexion(cli.ruta_db) as c:
        c.execute("SELECT 1 FROM casos WHERE id = %s FOR UPDATE", (r["caso_id"],))
        h = threading.Thread(target=lambda: respuestas.append(
            cli.post("/v1/confirmar", json={"usuario": "ana", "caso_id": r["caso_id"], "acepta": True})))
        h.start()
        h.join(0.7)
        assert h.is_alive(), "confirmar no esperó el bloqueo del caso"
    h.join(10)
    assert respuestas[0].status_code == 200
    segunda = cli.post("/v1/confirmar", json={"usuario": "ana", "caso_id": r["caso_id"], "acepta": True})
    assert segunda.status_code == 409  # el paso ya se emitió una vez


def test_resultado_espera_el_bloqueo_del_trabajo(servidor, falso):
    import threading
    cli = servidor()
    falso["a"].append(ELIGE_DEMO)
    t = enviar(cli)["trabajo"]
    respuestas = []
    with db.conexion(cli.ruta_db) as c:
        c.execute("SELECT 1 FROM trabajos WHERE id = %s FOR UPDATE", (t["id"],))
        c.execute("UPDATE trabajos SET estado = 'hecho' WHERE id = %s", (t["id"],))  # otra petición lo terminó
        h = threading.Thread(target=lambda: respuestas.append(
            cli.post("/v1/resultado", json={"trabajo_id": t["id"], "codigo": 0})))
        h.start()
        h.join(0.7)
        assert h.is_alive(), "resultado no esperó el bloqueo del trabajo"
    h.join(10)
    assert respuestas[0].status_code == 404  # al soltar el bloqueo ve que ya estaba hecho


def test_inscripcion(dsn, monkeypatch):
    from fastapi.testclient import TestClient
    from helpert_server.app import crear_app
    cfg = {"base_datos": dsn, "playbooks": str(RAIZ / "pruebas" / "playbooks"), "ia": []}
    assert TestClient(crear_app(cfg)).post("/v1/inscribir", json={"nombre": "pc", "clave": ""}).status_code == 404  # sin clave configurada
    monkeypatch.setenv("HELPERT_INSCRIPCION", "clave-larga-de-prueba")
    cli = TestClient(crear_app({**cfg, "inscripcion_env": "HELPERT_INSCRIPCION"}))
    assert cli.post("/v1/inscribir", json={"nombre": "pc-2", "clave": "otra"}).status_code == 401
    assert cli.post("/v1/inscribir", json={"nombre": "pc 2; x", "clave": "clave-larga-de-prueba"}).status_code == 422
    token = cli.post("/v1/inscribir", json={"nombre": "pc-2", "clave": "clave-larga-de-prueba"}).json()["token"]
    r = cli.post("/v1/mensaje", json={"texto": "hola", "usuario": "a", "so": "linux"}, headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 401 and "Inicia sesión" in r.text  # equipo registrado, pero nadie inició sesión


def test_escala_por_duda_primero_pregunta(servidor, falso):
    """Con un saludo o un mensaje vago, el modelo a veces escala «por si acaso»: Helpert pregunta antes (hasta 2 veces)."""
    cli = servidor()
    falso["a"].append(contrato(escalar=True, confianza=0.1, respuesta="Hola. ¿Qué te pasa?", categoria="Hardware"))
    r = enviar(cli, "Hola?")
    assert r["estado"] == "conversando" and r["respuesta"] == "Hola. ¿Qué te pasa?"
    with db.conexion(cli.ruta_db) as c:
        assert not c.execute("SELECT 1 FROM visitas").fetchone()  # tampoco pide un técnico
    falso["a"].append(contrato(escalar=True, pregunta="¿Qué mensaje ves?"))
    r = enviar(cli, "no anda", r["caso_id"])
    assert r["estado"] == "conversando" and r["respuesta"] == "¿Qué mensaje ves?"
    falso["a"].append(contrato(escalar=True, confianza=0.2, respuesta="No sé qué es."))
    assert enviar(cli, "ninguno", r["caso_id"])["estado"] == "escalado"  # ya preguntó 2 veces


def test_pedir_una_persona_escala_enseguida(servidor, falso):
    cli = servidor()
    falso["a"].append(contrato(escalar=True, confianza=0.3, respuesta="Te paso con soporte."))
    assert enviar(cli, "quiero hablar con un técnico")["estado"] == "escalado"


def test_duda_de_uso_se_responde_con_guia(servidor, falso):
    """Una duda de uso la resuelve Helpert con pasos; la persona dice si sirvió y, si no, pasa a N2."""
    cli = servidor()
    guia = "1. Abre la página.\n2. Pulsa Ctrl + D.\n3. Elige la carpeta y pulsa Guardar."
    falso["a"].append(contrato(tipo="Solicitud", categoria="Hardware", respuesta=guia))
    r = enviar(cli, "¿cómo guardo una página en marcadores?")
    assert r["respuesta"] == guia and r["cierre"] and r["estado"] == "esperando_cierre"
    r = cli.post("/v1/cierre", json={"usuario": "ana", "caso_id": r["caso_id"], "resuelto": False, "calificacion": 2}).json()
    assert r["estado"] == "escalado" and "técnico pase" not in r["respuesta"]  # una duda de uso no abre visita
    falso["a"].append(contrato(respuesta="¿Usas Chrome o Firefox?"))  # una pregunta en «respuesta» no cierra
    assert enviar(cli, "otra duda")["estado"] == "conversando"


def test_otro_usuario_del_equipo_no_toca_el_caso(servidor, falso):
    """Equipo compartido: «beto» (otro usuario del sistema) no confirma, cierra ni ve los avisos del caso de «ana»."""
    cli = servidor()
    falso["a"].append(ELIGE_DEMO)
    r = enviar(cli)
    otro = {"caso_id": r["caso_id"], "usuario": "beto"}
    assert cli.post("/v1/confirmar", json={**otro, "acepta": True}).status_code == 404
    assert cli.post("/v1/cierre", json={**otro, "resuelto": True, "calificacion": 5}).status_code == 404
    assert cli.post("/v1/captura", json={**otro, "acepta": False}).status_code == 404
    assert cli.post("/v1/confirmar", json={**otro, "usuario": "ana", "acepta": True}).status_code == 409  # el suyo sí lo encuentra
