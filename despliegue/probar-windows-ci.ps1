# Prueba de punta a punta en Windows (la corre la CI en windows-latest, como administrador): servidor con el
# PostgreSQL del runner, el agente instalado como servicio de verdad (SYSTEM) y una consulta por la tubería desde
# este usuario con «helpert --estado». Usa una clave de firma de un solo uso; nada de esto es de producción.
$ErrorActionPreference = 'Stop'
$raiz = Resolve-Path "$PSScriptRoot\.."
$t = Join-Path $env:RUNNER_TEMP 'helpert'
New-Item -ItemType Directory -Force $t | Out-Null
function srv { & uv run -q --project "$raiz\server" helpert-server @args; if ($LASTEXITCODE) { throw "helpert-server $args" } }

$pg = Get-Service postgresql* | Select-Object -First 1
Set-Service $pg.Name -StartupType Manual; Start-Service $pg.Name
$env:PGPASSWORD = 'root'
& "$env:PGBIN\createdb.exe" -U postgres helpert_ci
srv claves "$t\claves"
Copy-Item -Recurse "$raiz\pruebas\playbooks" "$t\pb"
srv firmar "$t\pb" --clave "$t\claves\playbooks.key"
$cfg = "$t\helpert-server.toml"
Set-Content $cfg "base_datos = `"postgresql://postgres:root@localhost/helpert_ci`"`nplaybooks = '$t\pb'`n[[ia]]`nproveedor = `"ollama`"`nmodelo = `"x`"`nurl = `"http://127.0.0.1:9`"`n"
$token = (srv --config $cfg equipo-nuevo ci-windows | Select-Object -Last 1).Trim()
$s = Start-Process uv -ArgumentList 'run', '-q', '--project', "$raiz\server", 'helpert-server', '--config', $cfg, 'servir', '--puerto', '8765' `
    -RedirectStandardError "$t\servidor.log" -PassThru -WindowStyle Hidden
for ($i = 0; $i -lt 60 -and -not (Test-NetConnection 127.0.0.1 -Port 8765 -InformationLevel Quiet -WarningAction SilentlyContinue); $i++) { Start-Sleep 1 }

$datos = "$env:ProgramData\Helpert"
New-Item -ItemType Directory -Force $datos | Out-Null
Set-Content "$datos\agente.toml" "servidor = `"http://127.0.0.1:8765`"`ntoken = `"$token`"`nplaybooks = '$t\pb'`nclave_publica = '$t\claves\playbooks.pub'`n"
$bin = "$raiz\agente\target\release"
New-Service -Name helpert-agente -BinaryPathName "`"$bin\helpert-agente.exe`" --servicio" -StartupType Manual | Out-Null
Start-Service helpert-agente
try {
    Start-Sleep 3
    if ((Get-Service helpert-agente).Status -ne 'Running') { throw 'el servicio no quedó en marcha' }
    $acl = (Get-Acl $datos).Access | ForEach-Object { "$($_.IdentityReference)" }
    if ($acl | Where-Object { $_ -notmatch 'SYSTEM|Administra' }) { throw "la carpeta de datos tiene otros permisos: $acl" }
    $r = & "$bin\helpert.exe" --estado
    Write-Host "helpert --estado: $r"
    if ($LASTEXITCODE) { throw 'la consulta por la tubería falló' }
    Write-Host 'Servicio, tubería y servidor: bien.'
} catch {
    Get-Content "$datos\agente.log" -ErrorAction SilentlyContinue | Write-Host
    Get-Content "$t\servidor.log" -Tail 30 -ErrorAction SilentlyContinue | Write-Host
    throw
} finally {
    Stop-Service helpert-agente -ErrorAction SilentlyContinue
    sc.exe delete helpert-agente | Out-Null
    Stop-Process -Id $s.Id -Force -ErrorAction SilentlyContinue
}
