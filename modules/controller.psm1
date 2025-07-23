using module ".\bucket_deployment.psm1"
using module ".\nsx_api_handle.psm1"
using module ".\shared_types.psm1"
using module ".\api_handle.psm1"
using module ".\get_config.psm1"
using module ".\io_handle.psm1"
using module ".\diagnose.psm1"
using module ".\logger.psm1"

. "$PSScriptRoot\resource_configs.ps1"

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
    try { [DataPacket[]]$intermediate_data = $io_handle.GetResourceData($resource_config) }
    catch { $intermediate_data = @(); $logger.Error($_.Exception.Message) }
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

function StartController {
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

    # Create Api Handle
    Initialize-SessionSecurity
    $logger.Info("Initialising communication with API...")
    [ApiHandle]$api_handle = [ApiHandle]::New($config); $api_handle.Init() # might throw

    # Optionally create NSX Api Handle
    [NsxApiHandle]$nsx_api_handle = $null
    if ($config.nsx_host_domain) {
        try { $nsx_api_handle = [NsxApiHandle]::New($config.nsx_host_domain) }
        catch {
            $logger.Error((Format-Error -Message "Error Instanciating NSX-API-Handle" -Cause $_.Exception.Message))
            $logger.Warn("Instead of the NSX-API, I will use the NSX-Image to diagnose integrity issues")
            $nsx_api_handle = $null
        }
    }

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
        $to_deploy = @($to_deploy | Where-Object { $_ })
        if ($use_smart_actions -and $nsx_api_handle) {
            # If we have NSX Api access, we definitively know which action to take
            $logger.Info("Checking for existing Resources via NSX API...")
            $deploy_buckets += [DeployBucket]::New(@([ApiAction]::Create))
            $deploy_buckets += [DeployBucket]::New(@([ApiAction]::Update))
            foreach ($data_packet in $to_deploy) {
                try { [Bool]$resource_exists = $nsx_api_handle.ResourceExists($data_packet) }
                catch {
                    $logger.Error((Format-Error -Message "NSX Get-Request unsuccessful" -Cause $_.Exception.Message))
                    $logger.Warn("I will use the NSX-Image for automatic request choices and to diagnose integrity issues")
                    $deploy_buckets = @(); $nsx_api_handle = $null; break
                }
                if ($resource_exists) { $deploy_buckets[1].to_deploy += $data_packet }
                else { $deploy_buckets[0].to_deploy += $data_packet }
            }
        }
        if ($use_smart_actions -and $null -eq $nsx_api_handle) {
            # Without the Api, we can still make a guess based on the Nsx Image
            $logger.Info("Comparing Resources with NSX Image...")
            $deploy_buckets += [DeployBucket]::New(@([ApiAction]::Create, [ApiAction]::Update))
            $deploy_buckets += [DeployBucket]::New(@([ApiAction]::Update, [ApiAction]::Create))
            foreach ($data_packet in $to_deploy) {
                [Bool]$img_exists = $null -ne $io_handle.GetImage($data_packet.GetImageKeys())
                if ($img_exists) { $deploy_buckets[1].to_deploy += $data_packet }
                else { $deploy_buckets[0].to_deploy += $data_packet }
            }
        }
        if (-not $use_smart_actions) { $deploy_buckets += [DeployBucket]::New($actions, $to_deploy) }
        # Duplicate the first action of each bucket for extra deploy chances
        foreach ($bucket in $deploy_buckets) {
            [ApiAction[]]$generous_actions = @($bucket.actions[0]) * $generous_factor + @($bucket.actions)
            $bucket.actions = $generous_actions
        }

        if ($nsx_api_handle) {
            # Catches issues like missing dependencies, dangling references, etc.
            $logger.section = "Validate"
            $logger.Info("Validating Integrity of Resources...")
            try {
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
                    } | Where-Object { $_ }
                }
            } catch {
                $logger.Error((Format-Error -Message "Failed to Validate Integrity of Resources" -Cause $_.Exception.Message))
                $logger.Warn("Instead of the NSX-API, I will use the NSX-Image to diagnose integrity issues")
                $nsx_api_handle = $null
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

    if ($parsed -lt $total) { $ret += 1 }
    if ($successful -lt $parsed) { $ret += 2 }
    return $ret
}
