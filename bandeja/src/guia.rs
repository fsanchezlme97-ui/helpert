//! Guía en pantalla: captura del monitor, ventana superpuesta con el resaltado y el cursor fantasma, y el clic.
//!
//! El servidor elige el elemento (Set-of-Mark) y devuelve su caja en píxeles de la captura. Aquí solo se dibuja esa
//! caja y, si la persona pulsa «Hazlo tú» en ese paso, se hace UNA acción de la lista cerrada en su centro. El chat
//! nunca pasa coordenadas: la acción sale del último paso que mandó el servidor y se consume al usarla.
//!
//! shortcut: un solo monitor (el enfocado en Hyprland; en los demás escritorios, la captura completa con origen 0,0).
//! Clic: Hyprland (hyprctl + ydotool) y X11 (xdotool); en GNOME/KDE Wayland la persona hace el clic. Windows después.

use base64::Engine;
use serde_json::{json, Value};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

/// Dónde está la captura en el escritorio: origen lógico del monitor y escala (píxeles físicos por lógico).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Geometria {
    pub x: f64,
    pub y: f64,
    pub escala: f64,
}

/// El último paso con elemento: lo único sobre lo que «Hazlo tú» puede actuar.
pub struct Ultimo(pub Mutex<Option<(Geometria, [f64; 4], String)>>);

pub const ACCIONES: [&str; 4] = ["clic", "doble_clic", "desplazar_abajo", "desplazar_arriba"];

/// Centro de la caja [x0, y0, x1, y1] (píxeles de la captura) en coordenadas lógicas del escritorio.
pub fn centro(g: Geometria, caja: [f64; 4]) -> (i32, i32) {
    (((caja[0] + caja[2]) / 2.0 / g.escala + g.x).round() as i32, ((caja[1] + caja[3]) / 2.0 / g.escala + g.y).round() as i32)
}

fn hyprland() -> bool {
    std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some()
}

fn x11() -> bool {
    std::env::var_os("WAYLAND_DISPLAY").is_none() && std::env::var_os("DISPLAY").is_some()
}

/// Captura del monitor donde trabaja la persona y su geometría.
fn capturar_monitor(app: &AppHandle) -> Result<(Vec<u8>, Geometria), String> {
    if hyprland() && std::env::var_os("HELPERT_CAPTURA_CMD").is_none() {
        let salida = Command::new("hyprctl").args(["-j", "monitors"]).output().map_err(|e| e.to_string())?;
        let monitores: Value = serde_json::from_slice(&salida.stdout).map_err(|e| e.to_string())?;
        let m = monitores.as_array().and_then(|l| l.iter().find(|m| m["focused"] == true).or(l.first()))
            .ok_or("No encontré el monitor")?;
        let nombre = m["name"].as_str().unwrap_or_default();
        if !nombre.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c)) {
            return Err("Nombre de monitor no válido".into());
        }
        // la imagen sale por la salida estándar: sin archivo temporal que otro usuario pueda cambiar
        let salida = Command::new("grim").args(["-o", nombre, "-"]).stderr(Stdio::null()).output();
        let (ok, datos) = salida.map(|s| (s.status.success(), s.stdout)).unwrap_or((false, Vec::new()));
        if !ok || !datos.starts_with(b"\x89PNG") {
            return Err("No pude ver tu pantalla en este escritorio.".into());
        }
        let g = Geometria { x: m["x"].as_f64().unwrap_or(0.0), y: m["y"].as_f64().unwrap_or(0.0),
                            escala: m["scale"].as_f64().filter(|s| *s > 0.0).unwrap_or(1.0) };
        return Ok((datos, g));
    }
    let datos = crate::tomar_captura()?;
    let escala = if x11() { 1.0 } else { app.primary_monitor().ok().flatten().map(|m| m.scale_factor()).unwrap_or(1.0) };
    Ok((datos, Geometria { x: 0.0, y: 0.0, escala }))
}

