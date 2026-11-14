//! helpert-agente: servicio del equipo. Escucha a la bandeja (o al chat de terminal) en un socket local,
//! reenvía al servidor y ejecuta solo los pasos de playbook que el servidor devuelve en su respuesta.
//!
//! shortcut: token por equipo sobre HTTP; antes del piloto, TLS mutuo con certificado por equipo (ver el plan).

use agente::{cargar, ejecutar, huella, leer_clave, servidor_seguro, validar, verificar_actualizacion};
use ed25519_dalek::VerifyingKey;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Deserialize)]
struct Config {
    servidor: String,
    token: String,
    playbooks: PathBuf,
    clave_publica: PathBuf,
    #[serde(default = "socket_defecto")]
    socket: PathBuf,
}

fn socket_defecto() -> PathBuf {
    "/run/helpert/agente.sock".into()
}

struct Agente {
    cfg: Config,
    clave: VerifyingKey,
    http: ureq::Agent,
    exe: PathBuf,
    binario: String,                 // huella sha256 de este ejecutable
    avisos: Mutex<Vec<Value>>,       // llegan con el latido; se borran cuando la bandeja los muestra
    ultimo_latido: Mutex<Option<Instant>>,
    fallidas: Mutex<HashSet<String>>, // actualizaciones que no pasaron la prueba: no se descargan otra vez
    ocupado: AtomicUsize,            // conversaciones en curso: una actualización espera a que terminen
    remoto: Mutex<(Option<Instant>, String)>, // «rustdesk:123456789»: para que soporte se conecte; se renueva cada hora
}

/// ID de RustDesk o AnyDesk de este equipo, si alguno está instalado (programa con `--get-id`, máximo 5 s).
fn id_remoto() -> String {
    for prog in ["rustdesk", "anydesk"] {
        let Ok(mut hijo) = std::process::Command::new(prog).arg("--get-id").stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null()).spawn() else { continue };
        let inicio = Instant::now();
        while matches!(hijo.try_wait(), Ok(None)) && inicio.elapsed() < Duration::from_secs(5) {
            std::thread::sleep(Duration::from_millis(100));
        }
        if !matches!(hijo.try_wait(), Ok(Some(e)) if e.success()) {
            let _ = hijo.kill();
            let _ = hijo.wait();
            continue;
        }
        let mut salida = String::new();
        let _ = std::io::Read::read_to_string(&mut hijo.stdout.take().unwrap(), &mut salida);
        let id: String = salida.split_whitespace().last().unwrap_or_default().chars()
            .filter(|c| c.is_ascii_alphanumeric() || "@._-".contains(*c)).collect();
        if (3..=40).contains(&id.len()) {
            return format!("{prog}:{id}");
        }
    }
    String::new()
}

const SO: &str = std::env::consts::OS; // "linux" (y "windows" cuando se compile allá)

impl Agente {
    fn post(&self, ruta: &str, cuerpo: &Value) -> Result<Value, String> {
        let url = format!("{}{ruta}", self.cfg.servidor.trim_end_matches('/'));
        let remoto = self.remoto.lock().unwrap().1.clone();
        let mut r = self.http.post(&url)
            .header("Authorization", &format!("Bearer {}", self.cfg.token))
            .header("X-Helpert-Version", env!("CARGO_PKG_VERSION"))
            .header("X-Helpert-SO", SO)
            .header("X-Helpert-Binario", &self.binario)
            .header("X-Helpert-Remoto", &remoto)
            .send_json(cuerpo)
            .map_err(|e| format!("No pude conectar con el servidor de Helpert: {e}"))?;
        let estado = r.status().as_u16();
        let v: Value = r.body_mut().read_json().map_err(|e| e.to_string())?;
        if estado != 200 {
            return Err(v["detail"].as_str().map(String::from).unwrap_or_else(|| format!("Error {estado}")));
        }
        Ok(v)
    }

    fn descargar(&self, ruta: &str) -> Result<Vec<u8>, String> {
        if !ruta.starts_with("/v1/actualizacion/") {
            return Err("ruta de descarga no válida".into());
        }
        let url = format!("{}{ruta}", self.cfg.servidor.trim_end_matches('/'));
        let mut r = self.http.get(&url).header("Authorization", &format!("Bearer {}", self.cfg.token)).call()
            .map_err(|e| e.to_string())?;
        if r.status().as_u16() != 200 {
            return Err(format!("descarga: error {}", r.status().as_u16()));
        }
        r.body_mut().with_config().limit(64 * 1024 * 1024).read_to_vec().map_err(|e| e.to_string())
    }

