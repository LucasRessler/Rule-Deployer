using module ".\shared_types.psm1"
using module ".\api_handle.psm1"
using module ".\io_handle.psm1"
using module ".\diagnose.psm1"
using module ".\parsing.psm1"
using module ".\utils.psm1"

[CmdletBinding()]
param (
    [String]$ConfigPath = "$PSScriptRoot\config.json",
    [String]$InlineJson,
    [String]$Tenant,
    [String]$Action
)

. "$PSScriptRoot\get_config.ps1"
. "$PSScriptRoot\resource_configs.ps1"

[Int]$EXCEL_OPEN_ATTEMPTS = 3

function GetAndParseResourceData {
    param (
        [IOHandle]$io_handle,
        [Hashtable]$resource_config,
        [Hashtable]$config,
        [ApiAction[]]$actions
    )

    # Get Raw Data
    Write-Host "Loading data for $($resource_config.resource_name)s..."
    [DataPacket[]]$intermediate_data = $io_handle.GetResourceData($resource_config)
    [Int]$num_data = $intermediate_data.Count
    if ($num_data -eq 0) { Write-Host "No data found!"; return }

    # Parse Data
    [Hashtable]$unique_check_map = @{}
    [DataPacket[]]$to_deploy = @()
    Write-Host "Parsing data for $num_data resource$(PluralityIn $num_data)..."
    for ($i = 0; $i -lt $num_data; $i++) {
        ShowPercentage $i $num_data
        [DataPacket]$data_packet = $intermediate_data[$i]
        $parse_intermediate_params = @{
            only_deletion = -not ([ApiAction]::Create -in $actions -or [ApiAction]::Update -in $actions)
            data_packet = $data_packet
            unique_check_map = $unique_check_map
        }
        try { $to_deploy += ParseIntermediate @parse_intermediate_params }
        catch {
            [String]$err_message = $_.Exception.Message
            [String]$short_info = $err_message.Split([System.Environment]::NewLine)[0].Split(":")[0]
            [String]$message = Format-Error -Message "Parse error at $($data_packet.origin_info)" -Cause "$err_message"
            [OutputValue]$val = [OutputValue]::New($message, $short_info, $config.color.parse_error, $data_packet.row_index)
            $Host.UI.WriteErrorLine($message)
            $io_handle.UpdateOutput($resource_config, $val)
        }
    }

    Write-Host "$($to_deploy.Count)/$num_data parsed successfully$(Punctuate $to_deploy.Count $num_data)"
    return $to_deploy
}

