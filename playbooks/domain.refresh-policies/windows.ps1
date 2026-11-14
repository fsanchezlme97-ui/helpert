# Volver a aplicar las políticas del dominio (GPO): las del equipo con gpupdate como SYSTEM, y las de la persona
# (unidades e impresoras asignadas, por ejemplo) con gpupdate en su sesión, mediante una tarea programada como ella
# que se borra al terminar. A gpupdate se le contesta «n» si pregunta por cerrar sesión o reiniciar: no hace ninguna de
# las dos cosas.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$GP = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Extension-List\{00000000-0000-0000-0000-000000000000}'

function Valor($ruta, $nombre) { try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null } }
function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
# con stderr redirigido, Windows PowerShell convierte cada línea en un error y con 'Stop' cortaría el script
function Nativo($exe) { $ErrorActionPreference = 'Continue'; 'n', 'n' | & $exe @args 2>$null | Out-Null; $LASTEXITCODE }
function Equipo { Get-CimInstance Win32_ComputerSystem }
# cuándo terminó la última aplicación de las políticas del equipo
function UltimaVez {
  $hi = Valor $GP 'EndTimeHi'; $lo = Valor $GP 'EndTimeLo'
  if ($null -eq $hi -or $null -eq $lo) { return $null }
  $u = { param($x) [int64][BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$x), 0) }
  [DateTime]::FromFileTime(((& $u $hi) -shl 32) -bor (& $u $lo))
}
function Hace($t) {
  if (-not $t) { return 'nunca, que yo sepa' }
  $m = [int]((Get-Date) - $t).TotalMinutes
  if ($m -lt 120) { "hace $m minuto(s)" } elseif ($m -lt 2880) { "hace $([int]($m / 60)) hora(s)" } else { "hace $([int]($m / 1440)) día(s)" }
}
# la persona es de un dominio (no local ni de Entra ID) y tiene la sesión abierta
function PersonaDeDominio {
  $sid = SidDe $env:HP_USUARIO
  $dom = "$env:HP_USUARIO".Split('\')[0]
  if (-not $sid -or $sid -notlike 'S-1-5-21-*' -or $dom -eq $env:COMPUTERNAME -or $dom -eq 'AzureAD') { return $false }
  @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $sid }).Count -gt 0
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $e = Equipo
      if (-not $e.PartOfDomain) { 'Este equipo no está unido a un dominio de la empresa, así que no recibe políticas de dominio. Si la empresa lo administra por la nube (Intune), las configuraciones llegan solas; si falta algo, avisa a soporte.'; exit 3 }
      "El equipo está unido al dominio $($e.Domain). Las políticas se aplicaron por última vez $(Hace (UltimaVez))."
      'Puedo volver a aplicarlas ahora, las del equipo y las de tu cuenta. No cierro tu sesión ni reinicio.'
      exit 0
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para aplicar las políticas.'; exit 3 }
      $e = Equipo
      if (-not $e.PartOfDomain) { 'Este equipo no está unido a un dominio.'; exit 3 }
      if ((Nativo nltest.exe "/dsgetdc:$($e.Domain)") -ne 0) { 'El equipo no llega a los servidores de la empresa: conéctate a la red de la oficina o a la VPN y vuelve a intentarlo.'; exit 3 }
      exit 0
    }
    'aplicar' {
      if ((Nativo gpupdate.exe /target:computer /force /wait:100) -ne 0) { 'No se pudieron aplicar las políticas del equipo. Soporte puede revisar el motivo.'; exit 1 }
      'Volví a aplicar las políticas del equipo.'
      if (-not (PersonaDeDominio)) { 'Las de tu cuenta no: tu cuenta no es del dominio o no tienes la sesión abierta. Se aplican solas al entrar.'; exit 0 }
      $nombre = "Helpert-gpupdate-$([guid]::NewGuid().ToString('N'))"
      $acc = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument '/c echo n| gpupdate.exe /target:user /force'
      $pri = New-ScheduledTaskPrincipal -UserId $env:HP_USUARIO -LogonType Interactive
      $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
      $res = $null
      Register-ScheduledTask -TaskName $nombre -Action $acc -Principal $pri -Settings $set | Out-Null
      try {
        Start-ScheduledTask -TaskName $nombre
        for ($i = 0; $i -lt 60; $i++) {
          Start-Sleep -Seconds 2
          $inf = Get-ScheduledTaskInfo -TaskName $nombre
          if ((Get-ScheduledTask -TaskName $nombre).State -ne 'Running' -and $inf.LastTaskResult -ne 267011) { $res = $inf.LastTaskResult; break }
        }
      } finally { Unregister-ScheduledTask -TaskName $nombre -Confirm:$false -ErrorAction SilentlyContinue }
      if ($res -ne 0) { 'No pude terminar de aplicar las políticas de tu cuenta; se aplican solas al cerrar y volver a abrir sesión.'; exit 0 }
      'También volví a aplicar las de tu cuenta. Si una unidad o impresora no aparece todavía, cierra sesión y vuelve a entrar.'
      exit 0
    }
    'verificar' {
      $t = UltimaVez
      if (-not $t -or $t -lt (Get-Date).AddMinutes(-15)) { 'Las políticas del equipo no se aplicaron hace poco. Avisa a soporte.'; exit 1 }
      "Las políticas del equipo se aplicaron $(Hace $t)."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
