// Capa de la guía en pantalla: resalta el elemento del paso, mueve el cursor fantasma hasta él y muestra la instrucción.
// Solo escucha el evento «guia» de la bandeja; no llama a nada ni recibe clics.
const marco = document.getElementById("marco");
const numero = document.getElementById("numero");
const burbuja = document.getElementById("burbuja");
const texto = document.getElementById("texto");
const cursor = document.getElementById("cursor");
let desde = null;  // dónde quedó el cursor fantasma

function mostrar(p) {
  const m = 6;  // aire alrededor del elemento
  Object.assign(marco.style, { left: `${p.x - m}px`, top: `${p.y - m}px`, width: `${p.ancho + 2 * m}px`, height: `${p.alto + 2 * m}px` });
  numero.textContent = p.n ?? "";
  marco.hidden = false;
  texto.textContent = p.texto || "";
  burbuja.hidden = !p.texto;
  // la burbuja va debajo del elemento si cabe; si no, encima; nunca fuera de la pantalla
  const bw = Math.min(340, innerWidth - 24);
  const abajo = p.y + p.alto + m + 14;
  burbuja.style.left = `${Math.max(12, Math.min(p.x, innerWidth - bw - 12))}px`;
  burbuja.style.top = abajo + 90 < innerHeight ? `${abajo}px` : `${Math.max(12, p.y - m - 14 - burbuja.offsetHeight)}px`;
  // el cursor fantasma sale de donde quedó (o del centro) y apunta al centro del elemento
  const hasta = { x: p.x + p.ancho / 2, y: p.y + p.alto / 2 };
  if (!desde) {
    cursor.style.transition = "none";
    cursor.style.transform = `translate(${innerWidth / 2}px, ${innerHeight / 2}px)`;
    cursor.getBoundingClientRect();  // aplica la posición inicial antes de animar
    cursor.style.transition = "";
  }
  cursor.removeAttribute("hidden");  // es SVG: no tiene la propiedad hidden de HTML
  requestAnimationFrame(() => { cursor.style.transform = `translate(${hasta.x - 4}px, ${hasta.y - 3}px)`; });
  desde = hasta;
}

window.__TAURI__?.event.listen("guia", ({ payload }) => mostrar(payload));
window.helpertGuia = mostrar;  // pruebas de la página sin Tauri
