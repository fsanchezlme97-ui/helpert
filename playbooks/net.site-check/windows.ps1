# Probar si un sitio o sistema responde: el nombre (DNS), la conexión al puerto 443 (y, si no, al 80) y el certificado
# (TLS 1.2, con la validación de Windows). Prueba directa, sin el proxy de la persona. Solo revisa: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$sitio = "$env:HP_SITIO".ToLower().Trim('.')

# conexión TCP abierta con el sitio, o $null si no conecta en 8 s
function Conectar($puerto) {
  $c = New-Object Net.Sockets.TcpClient
  try {
    $a = $c.BeginConnect($sitio, $puerto, $null, $null)
    if ($a.AsyncWaitHandle.WaitOne(8000)) { $c.EndConnect($a); $c.ReceiveTimeout = 8000; $c.SendTimeout = 8000; return $c }
  } catch { }
  $c.Close(); $null
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if (-not $sitio -or $sitio.StartsWith('-') -or $sitio.Contains('..')) { 'Necesito la dirección del sitio, por ejemplo intranet.empresa.pe.'; exit 1 }
      $ips = @(try { [Net.Dns]::GetHostAddresses($sitio) | ForEach-Object { "$_" } | Select-Object -Unique -First 3 } catch { })
      if ($ips.Count -eq 0) {
        "Falla el nombre: el equipo no encuentra la dirección de $sitio."
        'Revisa que esté bien escrito. Si es un sistema de la empresa, puede que solo funcione en la red de la oficina o con la VPN.'
        exit 10
      }
      $direccion = "Dirección de ${sitio}: $($ips -join ' ')."
      $c = Conectar 443
      if (-not $c) {
        $h = Conectar 80
        if ($h) { $h.Close(); "$sitio responde solo sin cifrado (http://$sitio), no por https: prueba esa dirección." }
        else {
          "Falla la conexión: el nombre se encuentra, pero el equipo no logra conectarse con $sitio."
          'Puede estar caído o bloqueado por un firewall; si es de la empresa, quizás necesitas la VPN. Si sigue así, avisa a soporte.'
        }
        $direccion; exit 10
      }
      # la validación de Windows: se anota el resultado y se deja seguir para poder ver el certificado
      $script:errores = $null; $script:cert = $null
      $cb = [Net.Security.RemoteCertificateValidationCallback] { param($o, $ce, $ch, $er) $script:errores = $er; $script:cert = $ce; $true }
      $ssl = New-Object Net.Security.SslStream($c.GetStream(), $false, $cb)
      $tls = $true
      try { $ssl.AuthenticateAsClient($sitio, $null, [Security.Authentication.SslProtocols]::Tls12, $false) } catch { $tls = $false }
      $ssl.Close(); $c.Close()
      if (-not $script:cert) {
        if ($tls) { "$sitio responde, pero no presenta certificado." }
        else { "Falla la conexión segura: $sitio acepta la conexión, pero no completa el cifrado (https). Puede que no sea una página web o que use un cifrado antiguo: avisa a soporte." }
      } elseif ("$script:errores" -eq 'None') {
        "$sitio responde bien: el nombre, la conexión y el certificado están correctos."
        'Si no abre en tu navegador, prueba «Limpiar la caché de nombres» o «Revisar el proxy del equipo».'
      } else {
        $x = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $script:cert
        if ($x.NotAfter -lt (Get-Date)) {
          "Falla el certificado: el de $sitio venció el $($x.NotAfter.ToString('dd/MM/yyyy')). Lo tiene que renovar quien administra el sitio; avisa a soporte."
        } else {
          "Falla el certificado: el de $sitio no es de confianza para este equipo o no corresponde a esa dirección."
          'Si es un sistema de la empresa, puede que falte instalar su certificado: lo revisa soporte.'
        }
      }
      $direccion
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
