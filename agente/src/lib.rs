//! Agente de Helpert: verifica, valida y ejecuta playbooks firmados.
//!
//! Reglas que no se negocian:
//! - Se ejecutan los bytes que se verificaron, no una ruta que se vuelve a leer.
//! - Los parámetros se validan otra vez aquí (además del servidor) y llegan al script como variables de entorno.
//! - Nada corre si la firma no es válida o la versión no es la que autorizó el servidor.

use ed25519_dalek::{Signature, VerifyingKey};
use serde::Deserialize;
use serde_json::{Map, Value};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub mod canal;

pub const FIRMA: &str = "firma.ed25519";

/// El token del equipo solo viaja cifrado: https siempre, salvo un servidor en este mismo equipo (desarrollo).
pub fn servidor_seguro(url: &str) -> Result<(), String> {
    if url.starts_with("https://") {
        return Ok(());
    }
    let resto = url.strip_prefix("http://").ok_or("el servidor debe empezar por https://")?;
    let host = resto.split(['/', '?', '#']).next().unwrap_or_default();
    let host = host.rsplit_once(':').map_or(host, |(h, puerto)| if puerto.chars().all(|c| c.is_ascii_digit()) { h } else { host });
    match host {
        "127.0.0.1" | "localhost" | "[::1]" => Ok(()),
        _ => Err(format!("{url}: sin https el token del equipo viajaría sin cifrar; usa https://")),
    }
}
pub const PASOS: [&str; 5] = ["diagnosticar", "comprobar", "aplicar", "verificar", "deshacer"];

#[derive(Debug, Deserialize)]
pub struct Regla {
    #[serde(default = "texto")]
    pub tipo: String,
    #[serde(default)]
    pub requerido: bool,
    pub min: Option<i64>,
    pub max: Option<i64>,
}

fn texto() -> String {
    "texto".into()
}

#[derive(Debug, Deserialize)]
pub struct Manifiesto {
    pub id: String,
    pub version: String,
    pub nombre: String,
    #[serde(default = "timeout_defecto")]
    pub timeout: u64,
    pub sistemas: HashMap<String, String>,
    #[serde(default)]
    pub parametros: HashMap<String, Regla>,
}

fn timeout_defecto() -> u64 {
    120
}

pub struct Paquete {
    pub manifiesto: Manifiesto,
    pub archivos: BTreeMap<String, Vec<u8>>,
}

fn id_valido(id: &str) -> bool {
    let b = id.as_bytes();
    !b.is_empty()
        && b.len() <= 64
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'.' || *c == b'-')
}

pub fn hex(s: &str) -> Result<Vec<u8>, String> {
    let s = s.trim();
    if s.len() % 2 != 0 {
        return Err("hex con largo impar".into());
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|e| e.to_string()))
        .collect()
}

pub fn leer_clave(ruta: &Path) -> Result<VerifyingKey, String> {
    let b = hex(&fs::read_to_string(ruta).map_err(|e| format!("{}: {e}", ruta.display()))?)?;
    let b: [u8; 32] = b.try_into().map_err(|_| "la clave pública debe tener 32 bytes".to_string())?;
    VerifyingKey::from_bytes(&b).map_err(|e| e.to_string())
}

fn leer_archivos(raiz: &Path, dir: &Path, out: &mut BTreeMap<String, Vec<u8>>) -> Result<(), String> {
    for e in fs::read_dir(dir).map_err(|e| e.to_string())? {
        let e = e.map_err(|e| e.to_string())?;
        let tipo = e.file_type().map_err(|e| e.to_string())?; // no sigue enlaces
        let ruta = e.path();
        if tipo.is_symlink() {
            return Err(format!("{}: no se permiten enlaces", ruta.display()));
        } else if tipo.is_dir() {
            leer_archivos(raiz, &ruta, out)?;
        } else if tipo.is_file() {
            // con «/» en todos los sistemas, como firma el servidor (as_posix)
            let partes: Option<Vec<&str>> = ruta.strip_prefix(raiz).unwrap().components().map(|c| c.as_os_str().to_str()).collect();
            let rel = partes.ok_or("ruta no UTF-8")?.join("/");
            out.insert(rel, fs::read(&ruta).map_err(|e| e.to_string())?);
        } else {
            return Err(format!("{}: tipo de archivo no permitido", ruta.display()));
        }
    }
    Ok(())
}

/// Lo que se firma (igual que `mensaje_paquete` del servidor): por ruta, `ruta\nlargo\n` + contenido.
pub fn mensaje(archivos: &BTreeMap<String, Vec<u8>>) -> Vec<u8> {
    let mut m = Vec::new();
    for (ruta, datos) in archivos.iter().filter(|(r, _)| r.as_str() != FIRMA) {
        m.extend_from_slice(format!("{ruta}\n{}\n", datos.len()).as_bytes());
        m.extend_from_slice(datos);
    }
    m
}

