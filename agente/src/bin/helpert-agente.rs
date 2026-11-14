//! helpert-agente: servicio del equipo. Escucha a la bandeja (o al chat de terminal) en un socket local,
//! reenvía al servidor y ejecuta solo los pasos de playbook que el servidor devuelve en su respuesta.
//!
//! shortcut: token por equipo sobre HTTP; antes del piloto, TLS mutuo con certificado por equipo (ver el plan).

use agente::canal::Conexion;
use agente::{cargar, canal, ejecutar, huella, leer_clave, servidor_seguro, validar, verificar_actualizacion};
use ed25519_dalek::VerifyingKey;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
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
    canal::RUTA.into()
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
    #[cfg(unix)]
    let programas = [("rustdesk", "rustdesk"), ("anydesk", "anydesk")];
    #[cfg(windows)]
    let programas = [("rustdesk", r"C:\Program Files\RustDesk\rustdesk.exe"), ("anydesk", r"C:\Program Files (x86)\AnyDesk\AnyDesk.exe")];
    for (prog, ruta) in programas {
        let Ok(mut hijo) = std::process::Command::new(ruta).arg("--get-id").stdout(std::process::Stdio::piped())
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

    /// Reemplaza este ejecutable por una versión firmada y sale con código 75: systemd (Restart=on-failure) o el
    /// administrador de servicios de Windows (acciones de recuperación) lo vuelve a arrancar. Antes prueba el binario nuevo: uno que no arranca nunca reemplaza al que funciona.
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
        let nuevo = self.exe.with_extension(if cfg!(windows) { "nuevo.exe" } else { "nuevo" });
        let _ = std::fs::remove_file(&nuevo);
        let mut opciones = std::fs::OpenOptions::new();
        opciones.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut opciones, 0o755);
        let escrito = opciones.open(&nuevo).and_then(|mut f| f.write_all(&datos).and_then(|_| f.sync_all()));
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
        reemplazar(&nuevo, &self.exe).map_err(|e| format!("{}: {e}", self.exe.display()))?;
        let espera = Instant::now();
        while self.ocupado.load(Ordering::SeqCst) > 0 && espera.elapsed() < Duration::from_secs(600) {
            std::thread::sleep(Duration::from_secs(1)); // no se corta una conversación a la mitad
        }
        eprintln!("[agente] actualizado a {version}; reinicio");
        salir(75);
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

/// Pone el binario nuevo en lugar del que corre. Windows no deja sobrescribir un ejecutable en uso, pero sí
/// renombrarlo: el viejo queda como `.viejo.exe` y se borra al arrancar la versión nueva.
#[cfg(unix)]
fn reemplazar(nuevo: &std::path::Path, exe: &std::path::Path) -> std::io::Result<()> {
    std::fs::rename(nuevo, exe)
}

#[cfg(windows)]
fn reemplazar(nuevo: &std::path::Path, exe: &std::path::Path) -> std::io::Result<()> {
    let viejo = exe.with_extension("viejo.exe");
    let _ = std::fs::remove_file(&viejo);
    std::fs::rename(exe, &viejo)?;
    std::fs::rename(nuevo, exe).inspect_err(|_| {
        let _ = std::fs::rename(&viejo, exe);
    })
}

/// Sale del proceso; como servicio de Windows, avisa antes el código al administrador de servicios.
fn salir(codigo: i32) -> ! {
    #[cfg(windows)]
    servicio::detenido(codigo);
    std::process::exit(codigo)
}

