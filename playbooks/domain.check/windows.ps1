# Revisar la unión con el dominio: si el equipo sigue unido, si encuentra un controlador de dominio (nltest) y si la
# relación de confianza funciona (Test-ComputerSecureChannel, sin repararla). Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

# con stderr redirigido, Windows PowerShell convierte cada línea en un error y con 'Stop' cortaría el script
function Nativo($exe) { $ErrorActionPreference = 'Continue'; & $exe @args 2>$null }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $e = Get-CimInstance Win32_ComputerSystem
      if (-not $e.PartOfDomain) {
        if ("$(Nativo dsregcmd.exe /status)" -match 'AzureAdJoined\s*:\s*YES') { 'Este equipo no está unido a un dominio local: está unido a Microsoft Entra ID (la nube de la empresa). Si tu cuenta no entra, avisa a soporte.' }
        else { 'Este equipo no está unido a ningún dominio de la empresa. Si debería estarlo, avisa a soporte para que lo una.' }
        exit 10
      }
      $dom = $e.Domain
      $o = "$(Nativo nltest.exe "/dsgetdc:$dom")"
      if ($LASTEXITCODE -ne 0) {
        "El equipo está unido al dominio $dom, pero no encuentra sus servidores."
        'Conéctate a la red de la oficina o a la VPN y vuelve a intentarlo. Si ya lo estás, avisa a soporte.'
        exit 10
      }
      $dc = ''; if ($o -match 'DC: \\\\(\S+)') { $dc = " ($($Matches[1]))" }
      $ok = $null; try { $ok = Test-ComputerSecureChannel -ErrorAction Stop } catch { }
      if ($ok -eq $false) {
        "El equipo está unido al dominio $dom y llega a su servidor$dc, pero la relación de confianza está rota."
        'Por eso tu cuenta de la empresa no entra. Soporte tiene que repararla; mientras tanto, puedes entrar con una cuenta local si tienes una.'
        exit 10
      }
      if ($null -eq $ok) { "El equipo está unido al dominio $dom y llega a su servidor$dc, pero no pude comprobar la relación de confianza. Si tu cuenta no entra, avisa a soporte."; exit 10 }
      "El equipo sigue unido al dominio $dom, llega a su servidor$dc y la relación de confianza funciona."
      'Si tu cuenta no entra, puede ser la contraseña o un bloqueo de la cuenta: revísalo con soporte.'
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