/// Huella sha256 en hex (la del binario del agente, para que el servidor sepa qué versión corre de verdad).
pub fn huella(datos: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(datos).iter().map(|b| format!("{b:02x}")).collect()
}

/// Lo que se firma al publicar un binario del agente: un paquete con un único archivo «actualizacion»
/// (igual que en catalogo.py). Sin manifest.toml no puede pasar por un playbook, ni al revés.
pub fn mensaje_actualizacion(version: &str, so: &str, sha: &str) -> Vec<u8> {
    let meta = format!("helpert-agente\n{version}\n{so}\n{sha}\n").into_bytes();
    mensaje(&BTreeMap::from([("actualizacion".to_string(), meta)]))
}

/// Comprueba una actualización descargada: huella de los bytes, sistema y firma de versión+sistema+huella.
pub fn verificar_actualizacion(datos: &[u8], version: &str, so: &str, sha: &str, firma_hex: &str, clave: &VerifyingKey)
    -> Result<(), String> {
    if !version.chars().all(|c| c.is_ascii_alphanumeric() || ".+-".contains(c)) || version.is_empty() || version.len() > 32 {
        return Err("versión no válida".into());
    }
    if so != std::env::consts::OS {
        return Err(format!("la actualización es para {so}"));
    }
    if huella(datos) != sha {
        return Err("la huella del archivo descargado no coincide".into());
    }
    let firma = Signature::from_slice(&hex(firma_hex)?).map_err(|e| e.to_string())?;
    clave.verify_strict(&mensaje_actualizacion(version, so, sha), &firma).map_err(|_| "firma de la actualización no válida".into())
}

/// Carga el paquete en memoria y verifica firma, id y versión. Lo que se ejecuta sale de esta copia.
pub fn cargar(carpeta: &Path, id: &str, version: &str, clave: &VerifyingKey) -> Result<Paquete, String> {
    if !id_valido(id) {
        return Err(format!("id no válido: {id}"));
    }
    let dir: PathBuf = carpeta.join(id);
    let mut archivos = BTreeMap::new();
    leer_archivos(&dir, &dir, &mut archivos)?;
    let firma = archivos.get(FIRMA).ok_or("el paquete no está firmado")?;
    let firma = hex(std::str::from_utf8(firma).map_err(|e| e.to_string())?)?;
    let firma = Signature::from_slice(&firma).map_err(|e| e.to_string())?;
    clave.verify_strict(&mensaje(&archivos), &firma).map_err(|_| "firma no válida".to_string())?;
    let texto = std::str::from_utf8(archivos.get("manifest.toml").ok_or("falta manifest.toml")?)
        .map_err(|e| e.to_string())?;
    let manifiesto: Manifiesto = toml::from_str(texto).map_err(|e| e.to_string())?;
    if manifiesto.id != id || manifiesto.version != version {
        return Err(format!("se pidió {id} {version} y el paquete es {} {}", manifiesto.id, manifiesto.version));
    }
    Ok(Paquete { manifiesto, archivos })
}

const TEXTO_PERMITIDO: fn(char) -> bool = |c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-');

/// Misma regla que `validar_parametros` del servidor. Devuelve las variables de entorno HP_<NOMBRE>.
pub fn validar(m: &Manifiesto, params: &Map<String, Value>) -> Result<Vec<(String, String)>, String> {
    if let Some(k) = params.keys().find(|k| !m.parametros.contains_key(*k)) {
        return Err(format!("parámetro no permitido: {k}"));
    }
    let mut env = Vec::new();
    for (nombre, r) in &m.parametros {
        if !nombre.chars().all(|c| c.is_ascii_lowercase() || c == '_') {
            return Err(format!("nombre de parámetro no válido: {nombre}"));
        }
        let v = match params.get(nombre) {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) if s.is_empty() => None,
            Some(v) => Some(v),
        };
        let Some(v) = v else {
            if r.requerido {
                return Err(format!("falta el parámetro {nombre}"));
            }
            continue;
        };
        let valor = match (r.tipo.as_str(), v) {
            ("texto", Value::String(s))
                if s.len() as i64 <= r.max.unwrap_or(100) && s.chars().all(TEXTO_PERMITIDO) => s.clone(),
            ("entero", Value::Number(n)) if n.is_i64() => {
                let n = n.as_i64().unwrap();
                if r.min.is_some_and(|x| n < x) || r.max.is_some_and(|x| n > x) {
                    return Err(format!("{nombre}: fuera de rango"));
                }
                n.to_string()
            }
            ("booleano", Value::Bool(b)) => (if *b { "1" } else { "0" }).into(),
            _ => return Err(format!("{nombre}: valor no válido")),
        };
        env.push((format!("HP_{}", nombre.to_uppercase()), valor));
    }
    Ok(env)
}

