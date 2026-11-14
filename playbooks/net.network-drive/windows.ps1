# Reconectar unidades de red: las que Windows recuerda para la persona (HKEY_USERS\<SID>\Network, las de «Conectar a
# unidad de red» con «Volver a conectar al iniciar sesión»). Las unidades son de su sesión, así que se revisan y se
# reconectan en ella, como ella, con una tarea programada (y se borra): un PowerShell oculto con la API de red de Windows
# (WNetGetConnection y WNetRestoreSingleConnection, la que usa el Explorador; sin ventanas ni preguntas). Su código de
# salida dice qué letras siguen sin conectar (bit 0 = A:). Las de las políticas del dominio no están aquí.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$FALLO = 0x4000000  # el PowerShell de la sesión no pudo revisar (p. ej. una política lo limita)

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
$sid = SidDe $env:HP_USUARIO
function Sesion { @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $sid }).Count -gt 0 }
function NoPuedo {
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  if (-not (Sesion)) { return 'Necesito que tengas la sesión abierta en este equipo para revisar tus unidades de red.' }
}
# letra -> carpeta compartida, de lo que Windows recuerda para la persona (se lee del registro, no se toca)
function Unidades {
  $u = [ordered]@{}
  foreach ($k in @(Get-ChildItem -LiteralPath "Registry::HKEY_USERS\$sid\Network" -ErrorAction SilentlyContinue)) {
    $l = "$($k.PSChildName)".ToUpper()
    if ($l -match '^[A-Z]$') { $u[$l] = "$($k.GetValue('RemotePath'))" }
  }
  $u
}
# lo que corre en la sesión de la persona; texto fijo, sin nada que venga de afuera
$EN_SESION = @'
try {
  if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { exit 0x4000000 }
  Add-Type -Namespace Hp -Name Red -MemberDefinition '[DllImport("mpr.dll", CharSet = CharSet.Unicode)] public static extern int WNetGetConnection(string d, System.Text.StringBuilder r, ref int n); [DllImport("mpr.dll", CharSet = CharSet.Unicode)] public static extern int WNetRestoreSingleConnection(IntPtr h, string d, bool ui);'
  function Arriba($d) { $n = 1024; $b = New-Object System.Text.StringBuilder 1024; [Hp.Red]::WNetGetConnection($d, $b, [ref]$n) -eq 0 }
  $m = 0; $fin = (Get-Date).AddSeconds(40)  # cada servidor caído puede tardar; después de 40 s ya no se intenta más
  foreach ($k in @(Get-ChildItem HKCU:\Network -ErrorAction SilentlyContinue)) {
    $l = "$($k.PSChildName)".ToUpper(); if ($l -notmatch '^[A-Z]$') { continue }
    $d = $l + ':'
    if (Arriba $d) { continue }
    if ($CONECTAR -and (Get-Date) -lt $fin) { $null = [Hp.Red]::WNetRestoreSingleConnection([IntPtr]::Zero, $d, $false); if (Arriba $d) { continue } }
    $m = $m -bor (1 -shl ([int][char]$l - 65))
  }
  exit $m
} catch { exit 0x4000000 }
'@
# corre $EN_SESION como la persona; devuelve las letras que siguen caídas (lista, quizá vacía), o $null si no se pudo revisar
function Caidas([bool]$conectar) {
  $codigo = "`$CONECTAR = `$$conectar`n" + $EN_SESION
  $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($codigo))
  $t = 'Helpert-unidades-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $a = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $b64"
  $p = New-ScheduledTaskPrincipal -UserId $env:HP_USUARIO -LogonType Interactive
  $c = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 65) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  $r = $null
  $null = Register-ScheduledTask -TaskName $t -Action $a -Principal $p -Settings $c -Force
  try {
    Start-ScheduledTask -TaskName $t
    for ($i = 0; $i -lt 30; $i++) {
      Start-Sleep -Seconds 2
      $inf = Get-ScheduledTaskInfo -TaskName $t
      if ("$((Get-ScheduledTask -TaskName $t).State)" -notin 'Running', 'Queued' -and $inf.LastTaskResult -ne 267011) { $r = [int64]$inf.LastTaskResult; break }
    }
    if ($null -eq $r) { Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue }
  } finally { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
  # 0x413xx son códigos del programador de tareas (p. ej. 0x41306: se cortó por tiempo), no letras
  $script:tarde = $null -eq $r -or ($r -ge 0x41300 -and $r -le 0x413FF)
  if ($tarde -or $r -lt 0 -or $r -ge $FALLO) { return $null }
  , @(for ($i = 0; $i -lt 26; $i++) { if ($r -band (1 -shl $i)) { [string][char](65 + $i) } })
}
function Texto($letras, $u) { (@($letras | ForEach-Object { "${_}: ($($u[$_]))" }) -join ', ') }
$tarde = $false
function NoSe { if ($tarde) { 'Revisar tus unidades de red tardó demasiado: puede que el servidor no responda o que haga falta la VPN. Vuelve a intentarlo más tarde.' } else { $NOSE } }
$NOSE = 'No pude revisar tus unidades de red en tu sesión (puede que una política de la empresa lo impida). Ábrelas desde el Explorador de archivos; si no conectan, avisa a soporte.'

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      $u = Unidades
      if (-not $u.Count) { 'No tienes unidades de red configuradas en este equipo; soporte tiene que agregarlas.'; exit 1 }
      $c = Caidas $false
      if ($null -eq $c) { NoSe; exit 1 }
      $c = @($c | Where-Object { $u.Contains($_) })
      if (-not $c.Count) { "Todas tus unidades de red están conectadas: $(Texto @($u.Keys) $u)."; exit 10 }
      "Estas unidades de red no están conectadas: $(Texto $c $u)."
      exit 0
    }
    'comprobar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      if (-not (Unidades).Count) { 'No tienes unidades de red configuradas en este equipo.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = NoPuedo; if ($m) { $m; exit 1 }
      $c = Caidas $true
      if ($null -eq $c) { NoSe; exit 1 }
      'Volví a conectar tus unidades de red.'
      exit 0
    }
    'verificar' {
      $m = NoPuedo; if ($m) { $m; exit 1 }
      $u = Unidades
      $c = Caidas $false
      if ($null -eq $c) { NoSe; exit 1 }
      $c = @($c | Where-Object { $u.Contains($_) })
      if ($c.Count) { "No se pudieron conectar: $(Texto $c $u). Puede que el servidor no responda o que haga falta la VPN."; exit 1 }
      'Todas tus unidades de red están conectadas.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