    /// Latido: avisa que está vivo, recoge avisos para la bandeja y, si le toca y `actualizar`, se actualiza
    /// (solo desde el hilo del latido: nunca dentro de una conversación con la bandeja).
    fn latir(&self, actualizar: bool) {
        *self.ultimo_latido.lock().unwrap() = Some(Instant::now());
        let viejo = self.remoto.lock().unwrap().0.is_none_or(|t| t.elapsed() > Duration::from_secs(3600));
        if viejo && actualizar {  // solo desde el hilo del latido: nunca demora una conversación
            *self.remoto.lock().unwrap() = (Some(Instant::now()), id_remoto());
        }
        let r = match self.post("/v1/latido", &json!({})) {
            Ok(r) => r,
            Err(e) => return eprintln!("[agente] latido: {e}"),
        };
        if let Some(lista) = r["avisos"].as_array() {
            let mut a = self.avisos.lock().unwrap();
            for x in lista {
                if !a.iter().any(|y| y["id"] == x["id"]) {
                    a.push(x.clone());
                }
            }
        }
        if actualizar && r["actualizar"].is_object() {
            if let Err(e) = self.actualizar(&r["actualizar"]) {
                eprintln!("[agente] actualización: {e}");
            }
        }
    }

    /// Reemplaza este ejecutable por una versión firmada y sale con código 75: systemd lo vuelve a arrancar
    /// (Restart=on-failure). Antes prueba el binario nuevo: uno que no arranca nunca reemplaza al que funciona.
    fn actualizar(&self, a: &Value) -> Result<(), String> {
        let campo = |k: &str| a[k].as_str().ok_or(format!("falta {k}"));
        let (version, so, sha, firma, ruta) = (campo("version")?, campo("so")?, campo("sha256")?, campo("firma")?, campo("ruta")?);
        if sha == self.binario || self.fallidas.lock().unwrap().contains(sha) {
            return Ok(());
        }
        let fallar = |e: String| {
            self.fallidas.lock().unwrap().insert(sha.to_string());
            Err(e)
        };
        let datos = self.descargar(ruta)?;
        if let Err(e) = verificar_actualizacion(&datos, version, so, sha, firma, &self.clave) {
            return fallar(e);
        }
        let nuevo = self.exe.with_extension("nuevo");
        let _ = std::fs::remove_file(&nuevo);
        let escrito = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o755).open(&nuevo)
            .and_then(|mut f| f.write_all(&datos).and_then(|_| f.sync_all()));
        if let Err(e) = escrito {
            return Err(format!("{}: {e}", nuevo.display()));
        }
        // Prueba: el binario nuevo debe arrancar y decir su versión en menos de 10 segundos.
        let prueba = (|| -> Result<String, String> {
            let mut hijo = std::process::Command::new(&nuevo).arg("--version").stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null()).spawn().map_err(|e| e.to_string())?;
            let inicio = Instant::now();
            loop {
                if let Some(estado) = hijo.try_wait().map_err(|e| e.to_string())? {
                    let mut salida = String::new();
                    std::io::Read::read_to_string(&mut hijo.stdout.take().unwrap(), &mut salida).map_err(|e| e.to_string())?;
                    return if estado.success() { Ok(salida.trim().to_string()) } else { Err(format!("salió con {estado}")) };
                }
                if inicio.elapsed() > Duration::from_secs(10) {
                    let _ = hijo.kill();
                    return Err("no respondió en 10 s".into());
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        })();
        match prueba {
            Ok(v) if v == version => {}
            Ok(v) => {
                let _ = std::fs::remove_file(&nuevo);
                return fallar(format!("el binario dice ser {v}, no {version}"));
            }
            Err(e) => {
                let _ = std::fs::remove_file(&nuevo);
                return fallar(format!("el binario nuevo no pasó la prueba: {e}"));
            }
        }
        std::fs::rename(&nuevo, &self.exe).map_err(|e| format!("{}: {e}", self.exe.display()))?;
        let espera = Instant::now();
        while self.ocupado.load(Ordering::SeqCst) > 0 && espera.elapsed() < Duration::from_secs(600) {
            std::thread::sleep(Duration::from_secs(1)); // no se corta una conversación a la mitad
        }
        eprintln!("[agente] actualizado a {version}; reinicio");
        std::process::exit(75);
    }

