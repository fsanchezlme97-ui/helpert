# Instala (o desinstala) Helpert en un equipo Windows 10/11: servicio del equipo (SYSTEM) y bandeja (cada usuario).
# Va dentro del paquete que arma despliegue/empaquetar-windows.sh, junto a «Instalar Helpert.cmd» (doble clic).
#   powershell -ExecutionPolicy Bypass -File instalar.ps1                # pide permiso de administrador si hace falta
#   powershell -ExecutionPolicy Bypass -File instalar.ps1 -Silencioso    # despliegue masivo (GPO, Intune): sin ventanas
#   powershell -ExecutionPolicy Bypass -File instalar.ps1 -Desinstalar
# Al reinstalar se conserva el token del equipo. La clave de inscripción se lee de un archivo, nunca de la línea de órdenes.
param([switch]$Silencioso, [switch]$Desinstalar)
$ErrorActionPreference = 'Stop'
$Paquete = $PSScriptRoot
$Programa = Join-Path $env:ProgramFiles 'Helpert'
$Datos = Join-Path $env:ProgramData 'Helpert'
$Servicio = 'helpert-agente'
$Inicio = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
$Acceso = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Helpert.lnk'

function Avisar($texto, [switch]$Error) {
    Write-Host $texto
    if (-not $Silencioso) {
        Add-Type -AssemblyName System.Windows.Forms
        $icono = if ($Error) { 'Error' } else { 'Information' }
        [void][System.Windows.Forms.MessageBox]::Show($texto, 'Helpert', 'OK', $icono)
    }
}

# Administrador: si no lo es, se vuelve a abrir con la ventana de permiso de Windows (UAC).
$yo = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $args_ = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Silencioso) { $args_ += '-Silencioso' }
    if ($Desinstalar) { $args_ += '-Desinstalar' }
    try { $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $args_ -Wait -PassThru; exit $p.ExitCode }
    catch { Avisar 'Helpert necesita permiso de administrador para instalarse.' -Error; exit 1 }
}

function Detener {
    if (Get-Service $Servicio -ErrorAction SilentlyContinue) {
        Stop-Service $Servicio -Force -ErrorAction SilentlyContinue
        (Get-Service $Servicio).WaitForStatus('Stopped', '00:00:20')
    }
    Get-Process helpert-bandeja -ErrorAction SilentlyContinue | Stop-Process -Force
}

