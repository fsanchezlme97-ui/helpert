"""Genera el logo y los iconos de la bandeja de Helpert: solo casco y lentes, para que se lean a cualquier tamaño.

Colores de la paleta Oxocarbon (hyprfrijol, config/themes/palettes.json: «oxocarbon» y «oxocarbon-claro»).
El azul del casco «pensando» es el color principal de toda la interfaz; el logo es ese casco.

    python3 bandeja/iconos/generar.py   # escribe los .svg y, con rsvg-convert, los .png de 64 px
"""
import pathlib
import subprocess

AQUI = pathlib.Path(__file__).parent
TEMAS = {  # contorno, punto de aviso y color del casco por estado
    "claro": dict(trazo="#161616", punto="#161616",
                  casco={"disponible": "#24A148", "pensando": "#0F62FE", "trabajando": "#F1C21B", "aviso": "#DA1E28"}),
    "oscuro": dict(trazo="#DDE1E6", punto="#F2F4F8",
                   casco={"disponible": "#42BE65", "pensando": "#78A9FF", "trabajando": "#FFE97B", "aviso": "#EE5396"}),
}
TINTA = "#161616"  # símbolo del casco y pupilas: oscuros en los dos temas
LENTE = "#FFFFFF"  # lentes siempre blancos

SIMBOLOS = {
    "disponible": f'<path d="M26.5 20.5 31 25 38.5 15.5" fill="none" stroke="{TINTA}" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"/>',
    "pensando": f'<path d="M26 15.5 31 20 26 24.5M33 24.5h6" fill="none" stroke="{TINTA}" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>',
    "trabajando": "".join(f'<rect x="30.6" y="13.1" width="2.8" height="3.4" rx=".6" fill="{TINTA}" transform="rotate({a} 32 20.5)"/>'
                          for a in range(0, 360, 45))
                  + f'<circle cx="32" cy="20.5" r="4.6" fill="{TINTA}"/><circle cx="32" cy="20.5" r="1.9" fill="CASCO"/>',
    "aviso": f'<path d="M30.4 13h3.2l-.5 8h-2.2z" fill="{TINTA}" stroke="{TINTA}" stroke-width="1" stroke-linejoin="round"/>'
             f'<circle cx="32" cy="24.6" r="1.8" fill="{TINTA}"/>',
}


def dibujo(estado: str, t: dict) -> str:
    casco, trazo = t["casco"][estado], t["trazo"]
    extra = ""
    if estado == "trabajando":  # ondas de vibración a los dos lados
        extra = (f'<g fill="none" stroke="{trazo}" stroke-width="2.4" stroke-linecap="round">'
                 '<path d="M6 13Q2 19 4 26"/><path d="M1 9Q-3.5 18-1 28"/>'
                 '<path d="M58 13Q62 19 60 26"/><path d="M63 9Q67.5 18 65 28"/></g>')
    elif estado == "aviso":
        extra = f'<circle cx="61" cy="2" r="4.6" fill="{t["punto"]}"/>'
    return f'''<g stroke="{trazo}" stroke-width="2.6" stroke-linejoin="round" stroke-linecap="round">
<path d="M12 31C12 15 20.5 6 32 6S52 15 52 31Z" fill="{casco}"/>
<path d="M28.5 7.5V4.5Q28.5 3 30 3H34Q35.5 3 35.5 4.5V7.5" fill="{casco}"/>
<path d="M30 4.5 30.3 11.5M34 4.5 33.7 11.5" fill="none"/>
<path d="M6 32.5Q6 29 10.5 29H53.5Q58 29 58 32.5Q58 35.5 54.5 35.5H9.5Q6 35.5 6 32.5Z" fill="{casco}"/>
<path d="M30 42H34" fill="none"/>
<rect x="15" y="37.5" width="15" height="11" rx="3.2" fill="{LENTE}"/>
<rect x="34" y="37.5" width="15" height="11" rx="3.2" fill="{LENTE}"/>
</g>
<circle cx="22.8" cy="43" r="2.8" fill="{TINTA}"/><circle cx="41.2" cy="43" r="2.8" fill="{TINTA}"/>
<circle cx="21.8" cy="42" r=".95" fill="{LENTE}"/><circle cx="40.2" cy="42" r=".95" fill="{LENTE}"/>
{SIMBOLOS[estado].replace("CASCO", casco)}
{extra}'''


def svg(contenido: str, caja: str) -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{caja}" width="64" height="64">\n{contenido}\n</svg>\n'


def png(ruta: pathlib.Path) -> None:
    subprocess.run(["rsvg-convert", "-w", "64", "-h", "64", str(ruta), "-o", str(ruta.with_suffix(".png"))], check=True)


if __name__ == "__main__":
    for tema, t in TEMAS.items():
        for estado in t["casco"]:  # bandeja: caja cuadrada con sitio para las ondas y el punto de aviso
            ruta = AQUI / f"{estado}-{tema}.svg"
            ruta.write_text(svg(dibujo(estado, t), "-3 -7 70 70"))
            png(ruta)
        ruta = AQUI / f"logo-{tema}.svg"  # logo: el casco «pensando», ajustado a su caja
        ruta.write_text(svg(dibujo("pensando", t), "4.5 -1.5 55 55"))
        png(ruta)
    print("iconos listos en", AQUI)
