enum LogLevel {
    Debug = 0
    Info  = 1
    Warn  = 2
    Error = 3
}

class Log {
    [DateTime]$date
    [LogLevel]$level
    [String]$section
    [String]$message

    Log ([LogLevel]$level, [String]$section, [String]$message) {
        $this.date = Get-Date
        $this.level = $level
        $this.section = $section
        $this.message = $message.Trim()
    }
}

class Logger {
    [Log[]]$logs = @()
    [String]$section = $null
    [LogLevel]$min_write_level = [LogLevel]::Info
    [System.Management.Automation.Host.PSHostUserInterface]$UI

    Logger () { $this.UI = $null }
    Logger ([System.Management.Automation.Host.PSHostUserInterface]$UI) { $this.UI = $UI }

    [Void] Log ([LogLevel]$level, [String]$message) {
        $this.logs += [Log]::new($level, $this.section, $message)
        if ($null -eq $this.UI) { return }
        if ($level -lt $this.min_write_level) { return }
        switch ($level) {
            ([LogLevel]::Debug) { $this.UI.WriteDebugLine($message) }
            ([LogLevel]::Info) { $this.UI.WriteLine($message) }
            ([LogLevel]::Warn) { $this.UI.WriteWarningLine($message) }
            ([LogLevel]::Error) { $this.UI.WriteErrorLine($message) }
        }
    }

    [Void] Debug ([String]$message) { $this.Log([LogLevel]::Debug, $message) }
    [Void] Info ([String]$message) { $this.Log([LogLevel]::Info, $message) }
    [Void] Warn ([String]$message) { $this.Log([LogLevel]::Warn, $message) }
    [Void] Error ([String]$message) { $this.Log([LogLevel]::Error, $message) }

    [String[]] GetLogs () {
        return $this.logs | ForEach-Object {
            [Log]$log = $_
            [String]$date_str = $log.date.ToString("yyyy-MM-dd HH:mm:ss.ff")
            [String]$level_str = "$($log.level)".ToUpper(); $level_str += " " * (5 - $level_str.Length)
            [String]$section_str = if ($log.section) { " [ $($log.section) ] " }
            @($log.message.Split([Environment]::NewLine) | Where-Object { $_.Trim() } | ForEach-Object {
                [String]$line = "$date_str  $level_str $section_str $_"
                $date_str = "    ^           ^     "    
                $level_str = "  ^  "
                $section_str = if ($section_str) { " " * [Math]::Floor($section_str.Length / 2) + "^" + " " * [Math]::Ceiling($section_str.Length / 2 - 1) }
                $line
            }) -join "`r`n"
        }
    }

    [Void] Save ([String]$path) {
        [String]$logstr = $this.GetLogs() -join "`r`n"
        try { $logstr | Set-Content -Path $path -ErrorAction Stop }
        catch {
            $this.Error("Can't save logs, dumping to console instead")
            Write-Host $logstr
        }
    }
}
