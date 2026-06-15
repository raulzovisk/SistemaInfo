[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "Stop"

# Carregar Assemblies Necessários
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Carregar assinaturas Win32 P/Invoke
try {
    [Win32Functions.Win32] | Out-Null
}
catch {
    $Signature = @"
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
"@
    Add-Type -MemberDefinition $Signature -Name "Win32" -Namespace "Win32Functions"
}

# Inicializar configurações do sistema
[Win32Functions.Win32]::SetProcessDPIAware() | Out-Null

$SaveDir = Join-Path ([System.Environment]::GetFolderPath("UserProfile")) "Downloads\PrintsSistema"
[System.IO.Directory]::CreateDirectory($SaveDir) | Out-Null

# --- Funções Auxiliares de Captura e Janelas ---

function Capture-Screen ($rect) {
    if ($rect) {
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        $left = $rect.Left
        $top = $rect.Top
    }
    else {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $width = $screen.Width
        $height = $screen.Height
        $left = $screen.X
        $top = $screen.Y
    }
    
    $bmp = New-Object System.Drawing.Bitmap $width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
    $g.Dispose()
    return $bmp
}

function Get-BmpHash ($bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $ms.ToArray()
    $ms.Dispose()
    
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hashBytes = $md5.ComputeHash($bytes)
    $md5.Dispose()
    
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $hashBytes) {
        $sb.Append($b.ToString("X2")) | Out-Null
    }
    return $sb.ToString()
}

function Wait-Stable ($hwnd = [IntPtr]::Zero, $interval = 0.8, $confirm = 3, $timeoutSec = 120) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Aguardando tela estabilizar..." -ForegroundColor Gray
    $start = [DateTime]::UtcNow
    $prev = $null
    $equals = 0
    
    while (([DateTime]::UtcNow - $start).TotalSeconds -lt $timeoutSec) {
        $rect = $null
        if ($hwnd -ne [IntPtr]::Zero) {
            $r = New-Object Win32Functions.Win32+RECT
            if ([Win32Functions.Win32]::GetWindowRect($hwnd, [ref]$r)) {
                $rect = $r
            }
        }
        
        $bmp = Capture-Screen $rect
        $h = Get-BmpHash $bmp
        $bmp.Dispose()
        
        if ($h -eq $prev) {
            $equals++
            if ($equals -ge $confirm) {
                $diff = ([DateTime]::UtcNow - $start).TotalSeconds
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Tela estabilizou apos $($diff.ToString('F1'))s." -ForegroundColor Gray
                return
            }
        }
        else {
            $equals = 0
        }
        $prev = $h
        Start-Sleep -Milliseconds ($interval * 1000)
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Timeout ao aguardar estabilizacao, prosseguindo." -ForegroundColor Yellow
}

function Take-Screenshot ($name) {
    $path = Join-Path $SaveDir "$name.png"
    $bmp = Capture-Screen
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Print salvo: $path" -ForegroundColor Gray
    return $path
}

