# Rehacer la caché de Outlook: cierra Outlook de la persona (sus procesos, por SID) y renombra sus archivos de caché
# (*.ost de AppData\Local\Microsoft\Outlook) a <nombre>.ost.helpert-<fecha>, para que Outlook los descargue de nuevo.
# Deshacer cierra Outlook, borra la caché que se haya vuelto a descargar y devuelve la copia más reciente a su nombre.
# Los PST (archivos de datos con correo guardado en el equipo) no se tocan. Lo que toca la carpeta de la persona se hace
# con su propio token (el de su sesión), nunca como SYSTEM.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$NOMBRE = 'Outlook'
$PROCS = @('outlook')
$SUFIJO = '\.helpert-\d{8}-\d{6}$'

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
function Token($sid) {
  if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq $sid) { return 'yo' }
  $s = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $sid })
  if ($s.Count -eq 0) { return $null }
  Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class HpWts { [DllImport("wtsapi32.dll", SetLastError = true)] public static extern bool WTSQueryUserToken(uint sesion, out IntPtr token); }'
  $h = [IntPtr]::Zero
  if (-not [HpWts]::WTSQueryUserToken([uint32]$s[0].SessionId, [ref]$h)) { return $null }
  New-Object Microsoft.Win32.SafeHandles.SafeAccessTokenHandle $h
}
# con el token de la persona; lo que escribe el bloque se pierde, así que deja sus resultados en variables $script:
function ComoPersona($tok, [scriptblock]$b) {
  if ($tok -is [string]) { $null = & $b } else { [Security.Principal.WindowsIdentity]::RunImpersonated($tok, [Action]$b) }
}
function Preparar {
  $script:sid = SidDe $env:HP_USUARIO
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  $script:perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
  if (-not $perfil) { return 'No encontré tu carpeta personal en este equipo.' }
  $script:tok = Token $sid
  if (-not $tok) { return "Necesito que tengas la sesión abierta en este equipo para rehacer la caché de Outlook." }
}
function Procesos {
  @(Get-CimInstance Win32_Process | Where-Object { $PROCS -contains ("$($_.Name)" -replace '\.exe$', '') } |
      Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $sid })
}
function Cerrar {
  foreach ($p in @(Procesos)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  for ($i = 0; $i -lt 10; $i++) { if (@(Procesos).Count -eq 0) { return $true }; Start-Sleep -Seconds 1 }
  $false
}
# cachés (.ost) y copias de otras veces, con su tamaño en MB; corre con el token de la persona
function Revisar {
  $d = [IO.Path]::Combine($perfil, 'AppData\Local\Microsoft\Outlook')
  $script:osts = @(); $script:copias = @()
  if ([IO.Directory]::Exists($d)) {
    # «*.ost» también trae extensiones más largas: se filtra de nuevo
    $script:osts = @([IO.Directory]::GetFiles($d, '*.ost') | Where-Object { $_ -like '*.ost' })
    $script:copias = @([IO.Directory]::GetFiles($d, '*.ost.helpert-*') | Where-Object { $_ -match $SUFIJO } | Sort-Object)
  }
  $b = 0; foreach ($f in $osts) { $b += (New-Object IO.FileInfo $f).Length }; $script:mb = [math]::Round($b / 1MB)
  $b = 0; foreach ($f in $copias) { $b += (New-Object IO.FileInfo $f).Length }; $script:mbCopias = [math]::Round($b / 1MB)
}
# renombra cada caché; Outlook puede tardar unos segundos en soltarla después de cerrarse
function Renombrar {
  $fecha = Get-Date -Format 'yyyyMMdd-HHmmss'
  $script:hechos = 0; $script:fallidos = 0
  foreach ($f in $osts) {
    $ok = $false
    for ($i = 0; $i -lt 5 -and -not $ok; $i++) { try { [IO.File]::Move($f, "$f.helpert-$fecha"); $ok = $true } catch { Start-Sleep -Seconds 2 } }
    if ($ok) { $script:hechos++ } else { $script:fallidos++ }
  }
}
# por cada caché original, su copia más reciente vuelve a su nombre (la que Outlook haya descargado de nuevo se borra)
function Devolver {
  $script:hechos = 0; $script:fallidos = 0
  foreach ($g in ($copias | Group-Object { $_ -replace $SUFIJO, '' })) {
    $orig = $g.Name; $copia = @($g.Group)[-1]
    try { if ([IO.File]::Exists($orig)) { [IO.File]::Delete($orig) }; [IO.File]::Move($copia, $orig); $script:hechos++ } catch { $script:fallidos++ }
  }
}
$osts = @(); $copias = @(); $mb = 0; $mbCopias = 0; $hechos = 0; $fallidos = 0

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      ComoPersona $tok { Revisar }
      if ($osts.Count -eq 0) { 'No encontré la caché de Outlook (OST) en tu carpeta: o usas el Outlook nuevo, o Outlook web, o tu cuenta no guarda caché en este equipo.'; exit 10 }
      "Tu caché de Outlook ocupa $mb MB en $($osts.Count) archivo(s). La renombraría para que Outlook descargue tu correo de nuevo; con un buzón grande puede tardar horas."
      if (@(Procesos).Count) { 'Outlook está abierto: lo voy a cerrar antes. Si estás escribiendo un correo, guárdalo como borrador.' }
      if ($copias.Count) { "Ya hay $($copias.Count) copia(s) de otras veces ($mbCopias MB): si te falta espacio, pide a soporte que las borre." }
      exit 0
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      ComoPersona $tok { Revisar }
      if ($osts.Count -eq 0) { 'No hay caché de Outlook que rehacer.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      if (-not (Cerrar)) { 'No pude cerrar Outlook, así que no toqué nada.'; exit 1 }
      ComoPersona $tok { Revisar; Renombrar }
      if ($fallidos) { "No pude renombrar $fallidos archivo(s) de caché: otro programa los está usando (Teams o Skype a veces lo hacen). Ciérralos y vuelve a pedírmelo."; exit 1 }
      'Cerré Outlook y renombré su caché. Ábrelo: descargará tu correo de nuevo y, con un buzón grande, puede tardar horas. Mientras, quizá falten correos viejos.'
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      if (@(Procesos).Count) { 'Outlook está abierto y descargando tu correo de nuevo.'; exit 0 }
      ComoPersona $tok { Revisar }
      if ($osts.Count -or -not $copias.Count) { 'La caché vieja de Outlook sigue en su lugar.'; exit 1 }
      'Listo: Outlook creará una caché nueva al abrirlo.'
      exit 0
    }
    'deshacer' {
      $m = Preparar; if ($m) { $m; exit 1 }
      if (-not (Cerrar)) { 'No pude cerrar Outlook, así que no toqué nada.'; exit 1 }
      ComoPersona $tok { Revisar; Devolver }
      if ($hechos -eq 0 -and $fallidos -eq 0) { 'No encontré una copia de la caché de Outlook que devolver.'; exit 1 }
      if ($fallidos) { "No pude devolver $fallidos archivo(s) de caché: otro programa los está usando."; exit 1 }
      'Devolví la caché anterior de Outlook. Ábrelo de nuevo.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
