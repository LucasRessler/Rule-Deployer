using module ".\bucket_deployment.psm1"
using module ".\shared_types.psm1"
using module ".\api_handle.psm1"
using module ".\io_handle.psm1"
using module ".\diagnose.psm1"
using module ".\parsing.psm1"
using module ".\logger.psm1"
using module ".\utils.psm1"

[CmdletBinding()]
param (
    [String]$Action,
    [String]$Tenant,
    [String]$InlineJson,
    [String]$ConfigPath = "$PSScriptRoot\config.json"
)

. "$PSScriptRoot\get_config.ps1"
. "$PSScriptRoot\resource_configs.ps1"

[Int]$EXCEL_OPEN_ATTEMPTS = 3
[Logger]$logger = [Logger]::New($Host.UI)
[String]$LOG_PATH = "ruledeployer_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"

function GetAndParseResourceData {
    param (
        [IOHandle]$io_handle,
        [Hashtable]$resource_config,
        [Hashtable]$config,
        [ApiAction[]]$actions,
        [Logger]$logger
    )

    # Get Raw Data
    $logger.section = "Load"
    $logger.Info("Loading data for $($resource_config.resource_name)s...")
    [DataPacket[]]$intermediate_data = $io_handle.GetResourceData($resource_config)
    [Int]$num_data = $intermediate_data.Count
    if ($num_data -eq 0) { $logger.Info("No data found!"); return }

    # Parse Data
    [Hashtable]$unique_check_map = @{}
    [DataPacket[]]$to_deploy = @()
    $logger.section = "Parse"
    $logger.Info("Parsing data for $num_data resource$(PluralityIn $num_data)...")
    for ($i = 0; $i -lt $num_data; $i++) {
        ShowPercentage $i $num_data
        [DataPacket]$data_packet = $intermediate_data[$i]
        $parse_intermediate_params = @{
            only_deletion = -not ([ApiAction]::Create -in $actions -or [ApiAction]::Update -in $actions)
            data_packet = $data_packet
            unique_check_map = $unique_check_map
            logger = $logger
        }
        try { $to_deploy += ParseIntermediate @parse_intermediate_params }
        catch {
            [String]$err_message = $_.Exception.Message
            [String]$short_info = $err_message.Split([System.Environment]::NewLine)[0].Split(":")[0]
            [String]$message = Format-Error -Message "Parse error at $($data_packet.origin_info)" -Cause "$err_message"
            [OutputValue]$val = [OutputValue]::New($message, $short_info, $config.color.parse_error, $data_packet.row_index)
            $io_handle.UpdateOutput($resource_config, $val)
            $logger.Error($message)
        }
    }

    $logger.Info("$($to_deploy.Count)/$num_data parsed successfully$(Punctuate $to_deploy.Count $num_data)")
    return $to_deploy
}

function Main ([String]$conf_path, [String]$tenant, [String]$inline_json, [String]$specific_action = "", [Logger]$logger) {
    $logger.section = "Setup"
    $logger.Info("Loading config from '$conf_path'...")
    [Hashtable]$config = Get-Config $conf_path # might throw
    $LOG_PATH = "$($config.log_directory)\$LOG_PATH"
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
                "Use 'create/update' to attempt both create and update requests"
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

    $logger.Info("Initialising communication with API...")
    # very dangerously disabling validating certification - sadly necessary
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [ApiHandle]$api_handle = [ApiHandle]::New($config); $api_handle.Init() # might throw
    [IOHandle]$io_handle = if ($inline_json) {
        $logger.Info("Loading JSON-data...")
        [JsonHandle]$json_handle = [JsonHandle]::New($inline_json, $config.nsx_image_path, $tenant) # might throw
        foreach ($unused_resource in $json_handle.UnusedResources()) { $logger.Warn("Unused $unused_resource") }
        $json_handle
    } else {
        $logger.Info("Opening Excel-instance...")
        $logger.Debug("Attempting to open '$($config.excel.filepath)'")
        if (-not $tenant) { throw "Please provide a tenant name" }
        [ExcelHandle]$excel_handle = [ExcelHandle]::New($config.nsx_image_path, $tenant)
        [Bool]$opened = $false
        foreach ($_ in 1..$EXCEL_OPEN_ATTEMPTS) {
            try { $excel_handle.Open($config.excel.filepath); $opened = $true; break }
            catch { $excel_handle.Release(); $logger.Info("Failed. Trying again..."); Start-Sleep 1 }
        }; if (-not $opened) { throw "Failed to open Excel-instance. :(" }
        $excel_handle 
    }

    # Display Request Plan
    $actions_info = (Join ($actions | ForEach-Object { "$_" }) "/")
    $resources_info = Join ($resource_config_groups | ForEach-Object {
        Format-List ($_ | ForEach-Object { "$($_.resource_name)s" })
    }) ", then "
    $logger.Info("Ready!")
    $logger.Info("Resource Order: $resources_info")
    $logger.Info("Request-Plan:   $actions_info resources")

    try {
        foreach ($resource_config_group in $resource_config_groups) {
            # Get, parse, collect data for each resource type in the group
            [Int]$generous_factor = 0
            [DataPacket[]]$to_deploy = @()
            foreach ($resource_config in $resource_config_group) {
                PrintDivider
                $generous_factor = [Math]::Max($generous_factor, $resource_config.additional_deploy_chances)
                [Hashtable]$get_and_parse_params = @{
                    io_handle = $io_handle
                    resource_config = $resource_config
                    config = $config
                    actions = $actions
                    logger = $logger
                }
                try { $to_deploy += GetAndParseResourceData @get_and_parse_params }
                catch { $logger.Error($_.Exception.Message) }
            }

            # Deploy parsed packets for the whole resource group
            PrintDivider
            $logger.section = "Deploy"
            [DeployBucket[]]$deploy_buckets = @()
            if ($use_smart_actions) {
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

            [Hashtable]$deploy_params = @{
                deploy_buckets = $deploy_buckets
                io_handle = $io_handle
                api_handle = $api_handle
                config = $config
                logger = $logger
            }

            try { DeployAndAwaitBuckets @deploy_params }
            catch { $logger.Error($_.Exception.Message) }
        }
    } finally {
        PrintDivider
        $logger.section = "Cleanup"
        $logger.Info("Releasing IO-Handle...")
        $io_handle.Release()
        $logger.Info("Saving Logs...")
        $logger.GetLogs() -join "`n" | Set-Content -Path $LOG_PATH
    }
}

try { Main $ConfigPath $Tenant $InlineJson $Action $logger }
catch {
    $logger.Error($_.Exception.Message)
    $logger.GetLogs() -join "`n" | Set-Content -Path $LOG_PATH
    exit 1
}

Write-Host "Done!"
