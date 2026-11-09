& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $base = 'https://github.com/emetgate/emetgate/releases/latest/download'
    $assets = @('emetgate.exe', 'emetgate.exe.sha256')
    $dir = Join-Path $env:LOCALAPPDATA 'Programs\emetgate'
    $exe = Join-Path $dir 'emetgate.exe'
    $old = Join-Path $dir 'emetgate.old.exe'
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('emetgate-install-' + [Guid]::NewGuid().ToString('N'))

    function Stop-Install([string] $message) {
        throw [InvalidOperationException]::new($message)
    }

    function Send-EnvironmentChange {
        if (-not ('EmetgateInstall.Broadcast' -as [type])) {
            Add-Type -Namespace EmetgateInstall -Name Broadcast -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr window, uint message, System.UIntPtr wParam, string lParam, uint flags, uint timeout, out System.UIntPtr result);
'@
        }
        $result = [UIntPtr]::Zero
        [void][EmetgateInstall.Broadcast]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
    }

    function Add-UserPath([string] $folder) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        try {
            $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $entries = @($raw -split ';' | Where-Object { $_ -ne '' })
            $wanted = $folder.TrimEnd('\')
            foreach ($entry in $entries) {
                if ([Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\') -ieq $wanted) { return $false }
            }
            $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
            if ($raw -ne '') { $kind = $key.GetValueKind('Path') }
            $key.SetValue('Path', (($entries + $folder) -join ';'), $kind)
        } finally {
            $key.Close()
        }
        Send-EnvironmentChange
        return $true
    }

    function Find-OnNewPath([string] $name) {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user = [Environment]::GetEnvironmentVariable('Path', 'User')
        foreach ($entry in ("$machine;$user" -split ';')) {
            if ($entry -eq '') { continue }
            foreach ($ext in @('.exe', '.cmd', '.bat')) {
                try {
                    $candidate = Join-Path ([Environment]::ExpandEnvironmentVariables($entry)) ($name + $ext)
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
                } catch {
                    continue
                }
            }
        }
        return $null
    }

    try {
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        foreach ($name in $assets) {
            try {
                Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile (Join-Path $stage $name)
            } catch {
                Stop-Install "could not download $base/$name ($($_.Exception.Message))"
            }
        }

        $listed = (Get-Content -Raw -Path (Join-Path $stage 'emetgate.exe.sha256')).Trim()
        $expected = ($listed -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $stage 'emetgate.exe')).Hash.ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{64}$') { Stop-Install "emetgate.exe.sha256 does not hold a SHA256 hash; nothing was installed" }
        if ($actual -ne $expected) { Stop-Install "SHA256 mismatch: emetgate.exe is $actual but the release lists $expected; nothing was installed" }

        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $exe) {
            if (Test-Path -LiteralPath $old) { Stop-Install "$old is still running; close every emetgate session and run the installer again" }
            Move-Item -LiteralPath $exe -Destination $old
        }
        try {
            Move-Item -LiteralPath (Join-Path $stage 'emetgate.exe') -Destination $exe
        } catch {
            if (Test-Path -LiteralPath $old) { Move-Item -LiteralPath $old -Destination $exe -Force }
            Stop-Install "could not write $exe ($($_.Exception.Message))"
        }
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }

        $version = (& $exe --version | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { Stop-Install "$exe was installed but does not start (exit $LASTEXITCODE)" }

        $added = Add-UserPath $dir
        if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $dir.TrimEnd('\') })) { $env:Path = "$env:Path;$dir" }

        Write-Host "$version installed in $dir"
        if ($added) { Write-Host "Added $dir to your user PATH." } else { Write-Host "$dir is already on your user PATH." }
        $first = Find-OnNewPath 'emetgate'
        if ($first -and ($first -ine [IO.Path]::GetFullPath($exe))) {
            Write-Host ''
            Write-Host "Warning: a new terminal will run $first, not this install, because its folder comes first on PATH." -ForegroundColor Yellow
            Write-Host "Remove $(Split-Path -Parent $first) from PATH, or delete that copy, to run $version." -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host 'Next steps:'
        Write-Host '  1. Open a new terminal.'
        Write-Host '  2. emetgate doctor'
        Write-Host '  3. emetgate lockdown'
        Write-Host ''
        Write-Host 'emetgate doctor and emetgate lockdown check for a new signed release at most once a day and install it.'
        Write-Host 'To turn that off: [Environment]::SetEnvironmentVariable("EMETGATE_NO_UPDATE", "1", "User")'
    } catch {
        Write-Host "emetgate install failed: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
