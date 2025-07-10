using module ".\modules\controller.psm1"
using module ".\modules\get_config.psm1"
using module ".\modules\logger.psm1"

[CmdletBinding()]
param (
    # One of these input methods is required
    [String]$InlineJson,
    [String]$ExcelFilePath,

    # CLI only
    [String]$Action,        # Always required
    [String]$Tenant,        # Required for Excel-Input
    [String]$RequestId,     # Optional, injects Request-ID

    # Cli only with default
    [String]$ConfigPath = "$PSScriptRoot\config.json",
    
    # CLI or Config
    [String]$VraHostName,   # Required, no default
    [String]$NsxHostDomain, # Fully optional
    [String]$NsxImagePath,  # Provides default
    [String]$EnvFile,       # Provides default
    [String]$LogDir         # Provides default
)

# Initialise Logger
[Logger]$logger = [Logger]::New($Host.UI)
[String]$default_log_dir = "$PSScriptRoot\logs"
[String]$log_filename = "ruledeployer_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
[String]$LogPath = "$default_log_dir\$log_filename"
$logger.Debug("I was invoked with '$($MyInvocation.Line)'")

# Define Config Structure
[Hashtable]$get_config_params = @{
    config_path = $ConfigPath
    logger = $logger

    defaults = @{
        NsxImagePath = "$PSScriptRoot\nsx_image.json"
        EnvFile = "$PSScriptRoot\.env"
        LogDir = $default_log_dir

        excel_sheetnames = @{
            security_groups = "SecurityGroups"
            services = "Services"
            rules = "Rules"
        }

        catalog_ids = @{
            security_groups = $null
            services = $null
            rules = $null
        }
    }
    
    overrides = @{
        VraHostName = $VraHostName
        NsxImagePath = $NsxImagePath
        EnvFile = $EnvFile
        LogDir = $LogDir
    }

    fully_optional = @{
        NsxHostDomain = $NsxHostDomain
    }
}

# Load Config
$logger.section = "Setup"
$logger.Info("Loading Config from '$ConfigPath'...")
try { [Hashtable]$config = Get-Config @get_config_params }
catch {
    [String]$err = Format-Error -Message "Error Loading Config from $ConfigPath" -Cause $_.Exception.Message
    $logger.Error($err); $logger.Save($LogPath); exit 666
}

# Ensure LogDir exists
$LogPath = "$($config.LogDir)\$log_filename"
New-Item -ItemType Directory -Path $config.LogDir -Force | Out-Null
$logger.Debug("Log-Output has been set to '$LogPath'")

# Load Env Vars
[String]$env_file = $config.EnvFile
if (Test-Path -Path $env_file) {
    $logger.Debug("Loading environment variables from '$env_file'")
    Get-Content -Path $env_file | ForEach-Object {
        if ($_ -match '^\s*(#.*)?$') { return }
        [String[]]$parts = $_ -split '=', 2
        if ($parts.Count -eq 2) {
            $name = $parts[0].Trim()
            $value = $parts[1].Trim()
            [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

# Call Controller Function
[Int]$ret = 0
[Hashtable]$controller_params = @{
    base_config = $config
    tenant = $Tenant 
    request_id = $RequestId
    inline_json = $InlineJson 
    excel_file_path = $ExcelFilePath
    specific_action = $Action 
    logger = $logger
}
try {
    $ret = StartController @controller_params
    $logger.Info("Saving Logs...")
    $logger.Save($LogPath)
    Write-Host "Done!"
    exit $ret
}
catch { $logger.Error($_.Exception.Message); $ret = 666 }
finally { $logger.Debug("End of Log"); $logger.Save($LogPath); exit $ret }
