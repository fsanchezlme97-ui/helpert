# Permitir la cámara y el micrófono a nivel del equipo: si el interruptor de privacidad de Windows para todo el equipo
# (ConsentStore\webcam y \microphone, Value = Deny) los bloquea, lo vuelve a poner en Allow. No toca lo que la empresa
# fija por política (GPO AppPrivacy, MDM o AllowCamera = 0): eso se informa y sale con 3. Los interruptores de la
# cuenta de la persona solo se nombran: los cambia ella en Configuración.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$CS = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$POL = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
$MDM = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Privacy'
$COSAS = 'webcam', 'microphone'
$NOMBRE = @{ webcam = 'la cámara'; microphone = 'el micrófono' }
$AJUSTE = @{ webcam = 'Cámara'; microphone = 'Micrófono' }
$POLITICA = @{ webcam = 'LetAppsAccessCamera'; microphone = 'LetAppsAccessMicrophone' }

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
function Valor($ruta, $nombre) {
  try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null }
}
function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Bloqueado($k) { (Valor "HKLM:\$CS\$k" 'Value') -eq 'Deny' }
# 2 = la empresa obliga a negarlo a todos los programas
function Politica($k) {
  $n = $POLITICA[$k]
  (Valor $POL $n) -eq 2 -or (Valor $MDM $n) -eq 2 -or ($k -eq 'webcam' -and (Valor 'HKLM:\SOFTWARE\Policies\Microsoft\Camera' 'AllowCamera') -eq 0)
}
function PorPolitica { @($COSAS | Where-Object { Politica $_ }) }
function Arreglables { @($COSAS | Where-Object { (Bloqueado $_) -and -not (Politica $_) }) }
function Nombres($ks) { @($ks | ForEach-Object { $NOMBRE[$_] }) -join ' y ' }
# los interruptores de la cuenta de la persona (su rama del registro, si tiene la sesión abierta)
function NotaPersona {
  $sid = SidDe $env:HP_USUARIO
  if (-not $sid) { return }
  foreach ($k in $COSAS) {
    if ((Valor "Registry::HKEY_USERS\$sid\$CS\$k" 'Value') -eq 'Deny') { "En tu cuenta está desactivado $($NOMBRE[$k]): actívalo en Configuración > Privacidad y seguridad > $($AJUSTE[$k])." }
  }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $a = @(Arreglables); $p = @(PorPolitica)
      if ($a.Count) {
        "Windows bloquea $(Nombres $a) a todos los programas de este equipo."
        if ($p.Count) { "Además, una política de la empresa bloquea $(Nombres $p): eso no lo cambio." }
        "Voy a volver a permitir $(Nombres $a) a nivel del equipo."
        exit 0
      }
      if ($p.Count) { "Una política de la empresa bloquea $(Nombres $p) en este equipo: no la puedo cambiar. Si la necesitas para trabajar, pide a soporte."; exit 3 }
      'Windows permite la cámara y el micrófono a nivel del equipo.'
      NotaPersona
      exit 10
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para cambiar la privacidad del equipo.'; exit 3 }
      if (@(Arreglables).Count -eq 0) {
        $p = @(PorPolitica)
        if ($p.Count) { "Una política de la empresa bloquea $(Nombres $p): no la puedo cambiar."; exit 3 }
        'Ya no hay nada bloqueado a nivel del equipo.'; exit 3
      }
      exit 0
    }
    'aplicar' {
      $a = @(Arreglables)
      try { foreach ($k in $a) { Set-ItemProperty -LiteralPath "HKLM:\$CS\$k" -Name 'Value' -Value 'Allow' } }
      catch { 'No pude cambiar la privacidad del equipo: puede que una política de la empresa la proteja. Pide a soporte que lo revise.'; exit 1 }
      "Volví a permitir $(Nombres $a) a nivel del equipo. Cierra y abre el programa que los usa."
      exit 0
    }
    'verificar' {
      $b = @(Arreglables)
      if ($b.Count) { "Windows sigue bloqueando $(Nombres $b) a nivel del equipo."; exit 1 }
      $p = @(PorPolitica)
      if ($p.Count) { "Windows ya no los bloquea a nivel del equipo, pero una política de la empresa sigue bloqueando $(Nombres $p)." }
      else { 'Windows permite la cámara y el micrófono a nivel del equipo.' }
      NotaPersona
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
