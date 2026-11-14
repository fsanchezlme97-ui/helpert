# Revisar dispositivos con errores: los que el Administrador de dispositivos marca con un aviso (Win32_PnPEntity con
# código de error) y pedirle a Windows que vuelva a detectar los dispositivos (pnputil /scan-devices). No reinicia
# ni desinstala ninguno. Los desactivados a propósito (código 22) solo se nombran: activarlos lo decide soporte.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$MOTIVOS = @{ 1 = 'su controlador no está bien instalado'; 10 = 'no pudo arrancar'; 18 = 'hay que reinstalar su controlador'; 28 = 'le falta el controlador'; 31 = 'Windows no pudo cargar su controlador'; 43 = 'Windows lo detuvo porque informó un problema' }

function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
# con la salida redirigida, Windows PowerShell convierte cada línea de stderr de un programa en un error, y con
# 'Stop' eso cortaría el script: aquí se ignora y vale el código de salida
function Pnp { $ErrorActionPreference = 'Continue'; $null = & pnputil.exe @args 2>$null; $LASTEXITCODE }
# conectados y con código de error (45 = desconectado: no es un error)
function ConError { @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -ne 45 }) }
function Malos { @(ConError | Where-Object { $_.ConfigManagerErrorCode -ne 22 }) }
function Nombre($d) { if ($d.Name) { $d.Name } else { 'Dispositivo desconocido' } }
function Linea($d) {
  $c = [int]$d.ConfigManagerErrorCode
  $m = "tiene un error (código $c)"; if ($MOTIVOS.ContainsKey($c)) { $m = $MOTIVOS[$c] }
  "- $(Nombre $d): $m."
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $todos = @(ConError); $mal = @(Malos)
      $des = @($todos | Where-Object { $_.ConfigManagerErrorCode -eq 22 })
      if ($mal.Count -eq 0) {
        'No hay dispositivos con errores.'
        if ($des.Count) { "Hay $($des.Count) dispositivo(s) desactivado(s) a propósito (por ejemplo «$(Nombre $des[0])»): si necesitas uno, pide a soporte que lo active." }
        'Si uno no funciona, desconéctalo, espera 5 segundos y conéctalo en otro puerto; si es interno, reinicia el equipo.'
        exit 10
      }
      "Hay $($mal.Count) dispositivo(s) con errores:"
      foreach ($d in ($mal | Select-Object -First 6)) { Linea $d }
      if ($mal.Count -gt 6) { "… y $($mal.Count - 6) más." }
      'Voy a pedirle a Windows que vuelva a detectar los dispositivos.'
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para volver a detectar los dispositivos.'; exit 3 }
      exit 0
    }
    'aplicar' {
      if ((Pnp /scan-devices) -ne 0) { 'No pude pedirle a Windows que vuelva a detectar los dispositivos (esta versión de Windows quizá no lo permite).'; exit 1 }
      Start-Sleep -Seconds 5
      'Le pedí a Windows que vuelva a detectar los dispositivos.'
      exit 0
    }
    'verificar' {
      $mal = @(Malos)
      if ($mal.Count) {
        "Sigue(n) con error $($mal.Count) dispositivo(s):"
        foreach ($d in ($mal | Select-Object -First 4)) { Linea $d }
        'Desconéctalo y conéctalo, o reinicia el equipo; si sigue igual, soporte tiene que revisar su controlador.'
        exit 1
      }
      'Ya no hay dispositivos con errores. Si el tuyo sigue sin funcionar, desconéctalo y conéctalo en otro puerto.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