/// Usuario de quien se conecta, según el núcleo (SO_PEERCRED), no según lo que diga el cliente.
#[cfg(unix)]
fn usuario_de(s: &Conexion) -> Option<String> {
    use std::os::unix::io::AsRawFd;
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

/// Windows: la cuenta de quien abrió la tubería (`DOMINIO\usuario`), tomando su identidad un momento
/// (ImpersonateNamedPipeClient), no lo que diga el cliente. Se llama después de leer su petición.
#[cfg(windows)]
fn usuario_de(s: &Conexion) -> Option<String> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::Security::*;
    use windows_sys::Win32::System::Pipes::ImpersonateNamedPipeClient;
    use windows_sys::Win32::System::Threading::{GetCurrentThread, OpenThreadToken};
    unsafe {
        if ImpersonateNamedPipeClient(s.as_raw_handle() as HANDLE) == 0 {
            return None;
        }
        let mut token: HANDLE = std::ptr::null_mut();
        let abierto = OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token);
        RevertToSelf();
        if abierto == 0 {
            return None;
        }
        let mut buf = vec![0u8; 256];
        let mut largo = 0u32;
        let ok = GetTokenInformation(token, TokenUser, buf.as_mut_ptr() as _, buf.len() as u32, &mut largo);
        CloseHandle(token);
        if ok == 0 {
            return None;
        }
        let sid = (*(buf.as_ptr() as *const TOKEN_USER)).User.Sid;
        let (mut nombre, mut dominio) = ([0u16; 256], [0u16; 256]);
        let (mut ln, mut ld, mut uso) = (256u32, 256u32, 0);
        if LookupAccountSidW(std::ptr::null(), sid, nombre.as_mut_ptr(), &mut ln, dominio.as_mut_ptr(), &mut ld, &mut uso) == 0 {
            return None;
        }
        let texto = |b: &[u16], n: u32| String::from_utf16_lossy(&b[..n as usize]);
        Some(format!("{}\\{}", texto(&dominio, ld), texto(&nombre, ln)))
    }
}

/// Atiende una conexión del chat: lee una petición y responde con una línea (más líneas de progreso).
fn conversar(agente: &Agente, con: Conexion) {
    let mut linea = String::new();
    if BufReader::new(&con).read_line(&mut linea).is_err() {
        return;
    }
    let Some(usuario) = usuario_de(&con) else { return };
    agente.ocupado.fetch_add(1, Ordering::SeqCst);
    let resp = match serde_json::from_str::<Value>(&linea) {
        Ok(pet) => agente.atender(&pet, &usuario, &mut || {
            let _ = writeln!(&con, r#"{{"progreso":"trabajando"}}"#);
        }),
        Err(_) => json!({"error": "JSON no válido"}),
    };
    agente.ocupado.fetch_sub(1, Ordering::SeqCst);
    let _ = writeln!(&con, "{resp}");
}

/// Linux: socket en /run/helpert. Cualquier usuario del equipo puede pedir ayuda; quién es lo dice el núcleo,
/// y qué se ejecuta lo decide el servidor.
#[cfg(unix)]
fn escuchar(ruta: &std::path::Path, atender: impl Fn(Conexion) + Send + Sync + 'static) {
    use std::os::unix::fs::PermissionsExt;
    if let Some(dir) = ruta.parent() {
        std::fs::create_dir_all(dir).expect("carpeta del socket");
    }
    let _ = std::fs::remove_file(ruta);
    let escucha = std::os::unix::net::UnixListener::bind(ruta).expect("no pude abrir el socket");
    std::fs::set_permissions(ruta, std::fs::Permissions::from_mode(0o666)).expect("permisos del socket");
    let atender = Arc::new(atender);
    for con in escucha.incoming().flatten() {
        let atender = atender.clone();
        std::thread::spawn(move || atender(con));
    }
}

/// Windows: tubería con nombre, de SYSTEM, que los usuarios del equipo pueden leer y escribir pero no crear
/// (FILE_FLAG_FIRST_PIPE_INSTANCE: si alguien la creó antes, el servicio no arranca en vez de compartirla),
/// solo local.
#[cfg(windows)]
fn escuchar(ruta: &std::path::Path, atender: impl Fn(Conexion) + Send + Sync + 'static) {
    use std::os::windows::io::FromRawHandle;
    use windows_sys::Win32::Foundation::*;
    use windows_sys::Win32::Security::Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    use windows_sys::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX};
    use windows_sys::Win32::System::Pipes::*;
    let ancho = |t: &str| t.encode_utf16().chain([0]).collect::<Vec<u16>>();
    let nombre = ancho(ruta.to_str().expect("ruta de la tubería"));
    // dueño SYSTEM (el cliente lo comprueba); SYSTEM todo; usuarios autenticados: leer y escribir datos (0x12008b),
    // sin FILE_CREATE_PIPE_INSTANCE
    let sddl = ancho("O:SYG:SYD:P(A;;GA;;;SY)(A;;0x12008b;;;AU)");
    let mut sd = std::ptr::null_mut();
    let ok = unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut sd, std::ptr::null_mut()) };
    assert!(ok != 0, "descriptor de seguridad de la tubería");
    let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: sd, bInheritHandle: 0 };
    let atender = Arc::new(atender);
    let mut primera = true;
    loop {
        let modo = PIPE_ACCESS_DUPLEX | if primera { FILE_FLAG_FIRST_PIPE_INSTANCE } else { 0 };
        let h = unsafe {
            CreateNamedPipeW(nombre.as_ptr(), modo, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                             PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, &sa)
        };
        if h == INVALID_HANDLE_VALUE {
            let e = std::io::Error::last_os_error();
            if primera {
                panic!("no pude abrir la tubería {}: {e}", ruta.display());
            }
            eprintln!("[agente] tubería: {e}");
            std::thread::sleep(Duration::from_secs(1));
            continue;
        }
        primera = false;
        let conectado = unsafe { ConnectNamedPipe(h, std::ptr::null_mut()) } != 0
            || unsafe { GetLastError() } == ERROR_PIPE_CONNECTED;
        if !conectado {
            unsafe { CloseHandle(h) };
            continue;
        }
        let con = unsafe { std::fs::File::from_raw_handle(h as _) };
        let atender = atender.clone();
        std::thread::spawn(move || atender(con));
    }
}