    fn correr(&self, t: &Value, usuario: &str) -> Value {
        let id = t["playbook"].as_str().unwrap_or_default();
        let (codigo, salida, error) = match cargar(&self.cfg.playbooks, id, t["version"].as_str().unwrap_or_default(), &self.clave)
            .and_then(|p| {
                let vacio = serde_json::Map::new();
                let env = validar(&p.manifiesto, t["parametros"].as_object().unwrap_or(&vacio))?;
                Ok(ejecutar(&p, SO, t["paso"].as_str().unwrap_or_default(), &env, usuario))
            }) {
            Ok(s) => (s.codigo, s.salida, s.error),
            Err(e) => (-1, String::new(), format!("Rechazado por el agente: {e}")),
        };
        eprintln!("[agente] {id} {} → {codigo}", t["paso"]);
        let recorta = |s: String, n: usize| s.chars().rev().take(n).collect::<Vec<_>>().into_iter().rev().collect::<String>();
        json!({"trabajo_id": t["id"], "codigo": codigo, "salida": recorta(salida, 4000), "error": recorta(error, 2000)})
    }

    /// Atiende una petición del chat. El chat nunca puede pedir que se ejecute algo: solo el servidor.
    /// `trabajando` avisa al chat (una línea de progreso) antes de correr cada paso, para el estado de la bandeja.
    fn atender(&self, pet: &Value, usuario: &str, trabajando: &mut dyn FnMut()) -> Value {
        let (ruta, cuerpo) = match pet["tipo"].as_str() {
            Some("mensaje") => ("/v1/mensaje", json!({"caso_id": pet["caso_id"], "texto": pet["texto"], "usuario": usuario, "so": SO})),
            Some("confirmar") => ("/v1/confirmar", json!({"caso_id": pet["caso_id"], "acepta": pet["acepta"], "usuario": usuario})),
            Some("cierre") => ("/v1/cierre", json!({"caso_id": pet["caso_id"], "resuelto": pet["resuelto"], "usuario": usuario,
                                                    "calificacion": pet["calificacion"], "comentario": pet["comentario"]})),
            Some("captura") => {
                if pet["imagen"].as_str().map_or(0, str::len) > 12_000_000 {
                    return json!({"error": "La captura es demasiado grande"});
                }
                ("/v1/captura", json!({"caso_id": pet["caso_id"], "acepta": pet["acepta"], "imagen": pet["imagen"], "usuario": usuario}))
            }
            Some("pantalla") => {
                // guía en pantalla: la captura va al servidor, que elige el paso; aquí no se ejecuta nada
                if pet["imagen"].as_str().map_or(0, str::len) > 12_000_000 {
                    return json!({"error": "La captura es demasiado grande"});
                }
                ("/v1/pantalla", json!({"caso_id": pet["caso_id"], "imagen": pet["imagen"], "hecho": pet["hecho"], "usuario": usuario}))
            }
            Some("avisos") => {
                // la bandeja pregunta cada 30 s; con ella abierta, el latido se adelanta para que el aviso llegue en ~1 min
                let viejo = self.ultimo_latido.lock().unwrap().is_none_or(|t| t.elapsed() > Duration::from_secs(60));
                if viejo {
                    self.latir(false);
                }
                // cada usuario del sistema ve solo los avisos de sus casos (equipos compartidos)
                let mios: Vec<Value> = self.avisos.lock().unwrap().iter().filter(|a| a["usuario"] == usuario).cloned().collect();
                return json!({"avisos": mios});
            }
            Some("cuenta") => {
                // inicio de sesión, perfil e historial de la persona; quién es lo dice el núcleo (usuario), no el cliente
                let accion = pet["accion"].as_str().unwrap_or_default();
                if !matches!(accion, "estado" | "codigo" | "entrar" | "salir" | "perfil" | "casos") {
                    return json!({"error": "Petición no válida"});
                }
                let mut cuerpo = json!({"usuario": usuario});
                for k in ["email", "codigo", "nombre", "telefono", "sede"] {
                    if let Some(v) = pet[k].as_str() {
                        cuerpo[k] = json!(v);
                    }
                }
                return self.post(&format!("/v1/cuenta/{accion}"), &cuerpo).unwrap_or_else(|e| json!({"error": e}));
            }
            Some("aviso_visto") => {
                let id = pet["id"].clone();
                self.avisos.lock().unwrap().retain(|a| a["id"] != id || a["usuario"] != usuario);
                return self.post("/v1/avisos/visto", &json!({"id": id, "usuario": usuario})).unwrap_or_else(|e| json!({"error": e}));
            }
            _ => return json!({"error": "Petición no válida"}),
        };
        let mut textos = Vec::new();
        let mut r = match self.post(ruta, &cuerpo) {
            Ok(v) => v,
            Err(e) => return json!({"error": e}),
        };
        while r["trabajo"].is_object() {
            if let Some(t) = r["respuesta"].as_str().filter(|t| !t.is_empty()) {
                textos.push(t.to_string());
            }
            trabajando();
            let res = self.correr(&r["trabajo"], usuario);
            r = match self.post("/v1/resultado", &res) {
                Ok(v) => v,
                Err(e) => return json!({"error": e, "caso_id": r["caso_id"]}),
            };
        }
        if let Some(t) = r["respuesta"].as_str().filter(|t| !t.is_empty()) {
            textos.push(t.to_string());
        }
        r["respuesta"] = json!(textos.join("\n\n"));
        r
    }
}