function DeployAndAwaitPackets {
    param (
        [DataPacket[]]$to_deploy,
        [ApiAction[]]$actions,
        [IOHandle]$io_handle,
        [ApiHandle]$api_handle,
        [Hashtable]$config
    )

    function NothingMoreToDo { Write-Host "Nothing more to do." }
    [Int]$num_to_deploy = $to_deploy.Count
    if ($num_to_deploy -eq 0) { NothingMoreToDo; return }

    [String]$last_action = $null
    foreach ($action in $actions) {
        [String]$action_verb = "$action".ToLower()
        if ($last_action) {
            [String]$adverb = if ("$action" -eq $last_action) { "again" } else { "instead" }
            Write-Host "I'll attempt to $action_verb the failed resource$(PluralityIn $num_to_deploy) $adverb."
        }; $last_action = "$action"

        # Deploy requests
        [DataPacket[]]$deployed = @()
        Write-Host "Deploying $num_to_deploy ${action}-request$(PluralityIn $num_to_deploy)..."
        for ($i = 0; $i -lt $num_to_deploy; $i++) {
            ShowPercentage $i $num_to_deploy
            [DataPacket]$data_packet = $to_deploy[$i]
            [Hashtable]$resource_config = $data_packet.resource_config
            [Hashtable]$data = $data_packet.data

            # Align with Image
            # I'll have to save the old version of the packet if I ever implement smart action order
            if ($action -eq [ApiAction]::Update -and ($img = $io_handle.GetImage($data_packet.GetImageKeys()))) {
                [String]$k_sr = "servicerequest"; [String]$k_ur = "updaterequests"
                [String]$sr_cur = $data[$k_sr]; [String]$sr_img = $img[$k_sr]
                [Bool]$sr_changed = $null -ne $sr_img -and $sr_img -ne $sr_cur
                [String[]]$ur_cur = $data[$k_ur]; [String[]]$ur_img = $img[$k_ur]
                [String[]]$ur_new = $ur_cur + $ur_img
                if ($sr_changed) { $ur_new += $sr_cur; $data[$k_sr] = $sr_img }
                $data[$k_ur] = NormalizeArray $ur_new
                $data["date_creation"] = $img["date_creation"]
                $data_packet.ClearCache()
            }

            [Hashtable]$inputs = $data_packet.GetApiConversion($action)
            [String]$name = $data_packet.GetApiConversion([ApiAction]::Create).name
            [String]$date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            [String]$deployment_name = "$action $(Join @($resource_config.resource_name, $name) " ") - $date - LR Automation"

            try {
                $data_packet.deployment_id = $api_handle.Deploy($deployment_name, $data_packet.tenant, $resource_config.catalog_id, $inputs)
                $deployed += $data_packet
            } catch {
                [String]$short_info = "Deployment Failed"
                [String]$message = "Deploy error at $($to_deploy[$i].origin_info): $($_.Exception.Message)"
                [OutputValue]$val = [OutputValue]::New($message, $short_info, $config.color.dploy_error, $data_packet.row_index)
                $Host.UI.WriteErrorLine($message)
                $io_handle.UpdateOutput($resource_config, $val)
            }

            Start-Sleep $resource_config.ddos_sleep_time # Mandatory because of DDoS protection probably
        }
        
        [Int]$num_deployed = $deployed.Length
        Write-Host "$num_deployed/$num_to_deploy deployed$(Punctuate $num_deployed $num_to_deploy)"
        if ($num_deployed -eq 0) { NothingMoreToDo; return }

        # Await Deployments
        $to_deploy = @()
        Write-Host "Waiting for status of $num_deployed deployment$(PluralityIn $num_deployed)..."
        for ($i = 0; $i -lt $num_deployed; $i++) {
            ShowPercentage $i $num_deployed
            [DataPacket]$deployment = $deployed[$i]
            [Hashtable]$resource_config = $deployment.resource_config
            [DeploymentStatus]$status = $api_handle.WaitForDeployment($deployment.deployment_id)

            if ($status -eq [DeploymentStatus]::Successful) {
                [String]$short_info = "$action Successful"
                [String]$message = "Resource at $($deployment.origin_info) was ${$action_verb}d successfully."
                [OutputValue]$val = [OutputValue]::New($message, $short_info, $config.color.success, $deployment.row_index)
                $io_handle.UpdateOutput($resource_config, $val)

                [Hashtable]$image = $deployment.GetImageConversion()
                $io_handle.UpdateNsxImage($image, $action)
            } else { $to_deploy += $deployment }
        }

        $num_to_deploy = $to_deploy.Length
        [Int]$num_successful = $num_deployed - $num_to_deploy
        Write-Host "$num_successful/$num_deployed ${action_verb}d successfully$(Punctuate $num_successful $num_deployed)"
        if ($num_to_deploy -eq 0) { NothingMoreToDo; return }
    }

    [String]$actions_str = Join @($actions | Select-Object -Unique | ForEach-Object { "$_" }) "/"
    [String]$requests_str = "$actions_str-request$(PluralityIn $actions.Length)"
    foreach ($failed_packet in $to_deploy) {
        [String]$short_info = "$actions_str Failed"
        [String]$message = Format-Error -Message "$requests_str for resource at $($failed_packet.origin_info) failed" `
            -Hints (DiagnoseFailure $io_handle $failed_packet $actions)
        [OutputValue]$val = [OutputValue]::New($message, $short_info, $config.color.dploy_error, $failed_packet.row_index)
        $Host.UI.WriteErrorLine($message)
        $io_handle.UpdateOutput($resource_config, $val)
    }

    NothingMoreToDo
}

function Main ([String]$conf_path, [String]$tenant, [String]$inline_json, [String]$specific_action = "") {
    Write-Host "Loading config from $conf_path..."
    [Hashtable]$config = Get-Config $conf_path # might throw
    [Hashtable[][]]$resource_config_groups = @(
        @((Get-SecurityGroupsConfig $config), (Get-ServicesConfig $config)),
        @((Get-RulesConfig $config))
    )

    [ApiAction[]]$actions = switch ($specific_action.ToLower()) {
        "create/update" { @([ApiAction]::Create, [ApiAction]::Update) }
        "create" { @([ApiAction]::Create) }
        "update" { @([ApiAction]::Update) }
        "delete" {
            [Array]::Reverse($resource_config_groups)
            @([ApiAction]::Delete)
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
                "Use 'create/update' to attempt both create and update requests"
            )
        }
    }

    Write-Host "Initialising communication with API..."
    # very dangerously disabling validating certification - sadly necessary
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [ApiHandle]$api_handle = [ApiHandle]::New($config); $api_handle.Init() # might throw
    [IOHandle]$io_handle = if ($inline_json) {
        Write-Host "Loading JSON-data..."
        [JsonHandle]$json_handle = [JsonHandle]::New($inline_json, $config.nsx_image_path, $tenant) # might throw
        foreach ($unused_resource in $json_handle.UnusedResources()) { $Host.UI.WriteWarningLine("Unused $unused_resource") }
        $json_handle
    }
    else {
        Write-Host "Opening Excel-instance..."
        if (-not $tenant) { throw "Please provide a tenant name" }
        [ExcelHandle]$excel_handle = [ExcelHandle]::New($config.nsx_image_path, $tenant)
        [Bool]$opened = $false
        foreach ($_ in 1..$EXCEL_OPEN_ATTEMPTS) {
            try { $excel_handle.Open($config.excel.filepath); $opened = $true; break }
            catch { $excel_handle.Release(); Write-Host "Failed. Trying again..."; Start-Sleep 1 }
        }
        if (-not $opened) { throw "Failed to open Excel-instance. :(" }
        $excel_handle 
    }

    # Display Request Plan
    $actions_info = (Join ($actions | ForEach-Object { "$_" }) "/")
    $resources_info = Join ($resource_config_groups | ForEach-Object {
        Join ($_ | ForEach-Object { "$($_.resource_name)s" }) " + "
    }) ", then "
    Write-Host "Ready!`n"
    Write-Host "Resource Order: $resources_info"
    Write-Host "Request-Plan:   $actions_info resources"

    try {
        foreach ($resource_config_group in $resource_config_groups) {
            # Get, parse, collect data for each resource type in the group
            [Int]$deploy_chances = 0
            [DataPacket[]]$to_deploy = @()
            foreach ($resource_config in $resource_config_group) {
                PrintDivider
                $deploy_chances = [Math]::Max($deploy_chances, $resource_config.additional_deploy_chances)
                $get_and_parse_params = @{
                    io_handle = $io_handle
                    resource_config = $resource_config
                    config = $config
                    actions = $actions
                }
                try { $to_deploy += GetAndParseResourceData @get_and_parse_params }
                catch { $Host.UI.WriteErrorLine($_.Exception.Message) }
            }

            # Deploy parsed packets for the whole resource group
            PrintDivider
            $generous_actions = $actions
            $generous_actions += $actions | ForEach-Object { @($_) * $deploy_chances }
            $deploy_params = @{
                to_deploy = $to_deploy
                actions = $generous_actions
                io_handle = $io_handle
                api_handle = $api_handle
                config = $config
            }
            try { DeployAndAwaitPackets @deploy_params }
            catch { $Host.UI.WriteErrorLine($_.Exception.Message) }
        }
    } finally {
        PrintDivider
        Write-Host "Releasing IO-Handle..."
        $io_handle.Release()
    }
}

try { Main $ConfigPath $Tenant $InlineJson $Action }
catch { $Host.UI.WriteErrorLine($_.Exception.Message); exit 1 }
Write-Host "Done!"
