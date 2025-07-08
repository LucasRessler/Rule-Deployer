using module ".\modules\bucket_deployment.psm1"
using module ".\modules\nsx_api_handle.psm1"
using module ".\modules\shared_types.psm1"
using module ".\modules\api_handle.psm1"
using module ".\modules\io_handle.psm1"
using module ".\modules\diagnose.psm1"
using module ".\modules\parsing.psm1"
using module ".\modules\logger.psm1"
using module ".\modules\utils.psm1"

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

. "$PSScriptRoot\modules\get_config.ps1"
. "$PSScriptRoot\modules\resource_configs.ps1"


function GetAndParseResourceData {
    param (
        [IOHandle]$io_handle,
        [Hashtable]$resource_config,
        [Hashtable]$config,
        [Hashtable]$summary,
        [ApiAction[]]$actions,
        [Logger]$logger
    )

    # Get Raw Data
    $logger.section = "Load"
    $logger.Info("Loading data for $($resource_config.resource_name)s...")
    [DataPacket[]]$intermediate_data = $io_handle.GetResourceData($resource_config)
    foreach ($data_packet in $intermediate_data) { $logger.Debug("Found data at $($data_packet.origin_info)") }
    [Int]$num_data = $intermediate_data.Count
    $summary[$resource_config.resource_name] = @{ total = $num_data }
    if ($num_data -eq 0) { $logger.Info("No data found!"); return }

    # Parse Data
    $logger.section = "Parse"
    $logger.Info("Parsing data for $num_data resource$(PluralityIn $num_data)...")
    [Hashtable]$unique_check_map = @{}
    [DataPacket[]]$to_deploy = $intermediate_data | ForEachWithPercentage {
        param ([DataPacket]$data_packet)
        $parse_intermediate_params = @{
            only_deletion = -not ([ApiAction]::Create -in $actions -or [ApiAction]::Update -in $actions)
            data_packet = $data_packet
            unique_check_map = $unique_check_map
            logger = $logger
        }
        try { ParseIntermediate @parse_intermediate_params }
        catch {
            [String]$err_message = $_.Exception.Message
            [String]$short_info = $err_message.Split([System.Environment]::NewLine)[0].Split(":")[0]
            [String]$message = Format-Error -Message "Parse error at $($data_packet.origin_info)" -Cause "$err_message"
            [OutputValue]$val = [OutputValue]::New($message, $short_info, $data_packet.row_index)
            $io_handle.UpdateOutput($resource_config, $val)
            $logger.Error($message)
        }
    }
    
    $logger.Info("$($to_deploy.Count)/$num_data parsed successfully$(Punctuate $to_deploy.Count $num_data)")
    $summary[$resource_config.resource_name]["parsed"] = $to_deploy.Count
    return $to_deploy
}

enum InputMethod {
    Json
    Excel
}

