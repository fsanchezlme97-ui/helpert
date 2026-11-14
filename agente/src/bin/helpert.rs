//! helpert: chat de terminal con el agente local.
//! Habla el mismo protocolo que la bandeja (helpert-bandeja) por el socket; sirve en servidores y por SSH.

use serde_json::{json, Value};
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

fn enviar(socket: &str, pet: Value) -> Value {
    let r = (|| -> io::Result<Value> {
        let s = UnixStream::connect(socket)?;
        writeln!(&s, "{pet}")?;
        for linea in BufReader::new(&s).lines() {
            let v: Value = serde_json::from_str(&linea?).unwrap_or(json!({"error": "Respuesta no válida del agente"}));
            if v.get("progreso").is_none() {  // las líneas de progreso son para el icono de la bandeja
                return Ok(v);
            }
        }
        Ok(json!({"error": "El agente cerró la conexión"}))
    })();
    r.unwrap_or_else(|e| json!({"error": format!("No pude hablar con el agente de Helpert ({socket}): {e}")}))
}

fn preguntar(texto: &str) -> Option<String> {
    print!("{texto}");
    io::stdout().flush().ok()?;
    let mut l = String::new();
    (io::stdin().lock().read_line(&mut l).ok()? > 0).then(|| l.trim().to_string())
}

fn si(texto: &str) -> bool {
    loop {
        match preguntar(texto).as_deref().map(str::to_lowercase).as_deref() {
            Some("s" | "si" | "sí") => return true,
            Some("n" | "no") | None => return false,
            _ => println!("Responde s o n."),
        }
    }
}

/// Inicio de sesión como en la bandeja: correo y código (por correo o el que da soporte).
fn entrar(socket: &str) -> bool {
    let estado = enviar(socket, json!({"tipo": "cuenta", "accion": "estado"}));
    if let Some(e) = estado["error"].as_str() {
        println!("Helpert: {e}");
        return false;
    }
    if estado["sesion"] == true {
        return true;
    }
    println!("Inicia sesión con tu correo de trabajo.");
    let Some(email) = preguntar("Correo: ") else { return false };
    let r = enviar(socket, json!({"tipo": "cuenta", "accion": "codigo", "email": email}));
    println!("Helpert: {}", r["respuesta"].as_str().or(r["error"].as_str()).unwrap_or(""));
    let Some(codigo) = preguntar("Código: ") else { return false };
    let r = enviar(socket, json!({"tipo": "cuenta", "accion": "entrar", "email": email, "codigo": codigo}));
    match r["error"].as_str() {
        Some(e) => { println!("Helpert: {e}"); false }
        None => { println!("Listo, {}.", r["persona"]["nombre"].as_str().unwrap_or(&email)); true }
    }
}

fn main() {
    let socket = std::env::var("HELPERT_SOCKET").unwrap_or_else(|_| "/run/helpert/agente.sock".into());
    if !entrar(&socket) {
        return;
    }
    println!("Helpert · soporte TI. Cuéntame qué pasa (escribe «salir» para terminar).");
    let mut caso: Value = Value::Null;
    while let Some(texto) = preguntar("\nTú: ") {
        if texto.is_empty() {
            continue;
        }
        if texto == "salir" {
            break;
        }
        println!("…");
        let mut r = enviar(&socket, json!({"tipo": "mensaje", "caso_id": caso, "texto": texto}));
        loop {
            if let Some(e) = r["error"].as_str() {
                println!("Helpert: {e}");
                break;
            }
            caso = r["caso_id"].clone();
            println!("Helpert: {}", r["respuesta"].as_str().unwrap_or(""));
            if r["fin"] == true {
                caso = Value::Null;
                break;
            }
            if r["confirmar"] == true {
                let acepta = si("¿Continuar? (s/n): ");
                println!("…");
                r = enviar(&socket, json!({"tipo": "confirmar", "caso_id": caso, "acepta": acepta}));
            } else if r["cierre"] == true {
                let resuelto = si("(s/n): ");
                let nota = loop {  // la calificación es obligatoria
                    let Some(linea) = preguntar("Califica la atención de 1 a 5: ") else { return };
                    match linea.parse::<u8>() {
                        Ok(n) if (1..=5).contains(&n) => break n,
                        _ => println!("Escribe un número del 1 al 5."),
                    }
                };
                r = enviar(&socket, json!({"tipo": "cierre", "caso_id": caso, "resuelto": resuelto, "calificacion": nota}));
            } else {
                break;
            }
        }
    }
}
