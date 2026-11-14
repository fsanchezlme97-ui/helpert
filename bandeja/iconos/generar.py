"""Genera el logo y los iconos de Helpert a partir de la ilustración de la mascota (mascota-original.png).

- mascota.png: la mascota de cuerpo entero, sin fondo (pantallas de bienvenida).
- icono.png: solo la cabeza, cuadrada, para tamaños chicos (encabezados, favicon, menú de aplicaciones).
- {estado}-{tema}.png: iconos de la bandeja, la cabeza con un punto del color del estado. El borde del punto es del
  color del panel de cada tema, para que el punto se lea separado de la cabeza.

Colores de estado de la paleta Oxocarbon (los mismos de la interfaz). Requiere ImageMagick 7 (`magick`).

    python3 bandeja/iconos/generar.py   # escribe los .png aquí y copia mascota e icono a la bandeja y la consola
"""
import pathlib
import shutil
import subprocess

AQUI = pathlib.Path(__file__).parent
RAIZ = AQUI.parent.parent
ORIGEN = AQUI / "mascota-original.png"
TEMAS = {  # borde del punto (color del panel) y color de cada estado
    "claro": ("#FFFFFF", {"disponible": "#24A148", "pensando": "#0F62FE", "trabajando": "#F1C21B", "aviso": "#DA1E28"}),
    "oscuro": ("#161616", {"disponible": "#42BE65", "pensando": "#78A9FF", "trabajando": "#FFE97B", "aviso": "#EE5396"}),
}


def magick(*args) -> None:
    subprocess.run(["magick", *map(str, args)], check=True)


if __name__ == "__main__":
    sinfondo = AQUI / "_sinfondo.png"
    # el fondo es gris claro liso y la mascota tiene contorno oscuro: se rellena desde las esquinas sin tocar el cuerpo
    magick(ORIGEN, "-alpha", "set", "-fuzz", "7%", "-fill", "none",
           *[x for p in ("0,0", "1599,0", "0,899", "1599,899") for x in ("-draw", f"color {p} floodfill")], sinfondo)
    magick(sinfondo, "-crop", "450x520+180+200", "+repage", "-trim", "+repage", "-resize", "x384", AQUI / "mascota.png")
    magick(AQUI / "mascota.png", "-crop", "275x204+44+0", "+repage", "-trim", "+repage",  # la cabeza, sin la mano
           "-background", "none", "-gravity", "center", "-extent", "%[fx:max(w,h)]x%[fx:max(w,h)]", "-resize", "256x256",
           AQUI / "icono.png")
    sinfondo.unlink()
    for tema, (borde, estados) in TEMAS.items():
        for estado, color in estados.items():
            magick(AQUI / "icono.png", "-resize", "64x64", "-fill", borde, "-draw", "circle 50,50 50,37",
                   "-fill", color, "-draw", "circle 50,50 50,40", AQUI / f"{estado}-{tema}.png")
    for destino in (RAIZ / "bandeja" / "ui", RAIZ / "server" / "helpert_server" / "estatico"):
        for archivo in ("mascota.png", "icono.png"):
            shutil.copy(AQUI / archivo, destino / archivo)
    print("iconos listos en", AQUI)