/// Configuración por defecto: /etc/helpert/agente.toml o C:\ProgramData\Helpert\agente.toml.
fn config_defecto() -> String {
    #[cfg(windows)]
    return format!(r"{}\Helpert\agente.toml", std::env::var("ProgramData").unwrap_or_else(|_| r"C:\ProgramData".into()));
    #[cfg(unix)]
    return "/etc/helpert/agente.toml".into();
}

fn main() {
    if std::env::args().any(|a| a == "--version") {
        println!("{}", env!("CARGO_PKG_VERSION")); // la usa la prueba de una actualización antes de instalarla
        return;
    }
    #[cfg(windows)]
    if std::env::args().any(|a| a == "--servicio") {
        return servicio::iniciar(); // lo arranca el administrador de servicios (sc.exe create ... --servicio)
    }
    arrancar();
}

fn arrancar() {
    let ruta = std::env::args().skip(1).find(|a| !a.starts_with("--"))
        .or_else(|| std::env::var("HELPERT_AGENTE_CONFIG").ok())
        .unwrap_or_else(config_defecto);
    let cfg: Config = std::fs::read_to_string(&ruta).map_err(|e| e.to_string())
        .and_then(|t| toml::from_str(&t).map_err(|e| e.to_string()))
        .unwrap_or_else(|e| panic!("No pude leer {ruta}: {e}"));
    servidor_seguro(&cfg.servidor).unwrap_or_else(|e| panic!("{e}"));
    let clave = leer_clave(&cfg.clave_publica).unwrap_or_else(|e| panic!("Clave pública: {e}"));
    let http = ureq::Agent::new_with_config(
        ureq::config::Config::builder().http_status_as_error(false).timeout_global(Some(Duration::from_secs(180))).build(),
    );
    let exe = std::env::current_exe().expect("ruta del ejecutable");
    #[cfg(windows)]
    let _ = std::fs::remove_file(exe.with_extension("viejo.exe")); // el de antes de una actualización
    let binario = huella(&std::fs::read(&exe).expect("no pude leer mi propio ejecutable"));
    let socket = cfg.socket.clone();
    eprintln!("[agente] escuchando en {} · servidor {}", socket.display(), cfg.servidor);
    let agente = Arc::new(Agente { cfg, clave, http, exe, binario, avisos: Mutex::new(Vec::new()),
                                   ultimo_latido: Mutex::new(None), fallidas: Mutex::new(HashSet::new()),
                                   ocupado: AtomicUsize::new(0), remoto: Mutex::new((None, String::new())) });

    // Latido cada 5 minutos: la consola sabe qué agentes están vivos y con qué versión (plan, «Operación»).
    let latido = agente.clone();
    std::thread::spawn(move || loop {
        latido.latir(true);
        std::thread::sleep(Duration::from_secs(300));
    });

    escuchar(&socket, move |con| conversar(&agente, con));
}

