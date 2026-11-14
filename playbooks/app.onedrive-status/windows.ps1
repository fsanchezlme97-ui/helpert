# Revisar OneDrive: si está instalado y abierto para la persona (su proceso, por SID), su versión, las cuentas con
# su carpeta (del registro de la persona), si esa carpeta existe (revisado con su token) y el espacio libre del disco.
# También si la empresa lo desactivó. Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

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
function Valor($ruta, $nombre) {
  try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null }
}
function Existe { $script:existe = [IO.Directory]::Exists($carpeta) }
$existe = $false; $carpeta = ''

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $sid = SidDe $env:HP_USUARIO
      if (-not $sid) { 'No sé qué persona lo pide.'; exit 3 }
      if ((Valor 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC') -eq 1) { 'La empresa desactivó OneDrive en este equipo: si lo necesitas, habla con soporte.'; exit 10 }
      $hku = "Registry::HKEY_USERS\$sid"
      if (-not (Test-Path -LiteralPath $hku)) { 'Necesito que tengas la sesión abierta en este equipo para revisar tu OneDrive.'; exit 3 }
      $tok = Token $sid
      if (-not $tok) { 'Necesito que tengas la sesión abierta en este equipo para revisar tu OneDrive.'; exit 3 }
      $version = Valor "$hku\Software\Microsoft\OneDrive" 'Version'
      if (-not $version) { $version = Valor 'HKLM:\SOFTWARE\Microsoft\OneDrive' 'Version' }
      if (-not $version) { 'OneDrive no está instalado para ti en este equipo. Si lo necesitas, pide a soporte que lo instale.'; exit 10 }
      $abierto = @(Get-CimInstance Win32_Process -Filter "Name='OneDrive.exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $sid }).Count -gt 0
      if ($abierto) { "OneDrive (versión $version) está abierto." } else { "OneDrive (versión $version) está instalado, pero no está abierto: por eso no sincroniza. Ábrelo desde el menú Inicio (busca «OneDrive»)." }
      $cuentas = @(Get-ChildItem -LiteralPath "$hku\Software\Microsoft\OneDrive\Accounts" -ErrorAction SilentlyContinue | Where-Object { Valor $_.PSPath 'UserFolder' })
      if (-not $cuentas.Count) { 'No has iniciado sesión en OneDrive: ábrelo y entra con tu cuenta del trabajo.'; exit 10 }
      $poco = $false
      foreach ($c in $cuentas) {
        $carpeta = "$(Valor $c.PSPath 'UserFolder')"
        $tipo = 'del trabajo'; if ($c.PSChildName -eq 'Personal') { $tipo = 'personal' }
        ComoPersona $tok { Existe }
        if (-not $existe) { "Tu carpeta de OneDrive $tipo ($carpeta) no existe: OneDrive no tiene dónde sincronizar. Pide a soporte que lo vuelva a configurar."; continue }
        $disco = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($carpeta.Substring(0, 2))'" -ErrorAction SilentlyContinue
        $libre = ''; if ($disco -and $disco.Size) {
          $gb = [math]::Round($disco.FreeSpace / 1GB, 1); $libre = " El disco tiene $gb GB libres."
          if ($gb -lt 2) { $poco = $true }
        }
        "Cuenta $tipo $(Valor $c.PSPath 'UserEmail'): tu carpeta es $carpeta.$libre"
      }
      if ($poco) { 'Queda poco espacio en el disco: OneDrive no puede descargar archivos así. Libera espacio o deja archivos «solo en línea».' }
      elseif ($abierto) { 'Si sigue sin sincronizar, haz clic en el ícono de la nube junto al reloj: ahí OneDrive dice qué error tiene.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
