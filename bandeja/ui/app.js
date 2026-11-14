// Chat de la bandeja. Todo texto que llega del servicio (IA, scripts) se pone con textContent, nunca como HTML.
const { invoke } = window.__TAURI__.core;
const log = document.getElementById("log");
const bienvenida = document.getElementById("bienvenida");
const acciones = document.getElementById("acciones");
const form = document.getElementById("form");
const texto = document.getElementById("texto");
const enviarBtn = document.getElementById("enviar");
let caso = null;

function el(etiqueta, clase, contenido) {
  const n = document.createElement(etiqueta);
  if (clase) n.className = clase;
  if (typeof contenido === "string") n.textContent = contenido;
  else if (contenido) n.append(...contenido);
  return n;
}

function avatar() {
  const img = el("img", "mt-0.5 size-7 shrink-0");
  img.src = "icono.png";
  img.alt = "";
  return img;
}

// quien: "tu" | "helpert" | "error"; contenido: texto o nodos.
function burbuja(quien, contenido) {
  bienvenida.hidden = true;
  let fila;
  if (quien === "tu") {
    fila = el("div", "flex justify-end", [
      el("p", "max-w-[85%] whitespace-pre-wrap break-words rounded-2xl rounded-br-md bg-primary px-3.5 py-2 text-sm text-primary-foreground", contenido)]);
  } else {
    const estilo = quien === "error"
      ? "border-peligro/30 bg-peligro/10 text-peligro"
      : "bg-card text-card-foreground shadow-xs";
    fila = el("div", "flex items-start gap-2", [avatar(),
      el("div", `max-w-[85%] whitespace-pre-wrap break-words rounded-2xl rounded-tl-md border px-3.5 py-2 text-sm ${estilo}`, contenido)]);
  }
  log.append(fila);
  log.scrollTo({ top: log.scrollHeight, behavior: "smooth" });
  return fila;
}

function escribiendo() {
  const punto = (retraso) => el("span", `size-1.5 animate-bounce rounded-full bg-muted-foreground/70 ${retraso}`);
  const puntos = el("span", "flex h-5 items-center gap-1", [punto(""), punto("[animation-delay:150ms]"), punto("[animation-delay:300ms]")]);
  puntos.setAttribute("aria-label", "Helpert está pensando");
  return burbuja("helpert", [puntos]);
}

// lista: [etiqueta, accion, variante?]; variante "primario" para la respuesta afirmativa.
function botones(lista, titulo) {
  const hijos = lista.map(([etiqueta, accion, variante]) => {
    const b = el("button", `btn btn-sm rounded-full ${variante === "primario" ? "btn-primario" : "btn-borde"}`, etiqueta);
    b.type = "button";
    b.addEventListener("click", () => { burbuja("tu", etiqueta); accion(); });
    return b;
  });
  acciones.replaceChildren(...(titulo ? [el("p", "w-full text-xs text-muted-foreground", titulo)] : []), ...hijos);
  acciones.hidden = lista.length === 0;
  form.hidden = lista.length !== 0;  // mientras hay una pregunta con botones, se responde con ellos
  // Nunca se enfoca un botón: una tecla perdida (espacio, Enter) no debe confirmar un cambio en el equipo.
  if (lista.length) acciones.focus(); else texto.focus();
}

function ocupado(si) {
  texto.disabled = enviarBtn.disabled = si;
  for (const b of document.querySelectorAll("#sugerencias button")) b.disabled = si;
}

