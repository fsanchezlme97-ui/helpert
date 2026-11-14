// Consola de Helpert: mejora las páginas que arma el servidor (todas funcionan sin JavaScript).
// Seguridad: DataTables lee las tablas ya escapadas del HTML, Choices no acepta HTML (allowHTML: false) y
// los gráficos usan tooltips de texto (renderMode: "richText"); ningún dato se inserta con innerHTML.
(() => {
  "use strict";

  const ES = {
    search: "", searchPlaceholder: "Buscar…", lengthMenu: "_MENU_ por página",
    info: "_START_–_END_ de _TOTAL_", infoEmpty: "Sin resultados", infoFiltered: "(filtrado de _MAX_)",
    zeroRecords: "Nada coincide con la búsqueda.", emptyTable: "No hay datos.",
    paginate: { first: "Primera", last: "Última", next: "›", previous: "‹" },
    aria: {
      orderable: "Ordenar por esta columna", orderableReverse: "Invertir orden",
      paginate: { first: "Primera", previous: "Anterior", next: "Siguiente", last: "Última" },
    },
  };
  const guardar = (k, v) => { try { sessionStorage.setItem(k, JSON.stringify(v)); } catch { /* sin almacenamiento */ } };
  const leer = (k) => { try { return JSON.parse(sessionStorage.getItem(k)); } catch { return null; } };

  // Tablas: data-tabla="completa" (búsqueda, páginas, estado guardado) o "simple" (solo ordenar).
  const tablas = new Map();
  for (const t of document.querySelectorAll("table[data-tabla]")) {
    const completa = t.dataset.tabla === "completa";
    const dt = new DataTable(t, {
      language: ES,
      order: [],
      autoWidth: false,
      paging: completa,
      pageLength: 25,
      info: completa,
      searching: true,
      stateSave: completa,
      stateDuration: 60 * 60 * 8,
      layout: completa
        ? { topStart: null, topEnd: null, bottomStart: ["pageLength", "info"], bottomEnd: "paging" }
        : { topStart: null, topEnd: null, bottomStart: null, bottomEnd: null },
    });
    tablas.set(t.id, dt);
  }

  // Buscador propio (estilo shadcn) para una tabla.
  for (const input of document.querySelectorAll("input[data-buscar]")) {
    const dt = tablas.get(input.dataset.buscar);
    if (!dt) continue;
    input.value = dt.search();
    input.addEventListener("input", () => dt.search(input.value).draw());
  }

  // Filas con enlace: clic en cualquier parte de la fila abre el caso.
  document.addEventListener("click", (ev) => {
    const fila = ev.target.closest("tr[data-href]");
    if (!fila || ev.target.closest("a, button, input, select") || String(window.getSelection())) return;
    window.location.assign(fila.dataset.href);
  });

  // Selects con Choices.js. data-filtro="tabla:columna" filtra una columna de DataTables por valores exactos.
  const abiertos = new Set();
  for (const sel of document.querySelectorAll("select[data-choices]")) {
    const clave = `helpert:${location.pathname}:${sel.name}`;
    const filtro = sel.dataset.filtro;
    if (filtro && sel.multiple) {
      const previos = leer(clave) || [];
      for (const o of sel.options) o.selected = previos.includes(o.value);
    }
    const ch = new Choices(sel, {
      allowHTML: false,
      searchEnabled: sel.multiple || sel.options.length > 8,
      shouldSort: false,
      itemSelectText: "",
      removeItemButton: sel.multiple,
      placeholderValue: sel.dataset.placeholder || "",
      searchPlaceholderValue: "Buscar…",
      noResultsText: "Sin resultados",
      noChoicesText: "No hay más opciones",
    });
    // Choices arma su propio combobox: le pasa el nombre accesible del select (aria-label o su <label>)
    const nombre = sel.getAttribute("aria-label") || sel.labels[0]?.textContent.trim();
    if (nombre) {
      for (const el of [ch.containerOuter?.element, ch.input?.element, ch.choiceList?.element, ch.itemList?.element]) el?.setAttribute("aria-label", nombre);
    }
    sel.addEventListener("showDropdown", () => abiertos.add(ch));
    sel.addEventListener("hideDropdown", () => abiertos.delete(ch));
    if (filtro) {
      const [tablaId, col] = filtro.split(":");
      const dt = tablas.get(tablaId);
      const aplicar = () => {
        const valores = [...sel.selectedOptions].map((o) => o.value);
        guardar(clave, valores);
        dt.column(Number(col)).search(
          valores.length ? `^(${valores.map(DataTable.util.escapeRegex).join("|")})$` : "", { regex: true, smart: false },
        ).draw();
      };
      if (dt) { sel.addEventListener("change", aplicar); aplicar(); }
    }
  }
  // Administración: confirmar acciones que no se deshacen y copiar secretos que se muestran una sola vez.
  document.addEventListener("submit", (ev) => {
    const msg = ev.target.dataset.confirmar;
    if (!msg || window.confirm(msg)) return;
    ev.preventDefault();
    for (const s of ev.target.querySelectorAll("select")) {  // cancelado: el select vuelve a su valor
      for (const o of s.options) o.selected = o.defaultSelected;
    }
  });
  for (const b of document.querySelectorAll("button[data-copiar]")) {
    b.addEventListener("click", async () => {
      const texto = document.getElementById(b.dataset.copiar).textContent;
      try { await navigator.clipboard.writeText(texto); } catch { return; }
      const antes = b.lastChild.textContent;
      b.lastChild.textContent = "Copiado";
      setTimeout(() => { b.lastChild.textContent = antes; }, 1800);
    });
  }
  for (const sel of document.querySelectorAll("select[data-enviar]")) {
    sel.addEventListener("change", () => sel.form.requestSubmit());
  }
  for (const b of document.querySelectorAll("[data-solo-sin-js]")) b.hidden = true;
  for (const b of document.querySelectorAll("[data-con-js]")) b.hidden = false;

  // Gráficos (ECharts) con los colores del tema; se redibujan al cambiar claro/oscuro.
  const lienzo = document.createElement("canvas").getContext("2d", { willReadFrequently: true });
  const color = (variable, alfa = 1) => {
    const v = getComputedStyle(document.documentElement).getPropertyValue(variable).trim();
    lienzo.clearRect(0, 0, 1, 1);
    lienzo.fillStyle = "#000";
    lienzo.fillStyle = v; // oklch → el navegador lo convierte; ECharts recibe rgb
    lienzo.fillRect(0, 0, 1, 1);
    const [r, g, b] = lienzo.getImageData(0, 0, 1, 1).data;
    return `rgba(${r},${g},${b},${alfa})`;
  };
  const graficos = [];
  const opciones = (d) => {
    const texto = color("--muted-foreground");
    const linea = color("--border");
    const serie = { exito: color("--exito"), peligro: color("--peligro"), info: color("--marca"), alerta: color("--alerta"),
                    neutro: color("--muted-foreground", 0.45) };
    for (let i = 1; i <= 8; i++) serie[`s${i}`] = color(`--serie-${i}`);  // categóricas, en orden fijo
    const base = {
      textStyle: { fontFamily: getComputedStyle(document.body).fontFamily, color: texto },
      tooltip: { renderMode: "richText", backgroundColor: color("--popover"), borderColor: linea,
                 textStyle: { color: color("--popover-foreground") } },
      animationDuration: 500,
    };
    const ejes = (categorias, horizontal) => {
      const cat = { type: "category", data: categorias, axisLine: { lineStyle: { color: linea } }, axisTick: { show: false },
                    axisLabel: { color: texto, hideOverlap: true } };
      const val = { type: "value", minInterval: 1, splitLine: { lineStyle: { color: linea, type: "dashed" } },
                    axisLabel: { color: texto } };
      return horizontal ? { xAxis: val, yAxis: { ...cat, inverse: true } } : { xAxis: cat, yAxis: val };
    };
    const leyenda = { bottom: 0, icon: "circle", itemWidth: 8, itemHeight: 8, textStyle: { color: texto } };
    if (d.tipo === "dona") {
      return { ...base, tooltip: { ...base.tooltip, trigger: "item" }, legend: leyenda,
        title: { text: String(d.total), subtext: "casos", left: "center", top: "34%", itemGap: 2,
                 textStyle: { fontSize: 28, fontWeight: 600, color: color("--foreground") },
                 subtextStyle: { fontSize: 12, color: texto } },
        series: [{ type: "pie", radius: ["58%", "80%"], center: ["50%", "44%"], padAngle: 2,
                   itemStyle: { borderRadius: 6 }, label: { show: false },
                   data: d.datos.map((x) => ({ name: x.nombre, value: x.valor, itemStyle: { color: serie[x.color] } })) }] };
    }
    const horizontal = d.tipo === "barras-h";
    return { ...base, tooltip: { ...base.tooltip, trigger: "axis", axisPointer: { type: "shadow" } }, legend: leyenda,
      grid: { left: 8, right: 16, top: 12, bottom: 36, containLabel: true }, ...ejes(d.categorias, horizontal),
      series: d.series.map((s, i) => ({ name: s.nombre, type: "bar", stack: d.apilar ? "total" : undefined,
        barMaxWidth: horizontal ? 18 : 28, data: s.datos, itemStyle: { color: serie[s.color],
        borderRadius: d.apilar && i < d.series.length - 1 ? 0 : horizontal ? [0, 4, 4, 0] : [4, 4, 0, 0],
        borderColor: color("--card"), borderWidth: d.apilar ? 1 : 0 } })) };  // separación entre segmentos
  };
  for (const el of document.querySelectorAll("[data-grafico]")) {
    const d = JSON.parse(el.dataset.grafico);
    const g = echarts.init(el, null, { renderer: "canvas" });
    g.setOption(opciones(d));
    graficos.push([g, d]);
    new ResizeObserver(() => g.resize()).observe(el);
  }
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    for (const [g, d] of graficos) g.setOption(opciones(d), true);
  });

  // Refresco: recarga la página (DataTables guarda orden, búsqueda y página) salvo que alguien esté escribiendo.
  const cada = Number(document.body.dataset.refrescar || 0);
  if (cada) {
    setInterval(() => {
      const activo = document.activeElement;
      if (document.hidden || abiertos.size || (activo && activo.matches("input, textarea, select"))) return;
      window.location.reload();
    }, cada * 1000);
  }
})();
