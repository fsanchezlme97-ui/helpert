"""Genera el logo y los iconos de Helpert.

Orígenes (sin fondo): logo-original.png (la marca «H>_»), logo-texto-original.png (marca + «Helpert») y
mascota-original.png (la ilustración de la mascota).

- icono.png: la marca sobre un cuadro blanco redondeado, para que el azul se lea también en temas oscuros
  (encabezados, favicon, menú de aplicaciones).
- {estado}-{tema}.png: iconos de la bandeja, el icono con un punto del color del estado. El borde del punto es del
  color del panel de cada tema, para que el punto se lea separado del icono.
- logo.png y logo-oscuro.png: el logo con texto para el README; en el oscuro el azul pasa a claro.
- mascota.png: la mascota de cuerpo entero, sin fondo (pantallas de bienvenida).

Colores de estado de la paleta Oxocarbon (los mismos de la interfaz). Requiere ImageMagick 7 (`magick`).

    python3 bandeja/iconos/generar.py   # escribe los .png aquí y copia mascota e icono a la bandeja y la consola
"""
import pathlib
import shutil
import subprocess

AQUI = pathlib.Path(__file__).parent
RAIZ = AQUI.parent.parent
CLARO = "0.902,0.929,0.953"  # #E6EDF3, el texto de GitHub en modo oscuro (canales 0-1 para -fx)
TEMAS = {  # borde del punto (color del panel) y color de cada estado
    "claro": ("#FFFFFF", {"disponible": "#24A148", "pensando": "#0F62FE", "trabajando": "#F1C21B", "aviso": "#DA1E28"}),
    "oscuro": ("#161616", {"disponible": "#42BE65", "pensando": "#78A9FF", "trabajando": "#FFE97B", "aviso": "#EE5396"}),
}


def magick(*args) -> None:
    subprocess.run(["magick", *map(str, args)], check=True)


if __name__ == "__main__":
    magick("-size", "256x256", "xc:none", "-fill", "#FFFFFF", "-draw", "roundrectangle 0,0 255,255 56,56",
           "(", AQUI / "logo-original.png", "-trim", "+repage", "-resize", "184x184", ")",
           "-gravity", "center", "-composite", AQUI / "icono.png")
    for tema, (borde, estados) in TEMAS.items():
        for estado, color in estados.items():
            magick(AQUI / "icono.png", "-resize", "64x64", "-fill", borde, "-draw", "circle 50,50 50,37",
                   "-fill", color, "-draw", "circle 50,50 50,40", AQUI / f"{estado}-{tema}.png")
    magick(AQUI / "logo-texto-original.png", "-trim", "+repage", AQUI / "logo.png")
    # lo oscuro (el azul y los bordes grises del texto chico) pasa a claro; el verde se queda
    magick(AQUI / "logo.png", "-channel", "RGB", "-fx", f"luminance<0.4 ? channel({CLARO}) : u", "+channel",
           AQUI / "logo-oscuro.png")

    sinfondo = AQUI / "_sinfondo.png"
    # el fondo es gris claro liso y la mascota tiene contorno oscuro: se rellena desde las esquinas sin tocar el cuerpo
    magick(AQUI / "mascota-original.png", "-alpha", "set", "-fuzz", "7%", "-fill", "none",
           *[x for p in ("0,0", "1599,0", "0,899", "1599,899") for x in ("-draw", f"color {p} floodfill")], sinfondo)
    magick(sinfondo, "-crop", "450x520+180+200", "+repage", "-trim", "+repage", "-resize", "x384", AQUI / "mascota.png")
    sinfondo.unlink()
    for destino in (RAIZ / "bandeja" / "ui", RAIZ / "server" / "helpert_server" / "estatico"):
        for archivo in ("mascota.png", "icono.png"):
            shutil.copy(AQUI / archivo, destino / archivo)
    print("iconos listos en", AQUI)