async function enviar(pet) {
  botones([]);
  ocupado(true);
  const espera = escribiendo();
  let r;
  try {
    r = await invoke("enviar", { pet });
  } catch (err) {
    r = { error: String(err) };
  }
  espera.remove();
  ocupado(false);
  if (r.error) { burbuja("error", r.error); texto.focus(); estado(); return; }  // p. ej. la sesión se cerró en la consola
  if (pet.tipo !== "captura") caso = r.caso_id ?? caso;  // una captura de un caso escalado no lo reabre
  if (r.respuesta) burbuja("helpert", r.respuesta);
  const evidencia = r.pedir_captura ? r.caso_id : null;
  if (r.fin) caso = null;
  if (r.confirmar) {
    botones([["Sí, continuar", () => enviar({ tipo: "confirmar", caso_id: caso, acepta: true }), "primario"],
             ["No", () => enviar({ tipo: "confirmar", caso_id: caso, acepta: false })]],
            "Helpert necesita tu permiso para hacer este cambio.");
  } else if (r.cierre) {
    pedirCierre(r.pantalla);
  } else if (evidencia) {
    // Plan, paso 3: la captura se pide en el momento, con permiso, y la persona la ve antes de enviarla.
    botones([["Sí, tomar captura", () => tomarCaptura(evidencia), "primario"],
             ["No, sin captura", () => enviar({ tipo: "captura", caso_id: evidencia, acepta: false })]],
            "¿Puedo tomar una captura de tu pantalla como evidencia? La verás antes de enviarla.");
  } else {
    botones([]);
  }
}

// La calificación es obligatoria: sin ella no se abre un caso nuevo.
function pedirCierre(pantalla) {
  const calificar = (resuelto) => {
    burbuja("helpert", "¿Cómo calificas la atención?");
    const nota = (n) => async () => { await enviar({ tipo: "cierre", caso_id: caso, resuelto, calificacion: n }); estado(); };
    botones([["1", nota(1)], ["2", nota(2)], ["3", nota(3)], ["4", nota(4)], ["5", nota(5)]], "1 = mala · 5 = excelente");
  };
  const lista = [["Sí, se resolvió", () => calificar(true), "primario"], ["No", () => calificar(false)]];
  if (pantalla) lista.push(["Guíame en pantalla", () => guiar("inicio")]);
  botones(lista, pantalla ? "¿Se resolvió tu problema? También puedo señalarte cada paso en tu pantalla." : "¿Se resolvió tu problema?");
}

// Guía en pantalla: Helpert mira la pantalla (sin sus ventanas), resalta el siguiente elemento y mueve un cursor fantasma.
// La persona hace el paso o, con «Hazlo tú», permite UNA acción sobre ese elemento. Nada se envía sin pedirlo aquí.
const VERBO = { clic: "clic", doble_clic: "doble clic", desplazar_abajo: "bajar", desplazar_arriba: "subir" };
async function guiar(hecho) {
  botones([]);
  ocupado(true);
  const espera = escribiendo();
  let r;
  try {
    r = await invoke("guia_paso", { casoId: caso, hecho });
  } catch (err) {
    r = { error: String(err) };
  }
  espera.remove();
  ocupado(false);
  const terminar = () => { invoke("guia_cerrar").catch(() => {}); pedirCierre(); };
  if (r.error) { burbuja("error", r.error); invoke("guia_cerrar").catch(() => {}); return pedirCierre(true); }  // se puede reintentar
  if (!r.paso) {  // p. ej. el paso necesitaba a soporte y el caso se escaló
    invoke("guia_cerrar").catch(() => {});
    if (r.respuesta) burbuja("helpert", r.respuesta);
    return botones([]);
  }
  const p = r.paso;
  burbuja("helpert", `Paso ${p.n}: ${p.instruccion}`);
  if (p.terminado) return terminar();
  const lista = [["Ya lo hice", () => guiar("persona"), "primario"]];
  if (p.caja && VERBO[p.accion]) lista.push([`Hazlo tú: ${VERBO[p.accion]} en «${p.etiqueta}»`, () => hazlo()]);
  lista.push(["Terminar guía", terminar]);
  botones(lista, p.caja ? "Te lo marqué en la pantalla con un recuadro." : "");
}