/// El agente como servicio de Windows: corre como LocalSystem, con el registro en C:\ProgramData\Helpert\agente.log.
#[cfg(windows)]
mod servicio {
    use std::sync::OnceLock;
    use std::time::Duration;
    use windows_service::service::{ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus, ServiceType};
    use windows_service::service_control_handler::{self, ServiceControlHandlerResult, ServiceStatusHandle};

    const NOMBRE: &str = "helpert-agente";
    static ESTADO: OnceLock<ServiceStatusHandle> = OnceLock::new();

    windows_service::define_windows_service!(ffi_main, principal);

    pub fn iniciar() {
        windows_service::service_dispatcher::start(NOMBRE, ffi_main).expect("no lo arrancó el administrador de servicios");
    }

    fn poner(estado: ServiceState, codigo: i32) {
        if let Some(h) = ESTADO.get() {
            let _ = h.set_service_status(ServiceStatus {
                service_type: ServiceType::OWN_PROCESS,
                current_state: estado,
                controls_accepted: if estado == ServiceState::Running { ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN } else { ServiceControlAccept::empty() },
                exit_code: if codigo == 0 { ServiceExitCode::Win32(0) } else { ServiceExitCode::ServiceSpecific(codigo as u32) },
                checkpoint: 0,
                wait_hint: Duration::default(),
                process_id: None,
            });
        }
    }

    /// Un código distinto de 0 cuenta como falla: las acciones de recuperación del servicio lo vuelven a arrancar.
    pub fn detenido(codigo: i32) {
        poner(ServiceState::Stopped, codigo);
    }

    fn principal(_args: Vec<std::ffi::OsString>) {
        if let Err(e) = proteger_carpeta() {
            panic!("{e}"); // sin registro: el archivo estaría justo en esa carpeta
        }
        registro();
        let h = service_control_handler::register(NOMBRE, |c| match c {
            ServiceControl::Stop | ServiceControl::Shutdown => {
                detenido(0);
                std::process::exit(0)
            }
            ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
            _ => ServiceControlHandlerResult::NotImplemented,
        });
        let Ok(h) = h else { return };
        let _ = ESTADO.set(h);
        poner(ServiceState::Running, 0);
        // un pánico (configuración que no se lee, tubería ocupada) queda en el registro y cuenta como falla
        std::panic::set_hook(Box::new(|p| {
            eprintln!("[agente] {p}");
            super::salir(1);
        }));
        std::thread::spawn(agente::preparar_powershell);  // la caché de módulos, antes del primer playbook
        super::arrancar();
    }

