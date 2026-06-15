[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "Stop"

# Substitua SEU_USUARIO pelo seu usuário do GitHub
$repoUrl = "https://github.com/raulzovisk/SistemaInfo/releases/latest/download/SistemaInfo.exe"
$tempExe = Join-Path $env:TEMP "SistemaInfo_Executavel_Temp.exe"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "    Baixando e Iniciando SistemaInfo    " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

try {
    Write-Host "Baixando o aplicativo do GitHub..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $repoUrl -OutFile $tempExe -UseBasicParsing
}
catch {
    Write-Host "Erro ao baixar o executável." -ForegroundColor Red
    Write-Host "Verifique se você alterou SEU_USUARIO no script run.ps1 e se o arquivo SistemaInfo.exe foi publicado nas Releases do GitHub." -ForegroundColor Red
    Write-Host ""
    Read-Host "Pressione ENTER para fechar"
    exit
}

Write-Host "Executando SistemaInfo..." -ForegroundColor Green
Start-Process -FilePath $tempExe -Wait

Write-Host "Limpando arquivos temporários..." -ForegroundColor Yellow
Remove-Item -Path $tempExe -Force -ErrorAction SilentlyContinue

Write-Host "Concluído!" -ForegroundColor Green

Write-Host ""
Read-Host "Pressione ENTER para fechar"