async function hazlo() {
  botones([]);
  ocupado(true);
  try {
    await invoke("guia_actuar");
  } catch (err) {
    ocupado(false);
    burbuja("error", String(err));
    return botones([["Ya lo hice", () => guiar("persona"), "primario"], ["Terminar guía", () => { invoke("guia_cerrar"); pedirCierre(); }]]);
  }
  ocupado(false);
  guiar("helpert");
}

async function tomarCaptura(cid) {
  botones([]);
  ocupado(true);
  let datos;
  try {
    datos = await invoke("capturar");
  } catch (err) {
    ocupado(false);
    burbuja("error", String(err));
    return enviar({ tipo: "captura", caso_id: cid, acepta: false });
  }
  ocupado(false);
  const img = el("img", "mt-2 max-h-56 w-full rounded-lg border object-contain");
  img.src = URL.createObjectURL(new Blob([datos], { type: "image/png" }));
  img.alt = "Vista previa de la captura";
  burbuja("helpert", [el("p", "", "Esta es la captura. Si muestra algo privado, descártala."), img]);
  botones([["Enviar captura", () => enviar({ tipo: "captura", caso_id: cid, acepta: true, imagen: base64(datos) }), "primario"],
           ["Descartar", () => enviar({ tipo: "captura", caso_id: cid, acepta: false })]]);
}

function base64(buffer) {
  const bytes = new Uint8Array(buffer);
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

// Avisos del Área de Sistemas (técnico asignado, visita terminada): llegan con el latido del servicio.
const mostrados = new Set();
async function revisarAvisos() {
  let r;
  try { r = await invoke("consultar", { pet: { tipo: "avisos" } }); } catch { return; }
  for (const a of r.avisos || []) {
    if (mostrados.has(a.id)) continue;
    mostrados.add(a.id);
    burbuja("helpert", a.texto);
    if (a.cierre) {
      caso = a.caso_id;
      pedirCierre();
    }
    invoke("consultar", { pet: { tipo: "aviso_visto", id: a.id } }).catch(() => {});
  }
}

function mandar(t) {
  burbuja("tu", t);
  enviar({ tipo: "mensaje", caso_id: caso, texto: t });
}

form.addEventListener("submit", (ev) => {
  ev.preventDefault();
  const t = texto.value.trim();
  if (!t) return;
  texto.value = "";
  ajustar();
  mandar(t);
});

for (const b of document.querySelectorAll("#sugerencias button")) {
  b.addEventListener("click", () => mandar(b.textContent));
}

// El cuadro crece con el texto hasta su max-h.
function ajustar() {
  texto.style.height = "auto";
  texto.style.height = `${texto.scrollHeight}px`;
}
texto.addEventListener("input", ajustar);
texto.addEventListener("keydown", (ev) => {
  if (ev.key === "Enter" && !ev.shiftKey && !ev.isComposing) { ev.preventDefault(); form.requestSubmit(); }
});

// ── Cuenta: inicio de sesión, pestañas, historial, ayuda y perfil ──────────────────────────────────────────────
const vistas = ["chat", "casos", "ayuda", "perfil"];
let cuenta = {};
const $ = (id) => document.getElementById(id);
const cuentaPet = (accion, datos = {}) => invoke("consultar", { pet: { tipo: "cuenta", accion, ...datos } })
  .catch((err) => ({ error: String(err) }));

function mostrarVista(v) {
  for (const x of vistas) $(`vista-${x}`).hidden = x !== v;
  for (const b of document.querySelectorAll("[data-vista]")) {
    if (b.dataset.vista === v) b.setAttribute("aria-current", "page"); else b.removeAttribute("aria-current");
  }
  if (v === "casos") cargarCasos();
  if (v === "chat") texto.focus();
}
for (const b of document.querySelectorAll("[data-vista]")) b.addEventListener("click", () => mostrarVista(b.dataset.vista));

let reintento = null;
async function estado() {
  const r = await cuentaPet("estado");
  if (r.error) {
    // el servicio no responde (p. ej. se reinicia tras actualizarse): se reintenta solo; si ya había sesión, el chat sigue a la vista
    clearTimeout(reintento);
    reintento = setTimeout(estado, 5000);
    if (!$("vista-app").hidden) return;
    $("vista-entrar").hidden = true;
    $("sin-servicio").hidden = false;
    $("sin-servicio").textContent = r.error;
    return;
  }
  $("sin-servicio").hidden = true;
  cuenta = r;
  $("vista-entrar").hidden = r.sesion;
  $("vista-app").hidden = !r.sesion;
  if (!r.sesion) { $("correo").focus(); return; }
  const nombre = r.persona.nombre || r.persona.email;
  $("quien").textContent = `${nombre} · ${r.empresa.nombre}`;
  $("saludo").textContent = r.persona.nombre ? `Hola, ${r.persona.nombre.split(" ")[0]}` : "Hola, soy Helpert";
  $("pendiente-punto").hidden = !r.pendiente;
  pintarAyuda();
  pintarPerfil();
}

// Inicio de sesión: correo → código (por correo o el que da soporte).
let correoActual = "";
$("form-correo").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  correoActual = $("correo").value.trim();
  $("entrar-error").textContent = "";
  const r = await cuentaPet("codigo", { email: correoActual });
  if (r.error) { $("entrar-error").textContent = r.error; return; }
  $("codigo-ayuda").textContent = r.respuesta;
  $("form-correo").hidden = true;
  $("form-codigo").hidden = false;
  $("codigo").focus();
});
$("form-codigo").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const r = await cuentaPet("entrar", { email: correoActual, codigo: $("codigo").value.trim() });
  if (r.error) { $("entrar-error").textContent = r.error; $("codigo").select(); return; }
  $("codigo").value = "";
  $("form-codigo").hidden = true;
  $("form-correo").hidden = false;
  $("entrar-error").textContent = "";
  await estado();
  mostrarVista("chat");
});
$("otro-correo").addEventListener("click", () => {
  $("form-codigo").hidden = true;
  $("form-correo").hidden = false;
  $("entrar-error").textContent = "";
  $("correo").focus();
});

