# Actualizar las firmas de Microsoft Defender (desde el origen que tenga configurado: Windows Update, WSUS de la
# empresa...). No instala ningún antivirus; si el equipo usa otro, solo lo dice.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Estado { try { Get-MpComputerStatus -ErrorAction Stop } catch { $null } }
function Activo($s) { $s -and $s.AntivirusEnabled }
# otro antivirus registrado y activo en el Centro de seguridad (solo existe en Windows de escritorio)
function OtroAV {
  try { $p = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop) } catch { return $null }
  ($p | Where-Object { ($_.productState -band 0x1000) -and $_.displayName -notmatch 'Defender' } | Select-Object -First 1).displayName
}
function NoDefender {
  $o = OtroAV
  if ($o) { "El antivirus de este equipo es «$o». Helpert solo actualiza Microsoft Defender: actualízalo desde ese programa o pide ayuda a soporte." }
  else { 'Microsoft Defender no está activo en este equipo y no encuentro otro antivirus: avisa a soporte.' }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $s = Estado
      if (-not (Activo $s)) { NoDefender; exit 3 }
      $d = $s.AntivirusSignatureAge
      if ($d -lt 1) { "Las firmas de Microsoft Defender están al día (versión $($s.AntivirusSignatureVersion))."; exit 10 }
      "Las firmas de Microsoft Defender tienen $d día(s) (versión $($s.AntivirusSignatureVersion))."
      'Puedo descargar las nuevas ahora.'
      exit 0
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para actualizar el antivirus.'; exit 3 }
      if (-not (Activo (Estado))) { NoDefender; exit 3 }
      exit 0
    }
    'aplicar' {
      try { Update-MpSignature -ErrorAction Stop }
      catch { 'No se pudieron descargar las firmas; puede que no haya internet o que la red de la empresa lo bloquee. Si sigue igual, avisa a soporte.'; exit 1 }
      "Descargué las firmas de Microsoft Defender (versión $((Estado).AntivirusSignatureVersion))."
      exit 0
    }
    'verificar' {
      $s = Estado
      if (-not (Activo $s) -or $s.AntivirusSignatureAge -gt 1) { 'Las firmas de Microsoft Defender siguen desactualizadas.'; exit 1 }
      "Las firmas de Microsoft Defender están al día (versión $($s.AntivirusSignatureVersion))."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
