# Playbook inofensivo para las pruebas: crea y borra un archivo en la carpeta temporal del sistema.
$f = Join-Path $env:TEMP "helpert-prueba-$env:HP_NOMBRE"
switch ($env:HP_PASO) {
    'diagnosticar' { "Se creará $f."; exit 0 }
    'comprobar' { exit 0 }
    'aplicar' { "paso=$env:HP_PASO usuario=$env:HP_USUARIO path=$env:PATH" | Set-Content -Encoding UTF8 $f; "Creé $f."; exit 0 }
    'verificar' { if (Test-Path $f) { "Existe $f."; exit 0 } else { exit 1 } }
    'deshacer' { Remove-Item -Force $f; "Borré $f."; exit 0 }
    default { exit 2 }
}
