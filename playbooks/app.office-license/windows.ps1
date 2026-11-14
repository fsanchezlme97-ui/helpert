# Revisar la licencia de Office: qué Office hay («Hacer clic y ejecutar» o MSI), el estado de sus licencias del equipo
# (ospp.vbs /dstatus) y si hay una licencia de Microsoft 365 de la cuenta de la persona (su registro, LicensingNext).
# Solo lectura: termina con 10. La licencia la asigna soporte.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$C2R = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
function Valor($ruta, $nombre) {
  try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null }
}
function Ospp {
  foreach ($r in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $r) { continue }
    foreach ($v in 'Office16', 'Office15') { $f = [IO.Path]::Combine($r, "Microsoft Office\$v\OSPP.VBS"); if ([IO.File]::Exists($f)) { return $f } }
  }
}
# licencias del equipo: una por producto, con su nombre, estado y días de gracia
function Licencias($ospp) {
  $ErrorActionPreference = 'Continue'  # cscript escribe en stderr; en 5.1 eso cortaría el script
  $salida = @(& "$env:SystemRoot\System32\cscript.exe" //nologo $ospp /dstatus 2>$null)
  $ErrorActionPreference = 'Stop'
  $l = $null
  foreach ($x in $salida) {
    if ($x -match '^LICENSE NAME:\s*(.+)$') { if ($l) { $l }; $l = [pscustomobject]@{ Nombre = ($Matches[1] -replace '^Office 1\d, ', '' -replace ' edition$', ''); Estado = ''; Gracia = '' } }
    elseif ($l -and $x -match '^LICENSE STATUS:\s*-*([A-Z_ ]+?)-*\s*$') { $l.Estado = $Matches[1] }
    elseif ($l -and $x -match '^REMAINING GRACE:\s*(\d+) days') { $l.Gracia = $Matches[1] }
  }
  if ($l) { $l }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $productos = "$(Valor $C2R 'ProductReleaseIds')"
      $ospp = Ospp
      if (-not $productos -and -not $ospp) { 'No encontré Microsoft Office instalado en este equipo.'; exit 10 }
      if ($productos) { "Tienes Microsoft Office «Hacer clic y ejecutar» (producto: $($productos -replace ',', ', '))." }
      if ((Valor $C2R 'SharedComputerLicensing') -eq '1') { 'Este equipo usa activación compartida: Office se activa cuando inicias sesión en él con tu cuenta del trabajo.' }
      $lic = @(); if ($ospp) { $lic = @(Licencias $ospp) }
      $buenas = @($lic | Where-Object { $_.Estado -eq 'LICENSED' })
      foreach ($x in @($buenas | Select-Object -First 3)) { "Licencia del equipo activa: $($x.Nombre)." }
      if (-not $buenas.Count) {
        foreach ($x in @($lic | Select-Object -First 2)) {
          $g = ''; if ($x.Gracia) { $g = " Quedan $($x.Gracia) días de gracia." }
          "La licencia $($x.Nombre) no está activada (estado: $($x.Estado)).$g"
        }
      }
      # licencia de Microsoft 365 de la cuenta de la persona (Office la guarda en su registro al iniciar sesión)
      $sid = SidDe $env:HP_USUARIO
      $cuenta = $false
      if ($sid) {
        $k = Get-Item -LiteralPath "Registry::HKEY_USERS\$sid\Software\Microsoft\Office\16.0\Common\Licensing\LicensingNext" -ErrorAction SilentlyContinue
        if ($k -and @($k.GetValueNames() | Where-Object { $_ -match 'retail|volume|o365|proplus|business' }).Count) { $cuenta = $true }
      }
      if ($cuenta) { 'Office tiene guardada una licencia de Microsoft 365 de tu cuenta.' }
      if ($buenas.Count -or $cuenta) {
        'Si aun así dice «producto sin licencia», cierra Office, ábrelo y en Archivo > Cuenta revisa que hayas entrado con tu cuenta del trabajo.'
      } else {
        'No encontré una licencia activa. Entra en Word con tu cuenta del trabajo (Archivo > Cuenta > Iniciar sesión); si sigue igual, pide a soporte que te asigne una licencia.'
      }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
