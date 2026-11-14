# Análisis rápido con Microsoft Defender y lo que encontró. Helpert no borra ni mueve archivos: si Defender
# encuentra una amenaza, aplica su acción habitual (normalmente la aísla en cuarentena, de donde soporte la puede sacar).
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$ACCION = @{ 1 = 'detectada, sin resolver'; 2 = 'limpiada'; 3 = 'aislada en cuarentena'; 4 = 'eliminada'; 5 = 'permitida'
  6 = 'bloqueada'; 102 = 'no se pudo aislar'; 103 = 'no se pudo eliminar'; 105 = 'sin resolver'; 107 = 'no se pudo bloquear' }

function Estado { try { Get-MpComputerStatus -ErrorAction Stop } catch { $null } }
function Activo($s) { $s -and $s.AntivirusEnabled }
function OtroAV {
  try { $p = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop) } catch { return $null }
  ($p | Where-Object { ($_.productState -band 0x1000) -and $_.displayName -notmatch 'Defender' } | Select-Object -First 1).displayName
}
function NoDefender {
  $o = OtroAV
  if ($o) { "El antivirus de este equipo es «$o». Helpert solo sabe analizar con Microsoft Defender: haz el análisis desde ese programa o pide ayuda a soporte." }
  else { 'Microsoft Defender no está activo en este equipo y no encuentro otro antivirus: avisa a soporte.' }
}
function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

# nombre del archivo de un recurso de Defender («file:_C:\...\a.zip->b.exe», «webfile:_C:\...\a.exe|https://...»)
function Archivo($r) { ((("$r" -replace '^[A-Za-z]+:_', '') -split '\||->')[0] -split '\\')[-1] }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $s = Estado
      if (-not (Activo $s)) { NoDefender; exit 3 }
      'Puedo hacer un análisis rápido con Microsoft Defender: revisa los lugares donde suelen esconderse los virus y tarda unos minutos.'
      if ($s.QuickScanAge -lt 1000) { "El último análisis rápido fue hace $($s.QuickScanAge) día(s)." }
      'Helpert no borra archivos: si aparece algo, Defender lo aísla y te digo qué fue.'
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para analizar el equipo.'; exit 3 }
      if (-not (Activo (Estado))) { NoDefender; exit 3 }
      exit 0
    }
    'aplicar' {
      $inicio = (Get-Date).AddMinutes(-1)
      try { Start-MpScan -ScanType QuickScan -ErrorAction Stop }
      catch { 'Defender no pudo hacer el análisis (puede que ya haya otro en curso). Inténtalo de nuevo en unos minutos.'; exit 1 }
      $det = @(try { Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.InitialDetectionTime -ge $inicio } } catch { })
      if ($det.Count -eq 0) { 'El análisis rápido terminó y Microsoft Defender no encontró nada peligroso.'; exit 0 }
      $nombres = @{}
      foreach ($t in @(try { Get-MpThreat -ErrorAction Stop } catch { })) { $nombres["$($t.ThreatID)"] = $t.ThreatName }
      "Microsoft Defender encontró $($det.Count) amenaza(s):"
      foreach ($d in ($det | Select-Object -First 5)) {
        $archivo = Archivo (@($d.Resources)[0])
        $que = $ACCION[[int]$d.ThreatStatusID]; if (-not $que) { $que = 'sin datos de qué hizo' }
        "- $($nombres["$($d.ThreatID)"])$(if ($archivo) { " en «$archivo»" }): $que."
      }
      'No abras esos archivos. Si falta un archivo tuyo que necesitas, soporte decide si se puede recuperar.'
      exit 0
    }
    'verificar' {
      $act = @(try { Get-MpThreat -ErrorAction Stop | Where-Object { $_.IsActive } } catch { })
      if ($act.Count) { "Quedan $($act.Count) amenaza(s) sin resolver: avisa a soporte."; exit 1 }
      'El análisis terminó y no quedan amenazas activas.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