# Borra una carpeta sin seguir enlaces de dentro (rmdir /s no entra en uniones ni enlaces simbólicos).
function Borrar($ruta) {
    if (Test-Path -LiteralPath $ruta) { cmd.exe /c rmdir /s /q "`"$ruta`"" | Out-Null }
}

try {
    if ($Desinstalar) {
        Detener
        if (Get-Service $Servicio -ErrorAction SilentlyContinue) { sc.exe delete $Servicio | Out-Null }
        Remove-ItemProperty -Path $Inicio -Name 'Helpert' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Acceso -Force -ErrorAction SilentlyContinue
        Borrar $Programa
        Borrar $Datos
        Avisar 'Helpert se desinstaló de este equipo.'
        exit 0
    }

    foreach ($f in 'bin\helpert-agente.exe', 'bin\helpert.exe', 'bin\helpert-bandeja.exe', 'playbooks.pub', 'servidor.txt') {
        if (-not (Test-Path -LiteralPath (Join-Path $Paquete $f))) { throw "Al paquete le falta $f." }
    }
    if (-not (Get-ChildItem (Join-Path $Paquete 'playbooks') -Filter firma.ed25519 -Recurse)) { throw 'Los playbooks del paquete no están firmados.' }
    $servidor = (Get-Content -LiteralPath (Join-Path $Paquete 'servidor.txt') -TotalCount 1).Trim()
    if ($servidor -notmatch '^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$') { throw "Servidor no válido: $servidor (debe ser https://)" }
    $servidor = $servidor.TrimEnd('/')
    # archivos descargados de internet: sin la marca que hace que Windows pregunte al abrirlos
    Get-ChildItem -LiteralPath $Paquete -Recurse -File | Unblock-File

    # WebView2 (el motor de la ventana de chat): viene con Windows 11 y con Edge; si falta, se instala.
    $wv = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    if (-not (Get-ItemProperty $wv -Name pv -ErrorAction SilentlyContinue)) {
        Write-Host 'Instalando WebView2...'
        $wvexe = Join-Path $env:TEMP 'MicrosoftEdgeWebview2Setup.exe'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $wvexe -UseBasicParsing
        Start-Process $wvexe -ArgumentList '/silent', '/install' -Wait
        Remove-Item $wvexe -Force
    }

    # Carpeta de datos (configuración con el token, registro, temporales de los scripts): solo SYSTEM y Administradores.
    # ProgramData deja a cualquier usuario crear carpetas; si alguien la creó antes (no es de un administrador) o es un
    # enlace, se borra y se crea de nuevo, ya con sus permisos (sin herencia, en la misma llamada).
    $token = $null
    $item = Get-Item -LiteralPath $Datos -Force -ErrorAction SilentlyContinue
    if ($item) {
        $dueno = (Get-Acl -LiteralPath $Datos).Owner
        $confiable = -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
                     ($dueno -eq 'NT AUTHORITY\SYSTEM' -or $dueno -eq 'BUILTIN\Administrators' -or
                      (New-Object Security.Principal.NTAccount($dueno)).Translate([Security.Principal.SecurityIdentifier]).Value -in 'S-1-5-18', 'S-1-5-32-544')
        $cfg = Join-Path $Datos 'agente.toml'
        if ($confiable -and (Test-Path -LiteralPath $cfg)) {
            $linea = Select-String -LiteralPath $cfg -Pattern '^token = "([A-Za-z0-9_-]+)"$' | Select-Object -First 1
            if ($linea) { $token = $linea.Matches[0].Groups[1].Value }  # reinstalación: el equipo sigue siendo el mismo
        }
    }
    Detener
    if ($item -and -not $confiable) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($Datos) } else { Borrar $Datos }
    }
    $seguridad = New-Object Security.AccessControl.DirectorySecurity
    $seguridad.SetSecurityDescriptorSddlForm('D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    if (Test-Path -LiteralPath $Datos) { Set-Acl -LiteralPath $Datos -AclObject $seguridad }
    else { [void][IO.Directory]::CreateDirectory($Datos, $seguridad) }

    # Token del equipo: el que ya tenía o uno nuevo con la clave de inscripción (va en el cuerpo, no en la línea de órdenes).
    if (-not $token) {
        $f = Join-Path $Paquete 'inscripcion'
        if (-not (Test-Path -LiteralPath $f)) { throw 'Falta la clave de inscripción del paquete.' }
        $clave = (Get-Content -LiteralPath $f -Raw).Trim()
        if ($clave -notmatch '^[A-Za-z0-9_-]+$') { throw 'Clave de inscripción no válida.' }
        $nombre = ($env:COMPUTERNAME -replace '[^A-Za-z0-9._-]', '-')
        if ($nombre.Length -gt 64) { $nombre = $nombre.Substring(0, 64) }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $cuerpo = @{ nombre = $nombre; clave = $clave } | ConvertTo-Json
        try { $r = Invoke-RestMethod -Method Post -Uri "$servidor/v1/inscribir" -Body $cuerpo -ContentType 'application/json' -TimeoutSec 30 }
        catch { throw "No pude registrar el equipo en $servidor ($($_.Exception.Message))." }
        $token = [string]$r.token
        if ($token -notmatch '^[A-Za-z0-9_-]+$') { throw 'El servidor no devolvió un token válido.' }
    }

    # Programa: Program Files (solo administradores pueden cambiarlo); los playbooks se reemplazan enteros.
    New-Item -ItemType Directory -Force -Path $Programa | Out-Null
    Copy-Item -Force (Join-Path $Paquete 'bin\*.exe') $Programa
    Borrar (Join-Path $Programa 'playbooks')
    Copy-Item -Recurse (Join-Path $Paquete 'playbooks') (Join-Path $Programa 'playbooks')
    Copy-Item -Force (Join-Path $Paquete 'playbooks.pub') $Programa

    $cfg = Join-Path $Datos 'agente.toml'
    Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue  # archivo nuevo, con los permisos de la carpeta
    $toml = "servidor = `"$servidor`"`r`ntoken = `"$token`"`r`nplaybooks = '$Programa\playbooks'`r`nclave_publica = '$Programa\playbooks.pub'`r`n"
    [IO.File]::WriteAllText($cfg, $toml, (New-Object Text.UTF8Encoding $false))

    # Servicio: arranca con Windows y vuelve a arrancar si se cae o tras actualizarse (sale con código 75).
    $bin = "`"$Programa\helpert-agente.exe`" --servicio"
    if (Get-Service $Servicio -ErrorAction SilentlyContinue) { sc.exe config $Servicio binPath= $bin start= auto | Out-Null }
    else { New-Service -Name $Servicio -BinaryPathName $bin -DisplayName 'Helpert · agente del equipo' -StartupType Automatic -Description 'Soporte TI de Helpert: diagnostica y aplica los pasos que confirmas en el chat.' | Out-Null }
    sc.exe failure $Servicio reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null
    sc.exe failureflag $Servicio 1 | Out-Null
    Start-Service $Servicio
    Start-Sleep -Seconds 2
    if ((Get-Service $Servicio).Status -ne 'Running') {
        $log = Join-Path $Datos 'agente.log'
        $detalle = if (Test-Path $log) { (Get-Content $log -Tail 5) -join "`n" } else { '' }
        throw "El servicio de Helpert no arrancó.`n$detalle"
    }

    # Bandeja: arranca al iniciar sesión cada usuario y está en el menú Inicio.
    New-ItemProperty -Path $Inicio -Name 'Helpert' -Value "`"$Programa\helpert-bandeja.exe`"" -PropertyType String -Force | Out-Null
    $acceso = (New-Object -ComObject WScript.Shell).CreateShortcut($Acceso)
    $acceso.TargetPath = "$Programa\helpert-bandeja.exe"
    $acceso.Arguments = '--abrir'
    $acceso.Description = 'Soporte TI: cuéntale qué le pasa a tu equipo'
    $acceso.Save()
    # abrirla ya para quien instaló, como usuario normal (explorer.exe la lanza sin los permisos de administrador)
    if (-not $Silencioso) { Start-Process explorer.exe "`"$Programa\helpert-bandeja.exe`"" }

    Avisar 'Helpert quedó instalado. Lo verás junto al reloj, en la barra de tareas: haz clic en su icono y cuéntale qué le pasa a tu equipo.'
    exit 0
} catch {
    Avisar "No se pudo instalar Helpert: $($_.Exception.Message)" -Error
    exit 1
}