    /// ProgramData\Helpert guarda la configuración con el token, el registro y la carpeta temporal de los scripts.
    /// ProgramData deja a cualquier usuario crear carpetas: si no existe, se crea ya con sus permisos (solo SYSTEM y
    /// Administradores, sin herencia), en la misma llamada, para que nadie alcance a dejar nada dentro; si existe y es un
    /// enlace o no es de SYSTEM ni de Administradores (alguien la creó antes de instalar), el servicio no arranca: el
    /// instalador la borra y la crea de nuevo. Si es de ellos, se le vuelven a fijar esos permisos (sin herencia). Dentro,
    /// tmp se crea de nuevo con los mismos permisos y el registro anterior se renombra antes de crear uno nuevo, sin
    /// abrir lo que hubiera.
    fn proteger_carpeta() -> Result<(), String> {
        use std::os::windows::fs::MetadataExt;
        use windows_sys::Win32::Foundation::{LocalFree, ERROR_SUCCESS};
        use windows_sys::Win32::Security::Authorization::*;
        use windows_sys::Win32::Security::*;
        use windows_sys::Win32::Storage::FileSystem::CreateDirectoryW;
        let dir = carpeta();
        let ruta: Vec<u16> = std::os::windows::ffi::OsStrExt::encode_wide(dir.as_os_str()).chain([0]).collect();
        let sddl: Vec<u16> = "O:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)".encode_utf16().chain([0]).collect();
        let mut sd = std::ptr::null_mut();
        if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut sd, std::ptr::null_mut()) } == 0 {
            return Err("descriptor de seguridad".into());
        }
        let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: sd, bInheritHandle: 0 };
        unsafe { CreateDirectoryW(ruta.as_ptr(), &sa) }; // si ya existe, falla y se revisa abajo
        let resultado = (|| {
            let m = std::fs::symlink_metadata(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
            if m.file_attributes() & 0x400 != 0 || !m.is_dir() {
                return Err(format!("{} es un enlace o no es una carpeta; reinstala Helpert", dir.display()));
            }
            let (mut dueno, mut sd_actual) = (std::ptr::null_mut(), std::ptr::null_mut());
            let r = unsafe {
                GetNamedSecurityInfoW(ruta.as_ptr(), SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION, &mut dueno,
                                      std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), &mut sd_actual)
            };
            let de_admin = r == ERROR_SUCCESS
                && unsafe { IsWellKnownSid(dueno, WinLocalSystemSid) != 0 || IsWellKnownSid(dueno, WinBuiltinAdministratorsSid) != 0 };
            if !sd_actual.is_null() {
                unsafe { LocalFree(sd_actual as _) };
            }
            if !de_admin {
                return Err(format!("{} no es de SYSTEM ni de Administradores; reinstala Helpert", dir.display()));
            }
            let (mut presente, mut dacl, mut por_defecto) = (0, std::ptr::null_mut(), 0);
            let r = unsafe {
                GetSecurityDescriptorDacl(sd, &mut presente, &mut dacl, &mut por_defecto);
                SetNamedSecurityInfoW(ruta.as_ptr(), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                                      std::ptr::null_mut(), std::ptr::null_mut(), dacl, std::ptr::null())
            };
            if r != ERROR_SUCCESS {
                return Err(format!("{}: no pude fijar sus permisos (error {r})", dir.display()));
            }
            let tmp = dir.join("tmp");
            let _ = std::fs::remove_dir_all(&tmp); // si es un enlace, borra el enlace, no lo que apunta
            let ancho_tmp: Vec<u16> = std::os::windows::ffi::OsStrExt::encode_wide(tmp.as_os_str()).chain([0]).collect();
            if unsafe { CreateDirectoryW(ancho_tmp.as_ptr(), &sa) } == 0 {
                return Err(format!("{}: {}", tmp.display(), std::io::Error::last_os_error()));
            }
            let _ = std::fs::rename(dir.join("agente.log"), dir.join("agente.anterior.log"));
            Ok(())
        })();
        unsafe { LocalFree(sd as _) };
        resultado
    }

    fn carpeta() -> std::path::PathBuf {
        std::path::PathBuf::from(std::env::var("ProgramData").unwrap_or_else(|_| r"C:\ProgramData".into())).join("Helpert")
    }

    /// Lo que el agente escribe en stderr va a un archivo nuevo en cada arranque (un servicio no tiene consola); el
    /// anterior queda como agente.anterior.log.
    fn registro() {
        use std::os::windows::io::IntoRawHandle;
        use windows_sys::Win32::System::Console::{SetStdHandle, STD_ERROR_HANDLE};
        let f = std::fs::OpenOptions::new().write(true).create_new(true).open(carpeta().join("agente.log"));
        if let Ok(f) = f {
            unsafe { SetStdHandle(STD_ERROR_HANDLE, f.into_raw_handle() as _) };
        }
    }
}