function Main {
    param (
        [Hashtable]$base_config,
        [String]$tenant,
        [String]$request_id,
        [String]$inline_json,
        [String]$excel_file_path,
        [String]$specific_action,
        [Logger]$logger
    )

    # Figure out Input Method
    [InputMethod]$input_method = if ($inline_json -and -not $excel_file_path) { [InputMethod]::Json }
    elseif ($excel_file_path -and -not $inline_json) {
        if (-not $tenant) { throw "Please provide a Tenant Name when using Excel-input" }
        else { [InputMethod]::Excel }
    } else { throw "Please use either the InlineJson-argument or the ExcelFilePath-argument to supply input" }

    # Saturate Config
    [Hashtable]$config = SaturateConfig $base_config # might throw
    [Hashtable[][]]$resource_config_groups = @(
        @((Get-SecurityGroupsConfig $config), (Get-ServicesConfig $config)),
        @((Get-RulesConfig $config))
    )

    [Bool]$use_smart_actions = $false
    [ApiAction[]]$actions = switch ($specific_action.ToLower()) {
        "create" { @([ApiAction]::Create) }
        "update" { @([ApiAction]::Update) }
        "delete" {
            [Array]::Reverse($resource_config_groups)
            @([ApiAction]::Delete)
        }
        "auto" {
            $use_smart_actions = $true
            @([ApiAction]::Create, [ApiAction]::Update)
        }
        "" {
            throw Format-Error -Message "Please provide a request action" -Hints @(
                "Valid options are 'create', 'update' and 'delete'"
                "Use 'auto' to attempt both create and update requests"
            )
        }
        default {
            throw Format-Error -Message "Failed to parse specified action" -Hints @(
                "'$specific_action' is not a valid request-action"
                "Please use 'create', 'update' or 'delete'"
                "Use 'auto' to attempt both create and update requests"
            )
        }
    }

    # Very dangerously trusting all Certs - sadly necessary
    if (!"TrustAllCertsPolicy" -as [type]) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
    return true;
    }
}
"@  }; [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

    # Create Api Handle
    $logger.Info("Initialising communication with API...")
    [ApiHandle]$api_handle = [ApiHandle]::New($config); $api_handle.Init() # might throw

    # Optionally create NSX Api Handle
    [NsxApiHandle]$nsx_api_handle = $null
    if ($NSXHostDomain) { $nsx_api_handle = [NsxApiHandle]::New($NSXHostDomain) } # might throw

    # Create JSON or Excel IO Handle
    $logger.Info("Initialising IO-Handle...")
    [IOHandle]$io_handle = switch ($input_method) {
        ([InputMethod]::Json) {
            $logger.Info("Loading JSON-data...")
            [JsonHandle]$json_handle = [JsonHandle]::New($inline_json, $config.nsx_image_path, $tenant, $request_id) # might throw
            foreach ($unused_resource in $json_handle.UnusedResources()) { $logger.Warn("Unused $unused_resource") }
            $json_handle
        }
        ([InputMethod]::Excel) {
            $logger.Info("Using Excel-Handle...")
            $logger.Debug("Attempting to open '$excel_file_path'")
            [ExcelHandle]::New($config.nsx_image_path, $excel_file_path, $tenant, $request_id) # might throw
        }
    }

    # Provide Info on Planned Request Order
    [String]$actions_info = Join ($actions | ForEach-Object { "$_" }) "/"
    [String]$resources_info = Join ($resource_config_groups | ForEach-Object {
        Format-List ($_ | ForEach-Object { "$($_.resource_name)s" })
    }) ", then "
    $logger.Info("Ready!`r`n")
    $logger.Info("Resource Order: $resources_info")
    $logger.Info("Request-Plan:   $actions_info resources")
    [Hashtable]$summary = @{}

    foreach ($resource_config_group in $resource_config_groups) {
        # Get, parse and collect data for each resource type in the group
        [Int]$generous_factor = 0
        [DataPacket[]]$to_deploy = @()
        foreach ($resource_config in $resource_config_group) {
            PrintDivider
            $generous_factor = [Math]::Max($generous_factor, $resource_config.additional_deploy_chances)
            [Hashtable]$get_and_parse_params = @{
                io_handle = $io_handle
                resource_config = $resource_config
                config = $config
                summary = $summary
                actions = $actions
                logger = $logger
            }
            try { $to_deploy += GetAndParseResourceData @get_and_parse_params }
            catch { $logger.Error($_.Exception.Message) }
        }

        # Deploy parsed packets for the whole resource group
        PrintDivider
        [DeployBucket[]]$deploy_buckets = @()
        if ($use_smart_actions -and $nsx_api_handle) {
            # If we have NSX Api access, we definitively know which action to take
            $logger.Info("Checking for existing Resources via NSX API...")
            $deploy_buckets += [DeployBucket]::New(@([ApiAction]::Create))
            $deploy_buckets += [DeployBucket]::New(@([ApiAction]::Update))
            foreach ($data_packet in $to_deploy | Where-Object { $_ }) {
                try { [Bool]$resource_exists = $nsx_api_handle.ResourceExists($data_packet) }
                catch { $logger.Error((Format-Error -Message "NSX Get-Request unsuccessful" -Cause $_.Exception.Message)); break }
                if ($resource_exists) { $deploy_buckets[1].to_deploy += $data_packet }
                else { $deploy_buckets[0].to_deploy += $data_packet }
            }
        } elseif ($use_smart_actions) {
            # Without the Api, we can still make a guess based on the Nsx Image
            $logger.Info("Comparing Resources with NSX Image...")
            $deploy_buckets += [DeployBucket]::New(@([ApiAction]::Create, [ApiAction]::Update))
            $deploy_buckets += [DeployBucket]::New(@([ApiAction]::Update, [Apiaction]::Create))
            foreach ($data_packet in $to_deploy) {
                [Bool]$img_exists = $null -ne $io_handle.GetImage($data_packet.GetImageKeys())
                if ($img_exists) { $deploy_buckets[1].to_deploy += $data_packet }
                else { $deploy_buckets[0].to_deploy += $data_packet }
            }
        } else { $deploy_buckets += [DeployBucket]::New($actions, $to_deploy) }
        # Duplicate the first action of each bucket for extra deploy chances
        foreach ($bucket in $deploy_buckets) {
            [ApiAction[]]$generous_actions = @($bucket.actions[0]) * $generous_factor + @($bucket.actions)
            $bucket.actions = $generous_actions
        }

        if ($nsx_api_handle) {
            # Catches issues like missing dependencies, dangling references, etc.
            $logger.section = "Validate"
            $logger.Info("Validating Integrity of Resources...")
            foreach ($bucket in $deploy_buckets) {
                $bucket.to_deploy = $bucket.to_deploy | ForEachWithPercentage {
                    param ([DataPacket]$unvalidated_packet)
                    [String[]]$faults = ValidateWithNsxApi $nsx_api_handle $unvalidated_packet $bucket.actions
                    if ($faults.Count) {
                        [String]$message = Format-Error -Message "Integrity error at $($unvalidated_packet.origin_info)" -Hints $faults
                        [String]$short_info = "$actions_info Not Possible"
                        [OutputValue]$val = [OutputValue]::New($message, $short_info, $unvalidated_packet.row_index)
                        $io_handle.UpdateOutput($unvalidated_packet.resource_config, $val)
                        $logger.Error($message)
                    } else { $unvalidated_packet.validated = $true; $unvalidated_packet }
                }
            }
        }

        [Hashtable]$deploy_params = @{
            deploy_buckets = $deploy_buckets
            io_handle = $io_handle
            api_handle = $api_handle
            summary = $summary
            logger = $logger
        }
        try { DeployAndAwaitBuckets @deploy_params }
        catch { $logger.Error($_.Exception.Message) }
    }

    # Cleanup
    [Int]$ret = 0; [Int]$total = 0; [Int]$parsed = 0; [Int]$successful = 0
    [String]$performed_actions = Format-List ($actions | ForEach-Object { "${_}d".ToLower() }) "or"
    [String[]]$summaries = $summary.Keys | ForEach-Object {
        $total += [Int]$summary[$_].total; $parsed += [Int]$summary[$_].parsed; $successful += [Int]$summary[$_].successful
        "$([Int]($summary[$_].successful))/$($summary[$_].total) $_$(PluralityIn $summary[$_].total)"
    }

    $logger.section = "Cleanup"; PrintDivider
    $logger.Info("$(Format-List $summaries) $performed_actions successfully.")
    $logger.Info("Releasing IO-Handle..."); $io_handle.Release()
    $logger.Info("Saving Logs..."); $logger.Save($LogPath)

    if ($parsed -lt $total) { $ret += 1 }
    if ($successful -lt $parsed) { $ret += 2 }
    return $ret
}