/// Capa «overlay» de Wayland (gtk-layer-shell, si está instalada y el escritorio la soporta): la ventana cubre el
/// monitor por encima de todo, sin foco ni teclado. Se carga en tiempo de ejecución: sin la biblioteca, la bandeja
/// sigue funcionando y la guía usa una ventana normal siempre encima.
#[cfg(target_os = "linux")]
fn capa_superpuesta(w: &tauri::WebviewWindow) -> bool {
    use gtk::glib::translate::ToGlibPtr;
    use gtk::prelude::*;
    type Ptr = *mut gtk::ffi::GtkWindow;
    let Ok(gw) = w.gtk_window() else { return false };
    let ventana: &gtk::Window = gw.upcast_ref();
    unsafe {
        let Ok(lib) = libloading::Library::new("libgtk-layer-shell.so.0") else { return false };
        let funciones = (|| -> Result<_, libloading::Error> {
            Ok((lib.get::<unsafe extern "C" fn() -> i32>(b"gtk_layer_is_supported\0")?,
                lib.get::<unsafe extern "C" fn(Ptr)>(b"gtk_layer_init_for_window\0")?,
                lib.get::<unsafe extern "C" fn(Ptr, i32)>(b"gtk_layer_set_layer\0")?,
                lib.get::<unsafe extern "C" fn(Ptr, i32, i32)>(b"gtk_layer_set_anchor\0")?,
                lib.get::<unsafe extern "C" fn(Ptr, i32)>(b"gtk_layer_set_exclusive_zone\0")?,
                lib.get::<unsafe extern "C" fn(Ptr, i32)>(b"gtk_layer_set_keyboard_mode\0")?,
                lib.get::<unsafe extern "C" fn(Ptr, *const std::ffi::c_char)>(b"gtk_layer_set_namespace\0")?))
        })();
        let Ok((soportada, iniciar, capa, ancla, zona, teclado, nombre)) = funciones else { return false };
        if soportada() == 0 {
            return false;
        }
        if ventana.is_realized() {
            ventana.unrealize(); // la capa se asigna antes de que la ventana exista en el compositor
        }
        let p: Ptr = ventana.to_glib_none().0;
        iniciar(p);
        capa(p, 3); // GTK_LAYER_SHELL_LAYER_OVERLAY
        for borde in 0..4 {
            ancla(p, borde, 1); // los cuatro bordes: cubre el monitor
        }
        zona(p, -1); // no empuja a las demás ventanas
        teclado(p, 0); // GTK_LAYER_SHELL_KEYBOARD_MODE_NONE
        nombre(p, c"helpert-guia".as_ptr());
        std::mem::forget(lib); // las funciones deben seguir cargadas mientras viva la ventana
    }
    true
}

fn ventana_guia(app: &AppHandle) -> Result<tauri::WebviewWindow, String> {
    if let Some(w) = app.get_webview_window("guia") {
        return Ok(w);
    }
    let w = WebviewWindowBuilder::new(app, "guia", WebviewUrl::App("guia.html".into()))
        .title("Helpert guía")
        .transparent(true)
        .decorations(false)
        .shadow(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(false)
        .focused(false)
        .visible(false)
        .build()
        .map_err(|e| e.to_string())?;
    #[cfg(target_os = "linux")]
    let en_capa = capa_superpuesta(&w);
    #[cfg(not(target_os = "linux"))]
    let en_capa = false;
    if !en_capa {
        // ventana normal del tamaño del escritorio (X11 y escritorios sin capas)
        if let Ok(Some(m)) = w.primary_monitor() {
            let _ = w.set_position(*m.position());
            let _ = w.set_size(*m.size());
        }
    }
    Ok(w)
}

fn ocultar(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("guia") {
        let _ = w.hide();
    }
}

fn base64(datos: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(datos)
}

/// Un paso de la guía: captura (sin las ventanas de Helpert), lo pide al servicio y muestra el resaltado.
#[tauri::command]
pub async fn guia_paso(app: AppHandle, caso_id: i64, hecho: String) -> Value {
    if !matches!(hecho.as_str(), "inicio" | "persona" | "helpert" | "nada") {
        return json!({"error": "Petición no válida"});
    }
    let a = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        *a.state::<Ultimo>().0.lock().unwrap() = None;
        ocultar(&a);
        let chat = a.get_webview_window("chat");
        if let Some(w) = &chat {
            let _ = w.hide();
        }
        std::thread::sleep(Duration::from_millis(450)); // que las ventanas terminen de ocultarse
        let captura = capturar_monitor(&a);
        if let Some(w) = &chat {
            let _ = w.show();
        }
        let (png, g) = match captura {
            Ok(x) => x,
            Err(e) => return json!({"error": e}),
        };
        let r = crate::hablar(&a, json!({"tipo": "pantalla", "caso_id": caso_id, "hecho": hecho, "imagen": base64(&png)}));
        let paso = &r["paso"];
        let caja: Option<[f64; 4]> = paso["caja"].as_array().filter(|c| c.len() == 4)
            .and_then(|c| Some([c[0].as_f64()?, c[1].as_f64()?, c[2].as_f64()?, c[3].as_f64()?]));
        match caja {
            Some(caja) if !paso["terminado"].as_bool().unwrap_or(false) => {
                let accion = paso["accion"].as_str().unwrap_or("ninguna").to_string();
                *a.state::<Ultimo>().0.lock().unwrap() = Some((g, caja, accion));
                if let Ok(w) = ventana_guia(&a) {
                    let _ = w.show(); // antes que lo siguiente: tao hace unwrap de la ventana GDK, que solo existe ya mostrada
                    let _ = w.set_ignore_cursor_events(true); // los clics pasan a lo que está debajo
                    let s = g.escala;
                    let _ = w.emit_to("guia", "guia", json!({
                        "x": caja[0] / s, "y": caja[1] / s, "ancho": (caja[2] - caja[0]) / s, "alto": (caja[3] - caja[1]) / s,
                        "n": paso["n"], "texto": paso["instruccion"]}));
                }
            }
            _ => ocultar(&a),
        }
        r
    })
    .await
    .unwrap_or_else(|e| json!({"error": e.to_string()}))
}

