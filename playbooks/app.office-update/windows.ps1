# Actualizar Microsoft Office: pide a Office «Hacer clic y ejecutar» que busque e instale sus actualizaciones
# (OfficeC2RClient.exe /update user, sin ventanas y sin cerrar programas: termina de aplicarse al cerrarlos).
# Si la empresa maneja las actualizaciones de Office (directiva, Configuration Manager o desactivadas), no se salta: se dice.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$C2R = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$POLITICA = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'

function Valor($ruta, $nombre) {
  try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null }
}
function Exe { [IO.Path]::Combine($env:CommonProgramFiles, 'microsoft shared\ClickToRun\OfficeC2RClient.exe') }
function Instalado { (Valor $C2R 'Platform') -and [IO.File]::Exists((Exe)) }
function Bloqueo {  # por qué la empresa no deja actualizar desde aquí, o nada
  if ((Valor $POLITICA 'enableautomaticupdates') -eq 0 -or "$(Valor $C2R 'UpdatesEnabled')" -eq 'False') { return 'La empresa desactivó las actualizaciones de Office en este equipo: las maneja soporte.' }
  if ((Valor $POLITICA 'officemgmtcom') -eq 1 -or "$(Valor $C2R 'OfficeMgmtCOM')" -eq 'True') { return 'Las actualizaciones de Office de este equipo las envía soporte con su sistema de gestión: pídeselas a soporte.' }
}
function EsAdmin {
  (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if (-not (Instalado)) { 'No encontré Microsoft Office «Hacer clic y ejecutar» en este equipo: si tienes Office, es de otro tipo y lo actualiza soporte.'; exit 3 }
      "Tienes Microsoft Office, versión $(Valor $C2R 'VersionToReport')."
      $b = Bloqueo; if ($b) { $b; exit 3 }
      'Puedo pedirle que busque e instale sus actualizaciones: se descargan en segundo plano y terminan de aplicarse cuando cierres los programas de Office.'
      exit 0
    }
    'comprobar' {
      if (-not (EsAdmin)) { 'Helpert necesita privilegios de administrador para actualizar Office.'; exit 3 }
      if (-not (Instalado)) { 'No encontré Office «Hacer clic y ejecutar» en este equipo.'; exit 3 }
      $b = Bloqueo; if ($b) { $b; exit 3 }
      exit 0
    }
    'aplicar' {
      if (-not (Instalado)) { 'No encontré Office «Hacer clic y ejecutar» en este equipo.'; exit 1 }
      $psi = New-Object Diagnostics.ProcessStartInfo (Exe), '/update user displaylevel=false forceappshutdown=false'
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $p = [Diagnostics.Process]::Start($psi)
      if (-not $p.WaitForExit(600000)) { 'Office sigue buscando actualizaciones; las instalará en segundo plano.'; exit 0 }
      if ($p.ExitCode -ne 0) { "Office no pudo empezar a actualizarse (código $($p.ExitCode)). Revisa que haya internet y vuelve a intentarlo; si sigue, avisa a soporte."; exit 1 }
      'Le pedí a Office que se actualice: descarga en segundo plano y termina de aplicarse cuando cierres Word, Excel, Outlook y los demás.'
      exit 0
    }
    'verificar' {
      if (-not (Instalado)) { 'Office ya no aparece instalado: avisa a soporte.'; exit 1 }
      $s = Get-Service -Name ClickToRunSvc -ErrorAction SilentlyContinue
      if (-not $s -or $s.Status -ne 'Running') { 'El servicio de actualización de Office no está funcionando: avisa a soporte.'; exit 1 }
      "La actualización de Office está en marcha (versión actual: $(Valor $C2R 'VersionToReport')). Cierra los programas de Office cuando puedas para que termine."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