# --- Program Flow ---
# Initialise Logger
[Logger]$logger = [Logger]::New($Host.UI)
[String]$log_filename = "ruledeployer_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
$logger.Debug("I was invoked with '$($MyInvocation.Line)'")

$logger.section = "Setup"
$logger.Info("Loading Config from $ConfigPath...")

# Load Config
try {
    [Hashtable]$config = Get-Config  -overrides @{
        VraHostName = $VraHostName
        NsxImagePath = $NsxImagePath
        EnvFile = $EnvFile
        LogDir = $LogDir
    } -defaults @{
        NsxImagePath = "$PSScriptRoot\nsx_image.json"
        EnvFile = "$PSScriptRoot\.env"
        LogDir = "$PSScriptRoot\logs"
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
    } -fully_optional @{
        NsxHostDomain = $NsxHostDomain
    } -config_path $ConfigPath -logger $logger
} catch {
    $logger.Error((Format-Error `
        -Message "Error Loading Config from $ConfigPath" `
        -Cause $_.Exception.Message))
    $logger.Save($log_filename)
    exit 666
}

# Load Env Vars
if ($null -ne (Get-Item -Path $config.EnvFile)) {
    Get-Content -Path $config.EnvFile | ForEach-Object {
        if ($_ -match '^\s*(#.*)?$') { return }
        [String[]]$parts = $_ -split '=', 2
        if ($parts.Count -eq 2) {
            $name = $parts[0].Trim()
            $value = $parts[1].Trim()
            [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

# Ensure LogPath exists
[String]$LogPath = "$($config.LogDir)\$log_filename"
New-Item -ItemType Directory -Path $config.LogDir -Force | Out-Null
$logger.Debug("Log-Output has been set to '$LogPath'")

# Call Main Function
[Hashtable]$main_params = @{
    base_config = $config
    tenant = $Tenant 
    request_id = $RequestId
    inline_json = $InlineJson 
    excel_file_path = $ExcelFilePath
    specific_action = $Action 
    logger = $logger
}
try {
    [Int]$ret = Main @main_params
    Write-Host "Done!"; exit $ret
} catch {
    $logger.Error($_.Exception.Message)
    $logger.Save($LogPath); exit 666
}
