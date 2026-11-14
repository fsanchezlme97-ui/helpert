"""Genera el logo y los iconos de Helpert a partir de logo-original.png (la marca «H>_») y logo-texto-original.png
(marca + «Helpert»), los dos sin fondo.

- marca.png / marca-oscuro.png: la marca para tamaños grandes (bienvenida); en la oscura el azul pasa a claro.
- marca-chica.png / marca-chica-oscuro.png: la misma marca con el trazo más grueso, para 40 px o menos (encabezados,
  avatar del chat). Con el trazo original, a ese tamaño el contorno de la H se pierde.
- {estado}-{tema}.png: iconos de la bandeja (app indicator), la marca chica del tema del panel con un punto del color del
  estado arriba a la derecha, donde no tapa nada. El borde del punto es del color del panel.
- icono.png: la marca chica sobre un cuadro blanco redondeado (favicon).
- app/helpert-{n}.png: ese mismo icono dibujado en cada tamaño del tema (16 a 256 px), el que usan el menú de
  aplicaciones y las barras de tareas. Reducir el de 256 a 16 lo dejaba borroso.
- icono.ico: esos mismos tamaños en un .ico, para el ejecutable de Windows.
- logo.png / logo-oscuro.png: el logo con texto, para el README.

Colores de estado de la paleta Oxocarbon (los mismos de la interfaz). Requiere ImageMagick 7 (`magick`).

    python3 bandeja/iconos/generar.py   # escribe los .png aquí y copia las marcas e icono a la bandeja y la consola
"""
import pathlib
import shutil
import subprocess

AQUI = pathlib.Path(__file__).parent
RAIZ = AQUI.parent.parent
CLARO = "0.902,0.929,0.953"  # #E6EDF3, el texto de GitHub en modo oscuro (canales 0-1 para -fx)
OSCURECER = ["-channel", "RGB", "-fx", f"luminance<0.4 ? channel({CLARO}) : u", "+channel"]  # azul → claro; el verde queda
COLORES = {"claro": ("#233B50", "#629891"), "oscuro": ("#E6EDF3", "#7CC4B9")}  # azul y verde de la marca chica
TEMAS = {  # borde del punto (color del panel) y color de cada estado
    "claro": ("#FFFFFF", {"disponible": "#24A148", "pensando": "#0F62FE", "trabajando": "#F1C21B", "aviso": "#DA1E28"}),
    "oscuro": ("#161616", {"disponible": "#42BE65", "pensando": "#78A9FF", "trabajando": "#FFE97B", "aviso": "#EE5396"}),
}
COPIAS = ("icono.png", "marca.png", "marca-oscuro.png", "marca-chica.png", "marca-chica-oscuro.png")


def magick(*args) -> None:
    *resto, salida = map(str, args)  # PNG32: RGBA siempre, sin paleta (algunos visores tratan mal el alfa de 1 bit)
    # sin fecha en el PNG: regenerar no cambia los archivos si el dibujo es el mismo
    subprocess.run(["magick", *resto, "-define", "png:exclude-chunks=date,time", f"PNG32:{salida}"], check=True)


def capa(mascara: list, color: str, ancho: int, alto: int) -> list:
    """El color con la máscara (blanco = visible) como transparencia, entre paréntesis para componerla."""
    return ["(", "-size", f"{ancho}x{alto}", f"xc:{color}", "(", *mascara, ")", "-alpha", "off",
            "-compose", "CopyOpacity", "-composite", ")"]


if __name__ == "__main__":
    marca = AQUI / "marca.png"
    magick(AQUI / "logo-original.png", "-trim", "+repage", marca)
    magick(marca, *OSCURECER, AQUI / "marca-oscuro.png")
    ancho, alto = (int(v) for v in subprocess.run(["magick", "identify", "-format", "%w %h", marca],
                                                  capture_output=True, text=True, check=True).stdout.split())
    # máscaras: el azul (la H, con su contorno engrosado hasta cerrarse) y el verde (el «>_» y la L, algo más gruesos)
    azul = [marca, "-fx", "a>0.35 && luminance<0.4 ? 1 : 0", "-alpha", "off", "-morphology", "Dilate", "Disk:5"]
    verde = [marca, "-fx", "a>0.35 && luminance>=0.4 ? 1 : 0", "-alpha", "off", "-morphology", "Dilate", "Disk:3"]
    for tema, (c_azul, c_verde) in COLORES.items():
        chica = AQUI / ("marca-chica.png" if tema == "claro" else "marca-chica-oscuro.png")
        magick(*capa(azul, c_azul, ancho, alto), *capa(verde, c_verde, ancho, alto), "-compose", "Over", "-composite", chica)
        borde, estados = TEMAS[tema]
        for estado, color in estados.items():
            magick("-size", "64x64", "xc:none", "(", chica, "-resize", "62x62", ")", "-gravity", "center", "-composite",
                   "-gravity", "NorthWest", "-fill", borde, "-draw", "circle 53,11 53,0",
                   "-fill", color, "-draw", "circle 53,11 53,3", AQUI / f"{estado}-{tema}.png")
    magick("-size", "256x256", "xc:none", "-fill", "#FFFFFF", "-draw", "roundrectangle 0,0 255,255 56,56",
           "(", AQUI / "marca-chica.png", "-resize", "196x196", ")", "-gravity", "center", "-composite", AQUI / "icono.png")
    (AQUI / "app").mkdir(exist_ok=True)
    for n in (16, 22, 24, 32, 48, 64, 128, 256):  # en lo chico, menos margen: la marca ocupa más del cuadro
        lado, radio = round(n * (0.86 if n < 32 else 0.76)), round(n * 0.22)
        magick("-size", f"{n}x{n}", "xc:none", "-fill", "#FFFFFF", "-draw", f"roundrectangle 0,0 {n - 1},{n - 1} {radio},{radio}",
               "(", AQUI / "marca-chica.png", "-resize", f"{lado}x{lado}", ")", "-gravity", "center", "-composite",
               AQUI / "app" / f"helpert-{n}.png")
    # el .ico de Windows (ejecutable y ventanas) con los mismos dibujos por tamaño
    subprocess.run(["magick", *[AQUI / "app" / f"helpert-{n}.png" for n in (16, 24, 32, 48, 64, 256)], AQUI / "icono.ico"], check=True)
    magick(AQUI / "logo-texto-original.png", "-trim", "+repage", AQUI / "logo.png")
    magick(AQUI / "logo.png", *OSCURECER, AQUI / "logo-oscuro.png")
    for destino in (RAIZ / "bandeja" / "ui", RAIZ / "server" / "helpert_server" / "estatico"):
        for archivo in COPIAS:
            shutil.copy(AQUI / archivo, destino / archivo)
    print("iconos listos en", AQUI)