/// «Hazlo tú»: la persona permite UNA acción, la del último paso, sobre el elemento resaltado.
#[tauri::command]
pub async fn guia_actuar(app: AppHandle) -> Result<(), String> {
    let Some((g, caja, accion)) = app.state::<Ultimo>().0.lock().unwrap().take() else {
        return Err("No hay un paso para hacer.".into());
    };
    if !ACCIONES.contains(&accion.as_str()) {
        return Err("Este paso lo haces tú.".into());
    }
    let a = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        ocultar(&a);
        let chat = a.get_webview_window("chat");
        if let Some(w) = &chat {
            let _ = w.hide(); // que el clic no caiga en la ventana de Helpert
        }
        std::thread::sleep(Duration::from_millis(250));
        let (x, y) = centro(g, caja);
        let r = accionar(&accion, x, y);
        std::thread::sleep(Duration::from_millis(700)); // que la pantalla reaccione antes de la próxima captura
        if let Some(w) = &chat {
            let _ = w.show();
        }
        r
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn guia_cerrar(app: AppHandle) {
    *app.state::<Ultimo>().0.lock().unwrap() = None;
    ocultar(&app);
}

/// Los argumentos de cada herramienta: solo números y acciones de la lista cerrada, nunca texto.
pub fn ordenes(accion: &str, x: i32, y: i32, hypr: bool) -> Option<Vec<Vec<String>>> {
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    let (xs, ys) = (x.to_string(), y.to_string());
    if hypr {
        // shortcut: rueda de ydotool en «clics» de rueda; el sentido puede variar según la versión de ydotool
        let mover = s(&["hyprctl", "dispatch", "movecursor", &xs, &ys]);
        let accion = match accion {
            "clic" => s(&["ydotool", "click", "0xC0"]),
            "doble_clic" => s(&["ydotool", "click", "-r", "2", "0xC0"]),
            "desplazar_abajo" => s(&["ydotool", "mousemove", "-w", "--", "0", "-3"]),
            "desplazar_arriba" => s(&["ydotool", "mousemove", "-w", "--", "0", "3"]),
            _ => return None,
        };
        return Some(vec![mover, accion]);
    }
    let boton = match accion {
        "clic" => s(&["click", "1"]),
        "doble_clic" => s(&["click", "--repeat", "2", "1"]),
        "desplazar_abajo" => s(&["click", "--repeat", "3", "5"]),
        "desplazar_arriba" => s(&["click", "--repeat", "3", "4"]),
        _ => return None,
    };
    Some(vec![[s(&["xdotool", "mousemove", &xs, &ys]), boton].concat()])
}

fn accionar(accion: &str, x: i32, y: i32) -> Result<(), String> {
    let hypr = hyprland();
    if !hypr && !x11() {
        return Err("En este escritorio todavía no puedo hacer clic por ti. Hazlo tú y pulsa «Ya lo hice».".into());
    }
    for orden in ordenes(accion, x, y, hypr).ok_or("Este paso lo haces tú.")? {
        let ok = Command::new(&orden[0]).args(&orden[1..]).stdout(Stdio::null()).stderr(Stdio::null())
            .status().map(|s| s.success()).unwrap_or(false);
        if !ok {
            return Err(format!("No pude hacer el clic ({} no respondió). Hazlo tú y pulsa «Ya lo hice».", orden[0]));
        }
        std::thread::sleep(Duration::from_millis(80));
    }
    Ok(())
}

#[cfg(test)]
mod pruebas {
    use super::*;

    #[test]
    fn centro_en_coordenadas_logicas() {
        // monitor a la derecha de otro (origen lógico 1920), escala 1.5: 300 px físicos = 200 lógicos
        let g = Geometria { x: 1920.0, y: 0.0, escala: 1.5 };
        assert_eq!(centro(g, [200.0, 100.0, 400.0, 200.0]), (2120, 100));
    }

    #[test]
    fn solo_acciones_conocidas_y_numeros() {
        assert!(ordenes("escribir", 1, 2, true).is_none() && ordenes("tecla", 1, 2, false).is_none());
        assert_eq!(ordenes("clic", 10, 20, false).unwrap(), vec![vec!["xdotool", "mousemove", "10", "20", "click", "1"]]);
        let h = ordenes("doble_clic", 5, 6, true).unwrap();
        assert_eq!(h[0], vec!["hyprctl", "dispatch", "movecursor", "5", "6"]);
        assert_eq!(h[1], vec!["ydotool", "click", "-r", "2", "0xC0"]);
    }
}