/// Usuario de quien se conecta, según el núcleo (SO_PEERCRED), no según lo que diga el cliente.
fn usuario_de(s: &UnixStream) -> Option<String> {
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut largo = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let ok = unsafe {
        libc::getsockopt(s.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PEERCRED, &mut cred as *mut _ as *mut _, &mut largo)
    };
    if ok != 0 {
        return None;
    }
    let out = std::process::Command::new("id").arg("-nu").arg(cred.uid.to_string()).output().ok()?;
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string()).filter(|u| !u.is_empty())
}

fn main() {
    if std::env::args().any(|a| a == "--version") {
        println!("{}", env!("CARGO_PKG_VERSION")); // la usa la prueba de una actualización antes de instalarla
        return;
    }
    let ruta = std::env::args().nth(1)
        .or_else(|| std::env::var("HELPERT_AGENTE_CONFIG").ok())
        .unwrap_or_else(|| "/etc/helpert/agente.toml".into());
    let cfg: Config = std::fs::read_to_string(&ruta).map_err(|e| e.to_string())
        .and_then(|t| toml::from_str(&t).map_err(|e| e.to_string()))
        .unwrap_or_else(|e| panic!("No pude leer {ruta}: {e}"));
    servidor_seguro(&cfg.servidor).unwrap_or_else(|e| panic!("{e}"));
    let clave = leer_clave(&cfg.clave_publica).unwrap_or_else(|e| panic!("Clave pública: {e}"));
    let http = ureq::Agent::new_with_config(
        ureq::config::Config::builder().http_status_as_error(false).timeout_global(Some(Duration::from_secs(180))).build(),
    );
    if let Some(dir) = cfg.socket.parent() {
        std::fs::create_dir_all(dir).expect("carpeta del socket");
    }
    let _ = std::fs::remove_file(&cfg.socket);
    let escucha = UnixListener::bind(&cfg.socket).expect("no pude abrir el socket");
    // Cualquier usuario del equipo puede pedir ayuda; quién es lo dice el núcleo, y qué se ejecuta lo decide el servidor.
    std::fs::set_permissions(&cfg.socket, std::fs::Permissions::from_mode(0o666)).expect("permisos del socket");
    eprintln!("[agente] escuchando en {} · servidor {}", cfg.socket.display(), cfg.servidor);
    let exe = std::env::current_exe().expect("ruta del ejecutable");
    let binario = huella(&std::fs::read(&exe).expect("no pude leer mi propio ejecutable"));
    let agente = Arc::new(Agente { cfg, clave, http, exe, binario, avisos: Mutex::new(Vec::new()),
                                   ultimo_latido: Mutex::new(None), fallidas: Mutex::new(HashSet::new()),
                                   ocupado: AtomicUsize::new(0), remoto: Mutex::new((None, String::new())) });

    // Latido cada 5 minutos: la consola sabe qué agentes están vivos y con qué versión (plan, «Operación»).
    let latido = agente.clone();
    std::thread::spawn(move || loop {
        latido.latir(true);
        std::thread::sleep(Duration::from_secs(300));
    });

    for con in escucha.incoming().flatten() {
        let agente = agente.clone();
        std::thread::spawn(move || {
            let Some(usuario) = usuario_de(&con) else { return };
            let mut linea = String::new();
            if BufReader::new(&con).read_line(&mut linea).is_err() {
                return;
            }
            agente.ocupado.fetch_add(1, Ordering::SeqCst);
            let resp = match serde_json::from_str::<Value>(&linea) {
                Ok(pet) => agente.atender(&pet, &usuario, &mut || {
                    let _ = writeln!(&con, r#"{{"progreso":"trabajando"}}"#);
                }),
                Err(_) => json!({"error": "JSON no válido"}),
            };
            agente.ocupado.fetch_sub(1, Ordering::SeqCst);
            let _ = writeln!(&con, "{resp}");
        });
    }
}
