# Revisar si el disco del sistema está cifrado con BitLocker, si el arranque seguro está activo y si el chip TPM
# está listo. Solo lectura: termina con 10. Activar el cifrado lo hace soporte.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Valor($ruta, $nombre) { try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null } }
# una línea por protección; las que faltan empiezan con «- !»
function Revisar {
  $v = $null
  try { $v = Get-CimInstance -Namespace root/cimv2/Security/MicrosoftVolumeEncryption -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop } catch { }
  if (-not $v) { '- !Disco del sistema: sin BitLocker (esta edición de Windows no lo tiene o no pude revisarlo).' }
  elseif ($v.ProtectionStatus -eq 1) { '- Disco del sistema: cifrado con BitLocker y protegido.' }
  elseif ($v.ConversionStatus -eq 2) { '- Disco del sistema: se está cifrando con BitLocker ahora.' }
  elseif ($v.ConversionStatus -eq 1 -or $v.ConversionStatus -eq 4) { '- !Disco del sistema: cifrado con BitLocker, pero la protección está suspendida.' }
  else { '- !Disco del sistema: sin cifrar.' }

  $sb = Valor 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
  if ($sb -eq 1) { '- Arranque seguro: activo.' }
  elseif ($sb -eq 0) { '- !Arranque seguro: apagado.' }
  else { '- !Arranque seguro: no tiene (el equipo arranca en modo antiguo, BIOS).' }

  $t = $null
  try { $t = Get-CimInstance -Namespace root/cimv2/Security/MicrosoftTpm -ClassName Win32_Tpm -ErrorAction Stop } catch { }
  if (-not $t) { '- !Chip TPM: no se detecta (puede estar apagado en la configuración del equipo).' }
  elseif ($t.IsEnabled_InitialValue -and $t.IsActivated_InitialValue) { "- Chip TPM: activo (versión $(("$($t.SpecVersion)" -split ',')[0].Trim()))." }
  else { '- !Chip TPM: presente, pero apagado o sin activar.' }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $r = @(Revisar)
      $n = @($r | Where-Object { $_ -like '- !*' }).Count
      if ($n -eq 0) { 'El equipo tiene activas las protecciones que pude revisar.' } else { "Al equipo le faltan $n protección(es) de seguridad." }
      $r | ForEach-Object { $_ -replace '^- !', '- ' }
      if ($n) { 'Activar el cifrado, el arranque seguro o el TPM lo hace soporte.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