// Historial
const ESTADOS = { conversando: ["En curso", "info"], menu: ["En curso", "info"], esperando_confirmacion: ["Espera tu permiso", "alerta"],
  aplicando: ["Aplicando", "alerta"], esperando_cierre: ["Por calificar", "alerta"], escalado: ["Con soporte", "peligro"],
  cerrado: ["Cerrado", "exito"] };
const fechaCorta = (iso) => new Date(iso).toLocaleDateString("es", { day: "2-digit", month: "short" });

async function cargarCasos() {
  const lista = $("lista-casos");
  const r = await cuentaPet("casos");
  if (r.error) { lista.replaceChildren(el("li", "text-sm text-peligro", r.error)); return; }
  if (!r.casos.length) {
    lista.replaceChildren(el("li", "rounded-xl border border-dashed p-8 text-center text-sm text-muted-foreground",
                             "Todavía no pediste ayuda. Cuando lo hagas, tus casos aparecen aquí."));
    return;
  }
  lista.replaceChildren(...r.casos.map((k) => {
    const [txt, variante] = k.estado === "cerrado" && k.resuelto === false ? ["Sin resolver", "neutra"] : ESTADOS[k.estado] || [k.estado, "neutra"];
    const insignia = el("span", `insignia insignia-${variante} shrink-0`, k.nivel > 1 && k.estado === "escalado" ? `${txt} · N${k.nivel}` : txt);
    const detalle = [fechaCorta(k.creado), k.categoria].filter(Boolean).join(" · ");
    const fila = el("li", "tarjeta gap-2 px-4 py-3", [
      el("div", "flex items-start justify-between gap-3", [
        el("p", "min-w-0 text-sm font-medium break-words", k.titulo || "Sin mensaje"), insignia]),
      el("p", "text-xs text-muted-foreground", `Caso #${k.id} · ${detalle}${k.calificacion ? ` · ${"★".repeat(k.calificacion)}` : ""}`)]);
    if (k.estado === "esperando_cierre") {
      const b = el("button", "btn btn-primario btn-sm w-fit", "Calificar ahora");
      b.type = "button";
      b.addEventListener("click", () => {
        mostrarVista("chat");
        caso = k.id;
        burbuja("helpert", `¿Se resolvió tu caso #${k.id}?`);
        pedirCierre();
      });
      fila.append(b);
    }
    return fila;
  }));
}

