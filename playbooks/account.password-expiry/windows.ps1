# Ver cuándo vence la contraseña de la persona. Cuenta local: con ADSI (WinNT), según su antigüedad y la política del
# equipo. Cuenta de dominio: lo calcula el propio dominio (msDS-UserPasswordExpiryTimeComputed), consultado por su SID
# con la cuenta del equipo. Las cuentas de Entra ID no se pueden consultar desde aquí. Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$NUNCA = [int64]::MaxValue
$CI = [Globalization.CultureInfo]::InvariantCulture

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
# fecha de vencimiento: [datetime], 'nunca', 'ya' (debe cambiarla al entrar) o $null si no se pudo consultar
function Local($nombre) {
  $u = [ADSI]"WinNT://$env:COMPUTERNAME/$nombre,user"
  if ($u.UserFlags.Value -band 0x10000) { return 'nunca' }  # «la contraseña nunca vence»
  if ($u.PasswordExpired.Value -eq 1) { return 'ya' }
  $max = [double]$u.MaxPasswordAge.Value; $edad = [double]$u.PasswordAge.Value
  if ($max -le 0 -or $max -ge 4294967295) { return 'nunca' }
  (Get-Date).AddSeconds($max - $edad)
}
function Dominio($sid) {
  try {
    $b = New-Object DirectoryServices.DirectorySearcher
    $b.SearchRoot = [ADSI]"LDAP://<SID=$sid>"
    $b.SearchScope = 'Base'
    [void]$b.PropertiesToLoad.Add('msDS-UserPasswordExpiryTimeComputed')
    $r = $b.FindOne()
  } catch { return $null }
  if (-not $r -or $r.Properties['msds-userpasswordexpirytimecomputed'].Count -eq 0) { return $null }
  $v = [int64]$r.Properties['msds-userpasswordexpirytimecomputed'][0]
  if ($v -eq $NUNCA) { return 'nunca' }
  if ($v -eq 0) { return 'ya' }
  [DateTime]::FromFileTime($v)
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $sid = SidDe $env:HP_USUARIO
      if (-not $sid) { 'No sé qué persona lo pide.'; exit 3 }
      $dom, $nombre = "$env:HP_USUARIO".Split('\', 2)
      if ($sid -like 'S-1-12-1-*' -or $dom -eq 'AzureAD') {
        'Tu cuenta es de Microsoft Entra ID (la nube de la empresa): su vencimiento no se puede ver desde el equipo.'
        'Si te pide cambiarla, hazlo en el portal de tu cuenta de la empresa; si necesitas la fecha, pídela a soporte.'
        exit 10
      }
      if ($dom -eq $env:COMPUTERNAME) { $v = Local $nombre } else { $v = Dominio $sid }
      if ($null -eq $v) { 'No pude consultar al dominio de la empresa: conéctate a la red de la oficina o a la VPN y vuelve a intentarlo.'; exit 1 }
      if ('nunca' -eq $v) { 'Tu contraseña no tiene fecha de vencimiento.'; exit 10 }
      if ('ya' -eq $v) { 'Tienes que cambiar tu contraseña la próxima vez que entres al equipo.'; exit 10 }
      $dias = [int][math]::Floor(($v - (Get-Date)).TotalDays)
      if ($dias -lt 0) { "Tu contraseña venció el $($v.ToString('dd/MM/yyyy', $CI)): el equipo te pedirá cambiarla al entrar."; exit 10 }
      "Tu contraseña vence el $($v.ToString('dd/MM/yyyy', $CI)) a las $($v.ToString('HH:mm', $CI)) (en $dias día(s))."
      if ($dias -le 7) { 'Cámbiala pronto: pulsa Ctrl + Alt + Supr y elige «Cambiar una contraseña».' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