function Wait-Window ($titles, $timeoutSec = 60) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Aguardando janelas: $($titles -join ', ')..." -ForegroundColor Gray
    $start = [DateTime]::UtcNow
    
    while (([DateTime]::UtcNow - $start).TotalSeconds -lt $timeoutSec) {
        $procs = [System.Diagnostics.Process]::GetProcesses()
        foreach ($proc in $procs) {
            try {
                if ($proc.MainWindowHandle -eq [IntPtr]::Zero) { continue }
                if (-not [Win32Functions.Win32]::IsWindowVisible($proc.MainWindowHandle)) { continue }
                foreach ($t in $titles) {
                    if ($proc.MainWindowTitle.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Janela '$($proc.MainWindowTitle)' encontrada." -ForegroundColor Gray
                        return $proc.MainWindowHandle
                    }
                }
            }
            catch {}
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Nenhuma janela [$($titles -join '/')] encontrada apos $timeoutSec s."
}

function Close-Window ($hwnd, $proc = $null) {
    if ($hwnd -ne [IntPtr]::Zero) {
        [Win32Functions.Win32]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    }
    if ($proc -and -not $proc.HasExited) {
        try { $proc.Kill() } catch {}
    }
    Start-Sleep -Milliseconds 500
}

# --- Definição das Tarefas ---

function Task-MsInfo {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Abrindo MSINFO..." -ForegroundColor Gray
    $proc = [System.Diagnostics.Process]::Start("msinfo32.exe")
    $hwnd = Wait-Window @("Informações do Sistema", "System Information")
    [Win32Functions.Win32]::ShowWindow($hwnd, 3) | Out-Null # SW_MAXIMIZE
    Wait-Stable $hwnd
    Take-Screenshot "INFO"
    Close-Window $hwnd $proc
}

function Task-AtivacaoWindows {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Abrindo Configuracoes de Ativacao..." -ForegroundColor Gray
    [System.Diagnostics.Process]::Start("explorer.exe", "ms-settings:activation") | Out-Null
    $hwndSettings = Wait-Window @("Configurações", "Settings")
    [Win32Functions.Win32]::ShowWindow($hwndSettings, 3) | Out-Null # SW_MAXIMIZE
    Wait-Stable $hwndSettings
    
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Rodando slmgr /dli..." -ForegroundColor Gray
    $psi = New-Object System.Diagnostics.ProcessStartInfo "wscript.exe", "C:\Windows\System32\slmgr.vbs /dli"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $procDli = [System.Diagnostics.Process]::Start($psi)
    
    $hwndDli = Wait-Window @("Windows Script Host") 120
    Wait-Stable $hwndDli 0.5 2
    Take-Screenshot "WIN 1"
    Close-Window $hwndDli $procDli
    
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Rodando slmgr /xpr..." -ForegroundColor Gray
    $psi = New-Object System.Diagnostics.ProcessStartInfo "wscript.exe", "C:\Windows\System32\slmgr.vbs /xpr"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $procXpr = [System.Diagnostics.Process]::Start($psi)
    
    $hwndXpr = Wait-Window @("Windows Script Host") 120
    Wait-Stable $hwndXpr 0.5 2
    Take-Screenshot "WIN 2"
    Close-Window $hwndXpr $procXpr
    
    Close-Window $hwndSettings
}

function Task-GetMac {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Abrindo CMD para getmac /v..." -ForegroundColor Gray
    $psi = New-Object System.Diagnostics.ProcessStartInfo "cmd.exe", "/c title GETMAC_CARREGANDO && getmac /v && echo. && title GETMAC_PRONTO && pause"
    $psi.UseShellExecute = $true
    $psi.CreateNoWindow = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    
    $hwnd = Wait-Window @("GETMAC_PRONTO") 120
    Start-Sleep -Seconds 1
    Take-Screenshot "MAC"
    Close-Window $hwnd $proc
}

function Task-SerialBios {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Abrindo PowerShell para Serial da BIOS..." -ForegroundColor Gray
    $psCmd = "[System.Console]::Title='PS_CARREGANDO'; Get-CimInstance Win32_Bios | Format-List SerialNumber; [System.Console]::Title='PS_PRONTO'; Start-Sleep -Seconds 300"
    $psi = New-Object System.Diagnostics.ProcessStartInfo "powershell.exe", "-NoProfile -Command `"$psCmd`""
    $psi.UseShellExecute = $true
    $psi.CreateNoWindow = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    
    $hwnd = Wait-Window @("PS_PRONTO") 120
    Start-Sleep -Seconds 1
    Take-Screenshot "SERIAL"
    Close-Window $hwnd $proc
}

function Task-ProgramasRecursos {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Abrindo Programas e Recursos..." -ForegroundColor Gray
    [System.Diagnostics.Process]::Start("appwiz.cpl") | Out-Null
    $hwnd = Wait-Window @("Programas e Recursos", "Programs and Features")
    [Win32Functions.Win32]::ShowWindow($hwnd, 3) | Out-Null # SW_MAXIMIZE
    Wait-Stable $hwnd
    
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Mudando visualizacao para Lista..." -ForegroundColor Gray
    try {
        [Win32Functions.Win32]::SetForegroundWindow($hwnd) | Out-Null
        Start-Sleep -Milliseconds 500
        [System.Windows.Forms.SendKeys]::SendWait("^+5")
        Start-Sleep -Milliseconds 1000
    }
    catch {}
    
    Take-Screenshot "PROGRAMAS"
    Close-Window $hwnd
}

function Task-Bitlocker {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Verificando status do BitLocker..." -ForegroundColor Gray
    
    $output = manage-bde.exe -status
    $outputStr = $output -join "`r`n"
    
    $ativo = $outputStr.Contains("Proteção Ativada") -or $outputStr.Contains("Protection On") -or $outputStr.Contains("Percentage Encrypted: 100")
    
    if (-not $ativo) {
        $txtPath = Join-Path $SaveDir "sem bitlocker.txt"
        $date = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
        $txtContent = "BitLocker não está ativado neste dispositivo.`r`nData/hora: $date`r`n`r`nSaída do manage-bde:`r`n$outputStr"
        [System.IO.File]::WriteAllText($txtPath, $txtContent, [System.Text.Encoding]::UTF8)
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] BitLocker inativo. Arquivo salvo: $txtPath" -ForegroundColor Gray
        return
    }
    
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] BitLocker ativo. Coletando chaves de recuperacao..." -ForegroundColor Gray
    
    $volumes = Get-BitLockerVolume -ErrorAction SilentlyContinue
    $entries = @()
    foreach ($vol in $volumes) {
        $keys = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }
        foreach ($k in $keys) {
            $entries += [PSCustomObject]@{
                Drive       = $vol.MountPoint
                Status      = $vol.VolumeStatus
                Protection  = $vol.ProtectionStatus
                KeyId       = $k.KeyProtectorId
                RecoveryKey = $k.RecoveryPassword
            }
        }
    }
    
    if ($entries.Count -eq 0) {
        $txtPath = Join-Path $SaveDir "sem bitlocker.txt"
        $date = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
        $txtContent = "BitLocker ativo, mas nenhuma chave de recuperação encontrada.`r`nData/hora: $date`r`n`r`nSaída:`r`n$outputStr"
        [System.IO.File]::WriteAllText($txtPath, $txtContent, [System.Text.Encoding]::UTF8)
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Nenhuma chave encontrada. Arquivo salvo: $txtPath" -ForegroundColor Gray
        return
    }
    
    $pdfPath = Join-Path $SaveDir "BitLocker_RecoveryKeys.pdf"
    Generate-BitlockerPdf $pdfPath $entries
}

function Generate-BitlockerPdf ($pdfPath, $entries) {
    $lines = @(
        "CHAVES DE RECUPERAÇÃO BITLOCKER",
        "Gerado em: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')",
        (New-Object string '─', 60),
        ""
    )
    
    foreach ($e in $entries) {
        $d = $e.RecoveryKey.Replace("-", "").Replace(" ", "")
        if ($d.Length -eq 48) {
            $formattedKey = @()
            for ($i = 0; $i -lt 8; $i++) {
                $formattedKey += $d.Substring($i * 6, 6)
            }
            $recoveryKey = $formattedKey -join "-"
        }
        else {
            $recoveryKey = $e.RecoveryKey
        }
        
        $lines += "Drive:               $($e.Drive)"
        $lines += "Status:              $($e.Status)"
        $lines += "Proteção:            $($e.Protection)"
        $lines += "ID da Chave:         $($e.KeyId)"
        $lines += "Chave de Recuperação:"
        $lines += "  $recoveryKey"
        $lines += ""
        $lines += (New-Object string '─', 60)
        $lines += ""
    }
    $lines += "GUARDE ESTA CHAVE EM LOCAL SEGURO."
    $lines += "Sem ela não é possível acessar o disco em caso de bloqueio."
    
    $printers = [System.Drawing.Printing.PrinterSettings]::InstalledPrinters
    $pdfPrinter = $null
    foreach ($p in $printers) {
        if ($p.Contains("PDF") -and $p.Contains("Microsoft")) {
            $pdfPrinter = $p
            break
        }
    }
    
    if (-not $pdfPrinter) {
        [System.IO.File]::WriteAllLines($pdfPath, $lines, [System.Text.Encoding]::UTF8)
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Impressora PDF não encontrada. Salvo como texto (.pdf)." -ForegroundColor Gray
        return
    }
    
    $lineIndex = 0
    $font = New-Object System.Drawing.Font "Consolas", 10
    $titleFont = New-Object System.Drawing.Font "Consolas", 13, [System.Drawing.FontStyle]::Bold
    $lineH = 22
    
    $pd = New-Object System.Drawing.Printing.PrintDocument
    $pd.PrinterSettings.PrinterName = $pdfPrinter
    $pd.PrinterSettings.PrintToFile = $true
    $pd.PrinterSettings.PrintFileName = $pdfPath
    $pd.DefaultPageSettings.Margins = New-Object System.Drawing.Printing.Margins 60, 60, 60, 60
    
    $printPageHandler = {
        param($sender, $ev)
        $g = $ev.Graphics
        $y = $ev.MarginBounds.Top
        $x = $ev.MarginBounds.Left
        $bottom = $ev.MarginBounds.Bottom
        
        while ($script:lineIndex -lt $lines.Count) {
            $line = $lines[$script:lineIndex]
            $isTitle = $line.StartsWith("CHAVES")
            $lh = if ($isTitle) { $lineH + 8 } else { $lineH }
            if ($y + $lh -gt $bottom) {
                $ev.HasMorePages = $true
                return
            }
            $f = if ($isTitle) { $titleFont } else { $font }
            $g.DrawString($line, $f, [System.Drawing.Brushes]::Black, $x, $y)
            $y += $lh
            $script:lineIndex++
        }
        $ev.HasMorePages = $false
    }
    
    $pd.add_PrintPage($printPageHandler)
    
    $script:lineIndex = 0
    $pd.Print()
    $pd.Dispose()
    $font.Dispose()
    $titleFont.Dispose()
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] PDF do BitLocker salvo: $pdfPath" -ForegroundColor Gray
}

# --- Menu Principal ---

$Itens = @(
    @{ Label = "Informações do Sistema (MSINFO32)"; Acao = { Task-MsInfo } },
    @{ Label = "Ativação do Windows (slmgr /dli + /xpr)"; Acao = { Task-AtivacaoWindows } },
    @{ Label = "Endereço MAC (getmac /v)"; Acao = { Task-GetMac } },
    @{ Label = "Serial da BIOS (Win32_Bios)"; Acao = { Task-SerialBios } },
    @{ Label = "Programas e Recursos (appwiz.cpl)"; Acao = { Task-ProgramasRecursos } },
    @{ Label = "BitLocker – Chave de Recuperação (PDF/TXT)"; Acao = { Task-Bitlocker } }
)

function Show-Cabecalho {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║         SISTEMA INFO – Coleta de Dados          ║" -ForegroundColor DarkCyan
    Write-Host "  ║       Pasta: Downloads\PrintsSistema            ║" -ForegroundColor DarkCyan
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
    Write-Host ""
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Show-Cabecalho
        
        Write-Host "  Selecione uma ou mais opções (ex: 1,3,5) ou escolha uma opção especial:`n" -ForegroundColor Cyan
        
        for ($i = 0; $i -lt $Itens.Count; $i++) {
            Write-Host "  [$($i + 1)] " -ForegroundColor White -NoNewline
            Write-Host "$($Itens[$i].Label)" -ForegroundColor Gray
        }
        
        Write-Host ""
        Write-Host "  [T] Executar TUDO (todas as opções acima)" -ForegroundColor Green
        Write-Host "  [S] Sair" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Opção: " -NoNewline
        
        $entrada = Read-Host
        if ($null -eq $entrada) { break }
        $entrada = $entrada.Trim().ToUpper()
        
        if ($entrada -eq "S") { break }
        
        $selecionados = @()
        if ($entrada -eq "T") {
            for ($i = 1; $i -le $Itens.Count; $i++) {
                $selecionados += $i
            }
        }
        else {
            $partes = $entrada.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)
            foreach ($p in $partes) {
                $p = $p.Trim()
                if ($p -match '^\d+$') {
                    $val = [int]$p
                    if ($val -ge 1 -and $val -le $Itens.Count) {
                        $selecionados += $val
                    }
                }
            }
            $selecionados = $selecionados | Select-Object -Unique | Sort-Object
        }
        
        if ($selecionados.Count -eq 0) {
            Write-Host "`n  Opção inválida. Pressione qualquer tecla para tentar novamente..." -ForegroundColor Red
            [System.Console]::ReadKey($true) | Out-Null
            continue
        }
        
        Clear-Host
        Show-Cabecalho
        
        $nomes = @()
        foreach ($idx in $selecionados) {
            $nomes += $Itens[$idx - 1].Label
        }
        Write-Host "  Executando: $($nomes -join ', ')`n" -ForegroundColor Yellow
        
        foreach ($idx in $selecionados) {
            try {
                Write-Host "`n  ── [$idx] $($Itens[$idx - 1].Label) ──" -ForegroundColor Cyan
                & $Itens[$idx - 1].Acao
            }
            catch {
                Write-Host "ERRO na tarefa [$idx]: $_" -ForegroundColor Red
            }
        }
        
        Write-Host "`n  ✔ Concluído! Arquivos salvos em: $SaveDir" -ForegroundColor Green
        Write-Host "`n  Pressione qualquer tecla para voltar ao menu..."
        [System.Console]::ReadKey($true) | Out-Null
    }
    Clear-Host
    Write-Host "`n  Encerrando... até mais!`n" -ForegroundColor Gray
}

# Iniciar o Menu
Show-Menu