// Ayuda: contacto de soporte de la empresa y control remoto
function pintarAyuda() {
  const e = cuenta.empresa;
  $("empresa-nombre").textContent = `Soporte de ${e.nombre}`;
  const datos = [["Teléfono", e.telefono], ["WhatsApp", e.whatsapp, e.whatsapp && `https://wa.me/${e.whatsapp.replace(/\D/g, "")}`],
                 ["Correo", e.correo, e.correo && `mailto:${e.correo}`], ["Horario", e.horario]].filter((d) => d[1]);
  $("contacto").replaceChildren(...(datos.length ? datos.map(([t, v, url]) => {
    let valor = el("dd", "select-all", v);
    if (url) {
      const b = el("button", "text-left text-primary underline-offset-4 hover:underline", v);
      b.type = "button";
      b.addEventListener("click", () => invoke("abrir", { url }).catch(() => {}));
      valor = el("dd", "", [b]);
    }
    return el("div", "grid grid-cols-[6rem_1fr] gap-2", [el("dt", "text-muted-foreground", t), valor]);
  }) : [el("p", "text-muted-foreground", "Tu empresa aún no cargó un contacto de soporte.")]));
  const [programa, id] = (cuenta.remoto_id || "").split(":");
  const nombre = { rustdesk: "RustDesk", anydesk: "AnyDesk" }[programa || e.remoto] || null;
  $("remoto-caja").hidden = !nombre;
  $("remoto-id").textContent = id ? `Tu ID: ${id}` : "";
  $("remoto-id").hidden = !id;
  $("abrir-remoto").textContent = `Abrir ${nombre}`;
  $("abrir-remoto").onclick = () => invoke("abrir_remoto", { programa: programa || e.remoto })
    .catch((err) => { $("remoto-id").hidden = false; $("remoto-id").textContent = String(err); });
}

// Perfil
function pintarPerfil() {
  const p = cuenta.persona;
  $("perfil-correo").textContent = p.email;
  $("p-nombre").value = p.nombre || "";
  $("p-telefono").value = p.telefono || "";
  const sedes = [{ nombre: "" }, ...cuenta.sedes];
  $("p-sede").replaceChildren(...sedes.map((s) => {
    const o = el("option", "", s.nombre ? (s.region ? `${s.nombre} · ${s.region}` : s.nombre) : "Sin elegir");
    o.value = s.nombre;
    o.selected = s.nombre === (p.sede || "");
    return o;
  }));
}
$("form-perfil").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const r = await cuentaPet("perfil", { nombre: $("p-nombre").value, telefono: $("p-telefono").value, sede: $("p-sede").value });
  $("perfil-ok").className = r.error ? "text-sm text-peligro" : "text-sm text-exito";
  $("perfil-ok").textContent = r.error || "Guardado";
  if (!r.error) await estado();
  setTimeout(() => { $("perfil-ok").textContent = ""; }, 2500);
});
$("salir").addEventListener("click", async () => {
  await cuentaPet("salir");
  caso = null;
  log.replaceChildren(bienvenida);
  bienvenida.hidden = false;
  botones([]);
  await estado();
});

setInterval(revisarAvisos, 30_000);
revisarAvisos();
estado();
