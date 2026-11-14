"""Guía en pantalla: análisis de la pantalla, marcas numeradas y el siguiente paso, con modelos falsos."""
import base64
import io
import json

from PIL import Image

from conftest import contrato
from helpert_server import db, pantalla
from test_areas_y_claves import poner
from test_flujo import enviar

GUIA = "1. Abre Configuración.\n2. Entra en Pantalla.\n3. Elige el fondo."


def png(ancho=1000, alto=500):
    buf = io.BytesIO()
    Image.new("RGB", (ancho, alto), (240, 240, 240)).save(buf, "PNG")
    return base64.b64encode(buf.getvalue()).decode()


def elementos(*etiquetas):
    return json.dumps({"elementos": [{"etiqueta": e, "caja": [100 * i, 100, 100 * i + 80, 300]} for i, e in enumerate(etiquetas, 1)]})


def paso(marca=1, accion="clic", instruccion="Haz clic en Configuración.", **k):
    return json.dumps({"marca": marca, "accion": accion, "instruccion": instruccion, "terminado": False, "escalar": False, **k})


def preparar(servidor, capturas=True):
    api = servidor()
    poner(api, "capturas", {"activas": capturas, "dias": 90, "ia_externa": False})
    poner(api, "ia", [{"proveedor": "falso-a", "modelo": "a"},
                      {"proveedor": "falso-b", "modelo": "b", "tareas": ["vision"], "local": True}])
    return api


def guia(api, falso):
    falso["a"].append(contrato(accion="guia", respuesta=GUIA, tipo="Solicitud"))
    r = enviar(api, "¿cómo cambio el fondo de pantalla?")
    assert r["cierre"]
    return r


def con_guia(servidor, falso, capturas=True):
    api = preparar(servidor, capturas)
    return api, guia(api, falso)


def pedir(api, caso_id, usuario="ana", hecho="inicio", imagen=None):
    return api.post("/v1/pantalla", json={"caso_id": caso_id, "usuario": usuario, "hecho": hecho, "imagen": imagen or png()})


def test_guia_paso_a_paso_con_marcas(servidor, falso):
    api, r = con_guia(servidor, falso)
    assert r["pantalla"]  # la bandeja ofrece «Guíame en pantalla»
    falso["b"] += [elementos("Inicio", "Configuración"), paso(marca=2)]
    p = pedir(api, r["caso_id"]).json()["paso"]
    # caja 0-1000 [ymin, xmin, ymax, xmax] = [200, 100, 280, 300] → píxeles de una captura de 1000 × 500
    assert p["caja"] == [100, 100, 300, 140] and p["etiqueta"] == "Configuración" and p["accion"] == "clic" and p["n"] == 1
    falso["b"] += [elementos("Pantalla"), paso(marca=0, accion="clic", instruccion="Listo, ya cambiaste el fondo.", terminado=True)]
    p = pedir(api, r["caso_id"], hecho="helpert").json()["paso"]
    assert p["terminado"] and p["accion"] == "ninguna" and p["caja"] is None  # sin marca no hay dónde hacer clic
    with db.conexion(api.ruta_db) as c:
        log = [m["texto"] for m in c.execute("SELECT texto FROM mensajes WHERE rol = 'pantalla' ORDER BY id")]
    assert log[0] == "Paso 1: Haz clic en Configuración. [clic en «Configuración»]" and log[1].startswith("Paso 2: Listo")
    # el caso sigue esperando que la persona diga si se resolvió
    assert api.post("/v1/cierre", json={"usuario": "ana", "caso_id": r["caso_id"], "resuelto": True,
                                       "calificacion": 5}).json()["estado"] == "cerrado"


def test_marca_inventada_o_datos_privados_escalan(servidor, falso):
    api, r = con_guia(servidor, falso)
    falso["b"] += [elementos("Aceptar"), paso(marca=7)]
    assert pedir(api, r["caso_id"]).json()["estado"] == "escalado"
    r = guia(api, falso)  # caso nuevo (el escalado no queda pendiente de calificar)
    # la pantalla (una página falsa) logra que el modelo pida la contraseña: no se muestra como paso de Helpert
    falso["b"] += [elementos("Usuario", "Contraseña"), paso(marca=2, instruccion="Escribe tu contraseña del banco aquí.")]
    r2 = pedir(api, r["caso_id"]).json()
    assert r2["estado"] == "escalado" and "contraseña" not in r2["respuesta"]


def test_solo_con_capturas_y_en_su_caso(servidor, falso):
    api, r = con_guia(servidor, falso, capturas=False)
    assert not r["pantalla"]
    assert pedir(api, r["caso_id"]).status_code == 409
    poner(api, "capturas", {"activas": True, "dias": 90, "ia_externa": False})
    assert pedir(api, r["caso_id"], usuario="beto").status_code == 404  # otro usuario del equipo
    assert pedir(api, r["caso_id"], imagen=base64.b64encode(b"<svg/>").decode()).status_code == 422
    falso["b"] += ["no es json", "tampoco"]  # el modelo no responde con el formato: sigue con la guía escrita
    assert "error" in pedir(api, r["caso_id"]).json()


def test_marcas_numeradas():
    img = Image.new("RGB", (400, 200), (255, 255, 255))
    out = pantalla.marcar(img, [[10, 40, 100, 80], [200, 100, 300, 150]])
    assert out.getpixel((10, 60)) == (255, 0, 110) and img.getpixel((10, 60)) == (255, 255, 255)  # dibuja en una copia
    assert pantalla.a_pixeles([0, 0, 1000, 1000], 1920, 1080) == [0, 0, 1920, 1080]
    assert pantalla.a_pixeles([500, 500, 501, 501], 1920, 1080) is None  # caja de nada
