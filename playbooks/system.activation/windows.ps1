# Revisar la activación de Windows (SoftwareLicensingProduct de WMI, sin leer textos de slmgr que cambian con el
# idioma). Solo lectura: termina con 10. Activar Windows lo hace soporte.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$WINDOWS = '55c92734-d682-4d71-983e-d6ec3f16059f'  # ApplicationID de Windows (Office y otros tienen otro)

function Licencia {
  $p = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$WINDOWS' AND PartialProductKey IS NOT NULL" `
      -Property Name, Description, LicenseStatus, LicenseStatusReason, GracePeriodRemaining, LicenseIsAddon)
  @($p | Where-Object { -not $_.LicenseIsAddon })[0]  # los complementos (p. ej. actualizaciones extendidas) no son la licencia de Windows
}
function Tipo($d) {
  if ($d -match 'TIMEBASED_EVAL') { return 'una versión de evaluación' }
  if ($d -match 'VOLUME_KMS') { return 'una licencia de la empresa (se renueva sola en la red de la empresa)' }
  if ($d -match 'VOLUME_MAK') { return 'una licencia de la empresa' }
  if ($d -match 'OEM') { return 'la licencia que vino con el equipo' }
  if ($d -match 'RETAIL') { return 'una licencia comprada aparte' }
  'una licencia'
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $so = (Get-CimInstance Win32_OperatingSystem).Caption
      $l = Licencia
      if (-not $l) { "$so no tiene una clave de producto instalada, así que no está activado. Pide a soporte que lo active."; exit 10 }
      $dias = [int]([math]::Floor($l.GracePeriodRemaining / 1440))
      $tipo = Tipo "$($l.Description)"
      $codigo = '0x{0:X8}' -f [uint32]$l.LicenseStatusReason
      switch ([int]$l.LicenseStatus) {
        1 {
          "$so está activado, con $tipo."
          if ($l.Description -match 'TIMEBASED_EVAL' -and $dias -gt 0) { "Esa versión de evaluación vence en $dias día(s): habla con soporte antes de esa fecha." }
          elseif ($l.Description -match 'VOLUME_KMS' -and $dias -gt 0 -and $dias -lt 30) {
            "Tiene que renovar la activación en los próximos $dias día(s): conéctate a la red de la empresa (o a la VPN) un rato."
          }
        }
        { 2, 3, 4, 6 -contains $_ } {
          "$so todavía no está activado: le quedan $dias día(s) de gracia."
          if ($_ -eq 3) { 'Puede deberse a un cambio de piezas del equipo (placa, disco).' }
          "Pide a soporte que lo active (código $codigo)."
        }
        default {
          "$so no está activado: por eso aparece la marca de agua «Activar Windows»."
          if ($l.Description -match 'VOLUME_KMS') { 'Se activa solo conectado a la red de la empresa: conéctate a ella (o a la VPN) y reinicia el equipo.' }
          "Si sigue igual, pide a soporte que lo active (código $codigo)."
        }
      }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