#[derive(Debug)]
pub struct Salida {
    pub codigo: i32,
    pub salida: String,
    pub error: String,
}

fn leer_hilo(r: impl Read + Send + 'static) -> std::thread::JoinHandle<String> {
    std::thread::spawn(move || {
        let mut b = Vec::new();
        let _ = r.take(64 * 1024).read_to_end(&mut b);
        String::from_utf8_lossy(&b).into_owned()
    })
}

/// Ejecuta un paso del playbook con el script ya verificado. Entorno limpio, sin heredar nada del agente.
pub fn ejecutar(p: &Paquete, so: &str, paso: &str, env: &[(String, String)], usuario: &str) -> Salida {
    let falla = |e: String| Salida { codigo: -1, salida: String::new(), error: e };
    if !PASOS.contains(&paso) {
        return falla(format!("paso no válido: {paso}"));
    }
    if so != std::env::consts::OS {
        return falla(format!("este equipo no es {so}"));
    }
    let Some(script) = p.manifiesto.sistemas.get(so).and_then(|f| p.archivos.get(f)) else {
        return falla(format!("{} no tiene script para {so}", p.manifiesto.id));
    };
    let Ok(script) = std::str::from_utf8(script) else { return falla("script no UTF-8".into()) };
    if script.contains('\0') {
        return falla("script con bytes nulos".into());
    }
    if cfg!(windows) && script.chars().count() > 10_000 {
        return falla("script de más de 10 000 caracteres: no cabe en la línea de comandos de Windows".into());
    }
    let mut cmd = comando(script, &p.manifiesto.id, paso);
    cmd.env("HP_PASO", paso)
        .env("HP_USUARIO", usuario)
        .envs(env.iter().map(|(k, v)| (k, v)))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut hijo = match cmd.spawn() {
        Ok(h) => h,
        Err(e) => return falla(e.to_string()),
    };
    let grupo = Grupo::de(&hijo);
    let out = leer_hilo(hijo.stdout.take().unwrap());
    let err = leer_hilo(hijo.stderr.take().unwrap());
    let limite = Instant::now() + Duration::from_secs(p.manifiesto.timeout);
    let codigo = loop {
        match hijo.try_wait() {
            Ok(Some(st)) => {
                grupo.matar(); // procesos sueltos que dejó el script
                break st.code().unwrap_or(-1);
            }
            Ok(None) if Instant::now() < limite => std::thread::sleep(Duration::from_millis(100)),
            _ => {
                grupo.matar();
                let _ = hijo.wait();
                break 124;
            }
        }
    };
    let mut error = err.join().unwrap_or_default();
    if codigo == 124 {
        error.push_str("\nSe pasó del tiempo límite.");
    }
    Salida { codigo, salida: out.join().unwrap_or_default(), error }
}

/// Linux: bash con el script como argumento, PATH fijo y su propio grupo de procesos.
#[cfg(unix)]
fn comando(script: &str, id: &str, paso: &str) -> Command {
    use std::os::unix::process::CommandExt;
    let mut cmd = Command::new("/bin/bash");
    cmd.arg("-c").arg(script).arg(format!("helpert-{id}")).arg(paso)
        .env_clear()
        .env("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
        .env("LANG", "C.UTF-8")
        .current_dir("/")
        .process_group(0); // para poder matar también a los hijos si se pasa del tiempo
    cmd
}

/// Windows: PowerShell 5.1 con el script en -EncodedCommand (los bytes verificados, sin archivo que se pueda
/// cambiar en medio) y salida en UTF-8. El paso va en HP_PASO. Del entorno del servicio solo pasa lo que
/// PowerShell y los comandos del sistema necesitan. TEMP es una carpeta del servicio (ProgramData\Helpert\tmp,
/// que el instalador deja solo para SYSTEM y administradores), no C:\Windows\Temp, donde cualquier usuario puede
/// dejar enlaces con los nombres que un script vaya a usar.
#[cfg(windows)]
fn comando(script: &str, _id: &str, _paso: &str) -> Command {
    use std::os::windows::process::CommandExt;
    let raiz = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
    let fuente = format!("$ProgressPreference = 'SilentlyContinue'\n[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)\n$OutputEncoding = [Console]::OutputEncoding\n{script}");
    let datos = format!(r"{}\Helpert", std::env::var("ProgramData").unwrap_or_else(|_| r"C:\ProgramData".into()));
    let tmp = format!(r"{datos}\tmp");
    let _ = std::fs::create_dir_all(&tmp);
    // Caché de módulos propia (en la carpeta del agente, solo SYSTEM y administradores): sin una completa, PowerShell 5.1
    // vuelve a recorrer los módulos cada vez que un script usa un cmdlet no cargado (18-28 s en la CI). La completa la
    // arma preparar_powershell; por eso la cabecera no usa cmdlets.
    let cache = format!(r"{datos}\powershell");
    let _ = std::fs::create_dir_all(&cache);
    let utf16: Vec<u8> = fuente.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let mut cmd = Command::new(format!(r"{raiz}\System32\WindowsPowerShell\v1.0\powershell.exe"));
    cmd.args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", &base64(&utf16)])
        .env_clear()
        .envs(["SystemRoot", "windir", "SystemDrive", "ProgramData", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432",
               "CommonProgramFiles", "CommonProgramFiles(x86)", "COMPUTERNAME", "PATHEXT", "NUMBER_OF_PROCESSORS",
               "PROCESSOR_ARCHITECTURE", "OS", "ALLUSERSPROFILE", "PUBLIC"]
            .into_iter().filter_map(|k| std::env::var(k).ok().map(|v| (k, v))))
        .env("PATH", format!(r"{raiz}\System32;{raiz};{raiz}\System32\Wbem;{raiz}\System32\WindowsPowerShell\v1.0\"))
        .env("PSModuleAnalysisCachePath", format!(r"{cache}\ModuleAnalysisCache"))
        .env("TEMP", &tmp)
        .env("TMP", &tmp)
        .current_dir(&raiz)
        .creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    cmd
}

/// Si aún no existe, arma la caché completa de módulos de PowerShell (lista todos los módulos y sus comandos), como
/// el servicio al arrancar: con ella un script tarda décimas en vez de 18-28 s, y el primer playbook de un equipo
/// nuevo no se pasa del tiempo límite. Espera a que termine (como mucho 10 minutos; en la CI, con 54 módulos, ~2).
#[cfg(windows)]
pub fn preparar_powershell() {
    let datos = format!(r"{}\Helpert", std::env::var("ProgramData").unwrap_or_else(|_| r"C:\ProgramData".into()));
    // marca propia: un playbook que corrió antes deja una caché parcial, que no sirve
    let lista = format!(r"{datos}\powershell\completa");
    if Path::new(&lista).exists() {
        return;
    }
    let mut cmd = comando("$null = Get-Module -ListAvailable -Refresh; $null = Get-Command -CommandType Cmdlet, Function",
                          "preparar", "preparar");
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    if let Ok(mut hijo) = cmd.spawn() {
        let grupo = Grupo::de(&hijo);
        let limite = Instant::now() + Duration::from_secs(600);
        let ok = loop {
            match hijo.try_wait() {
                Ok(Some(st)) => break st.success(),
                Ok(None) if Instant::now() < limite => std::thread::sleep(Duration::from_millis(200)),
                _ => break false,
            }
        };
        grupo.matar();
        let _ = hijo.wait();
        if ok {
            let _ = fs::write(&lista, b"");
        }
    }
}

/// Base64 estándar (para -EncodedCommand).
#[cfg(any(windows, test))]
fn base64(datos: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::with_capacity(datos.len().div_ceil(3) * 4);
    for c in datos.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            s.push(if i <= c.len() { A[(n >> (18 - 6 * i) & 63) as usize] as char } else { '=' });
        }
    }
    s
}

/// El proceso del script y todo lo que lance, para terminarlo junto.
#[cfg(unix)]
struct Grupo(i32);

#[cfg(unix)]
impl Grupo {
    fn de(hijo: &std::process::Child) -> Self {
        Grupo(hijo.id() as i32)
    }
    fn matar(&self) {
        unsafe { libc::kill(-self.0, libc::SIGKILL) };
    }
}

/// Windows: un Job object que termina a todos sus procesos al cerrarse.
#[cfg(windows)]
struct Grupo(windows_sys::Win32::Foundation::HANDLE);

#[cfg(windows)]
impl Grupo {
    fn de(hijo: &std::process::Child) -> Self {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::System::JobObjects::*;
        unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info as *const _ as _,
                                    std::mem::size_of_val(&info) as u32);
            AssignProcessToJobObject(job, hijo.as_raw_handle() as _);
            Grupo(job)
        }
    }
    fn matar(&self) {
        unsafe { windows_sys::Win32::System::JobObjects::TerminateJobObject(self.0, 124) };
    }
}

#[cfg(windows)]
impl Drop for Grupo {
    fn drop(&mut self) {
        unsafe { windows_sys::Win32::Foundation::CloseHandle(self.0) };
    }
}

#[cfg(test)]
mod pruebas {
    #[test]
    fn base64_como_el_estandar() {
        for (entrada, salida) in [("", ""), ("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"), ("foob", "Zm9vYg=="), ("fooba", "Zm9vYmE=")] {
            assert_eq!(super::base64(entrada.as_bytes()), salida);
        }
    }
}
