using module ".\utils.psm1"
using module ".\api_handle.psm1"
using module ".\io_handle.psm1"
using module ".\resource_configs.ps1"
using module ".\parsing.ps1"
using module ".\converters.ps1"

[CmdletBinding()]
param (
    [String]$ConfigPath = "$PSScriptRoot\arcaignis.json",
    [String]$InlineJson,
    [String]$Tenant,
    [String]$Action
)

[Int]$EXCEL_OPEN_ATTEMPTS = 3

function Get-Config ([String]$conf_path) {
    try { $config = Get-Content $conf_path -ErrorAction Stop | ConvertFrom-Json }
    catch { throw Format-Error -Message "The config could not be loaded" -cause $_.Exception.Message }
    $faults = Assert-Format $config @{
        nsx_image_path = @{}
        api = @{
            base_url = @{}
            catalog_ids = @{ security_groups = @{}; services = @{}; rules = @{} }
            credentials = @{ username = @{}; password = @{} }
        }
        excel = @{
            filepath = @{}
            sheetnames = @{ security_groups = @{}; services = @{}; rules = @{} }
        }
    }
    if ($faults) {
        throw Format-Error `
            -Message "The config didn't match the expected format" `
            -Hints $faults
    }

    $base_url = $config.api.base_url
    $regex_cidr = "([1-9]|[1-2][0-9]|3[0-2])"             # Decimal number from 1-32
    $regex_u8 = "([0-1]?[0-9]{1,2}|2([0-4][0-9]|5[0-5]))" # Decimal number from 0-255
    $regex_ip = "($regex_u8\.){3}$regex_u8"               # u8.u8.u8.u8
    $regex_u16 = "([0-5]?[0-9]{1,4}|6([0-4][0-9]{3}|5([0-4][0-9]{2}|5([0-2][0-9]|3[0-5]))))" # Decimal number from 0-65535
    $regex_u16_range = "$regex_u16(\s*-\s*$regex_u16)?"                                      # u16 or u16-u16

    @{
        nsx_image_path = $config.nsx_image_path
        excel = $config.excel
        api = @{
            catalog_ids = $config.api.catalog_ids
            credentials = $config.api.credentials
            urls = @{
                refresh_token = "$base_url/csp/gateway/am/api/login?access_token" 
                project_id = "$base_url/iaas/api/projects"
                login = "$base_url/iaas/api/login"
                items = "$base_url/catalog/api/items"
                deployments = "$base_url/deployment/api/deployments"
            }
        }
        regex = @{
            groupname = "[A-Za-z0-9_.-]+"
            servicerequest = "[A-Za-z]+\d+"
            ip_addr = $regex_ip
            ip_cidr = "$regex_ip(/$regex_cidr)?"         # ip or ip/cidr
            port = "[A-Za-z0-9]+\s*:\s*$regex_u16_range" # word:u16-range - protocols checked in `ParsePort`
        }
        color = @{
            parse_error = 255 # Red
            dploy_error = 192 # Dark Red
            success = 4697456 # Light Green
        }
    }
}

function HandleDataSheet {
    param (
        [IOHandle]$io_handle,
        [ApiHandle]$api_handle,
        [Hashtable]$resource_config,
        [Hashtable]$config,
        [ApiAction[]]$actions
    )

    [String]$sheet_name = $resource_config.excel_sheet_name
    function NothingMoreToDo {
        Write-Host "Filled out creation status for $sheet_name."
        Write-Host "Nothing more to do!"
    }

    # Get Raw Data
    PrintDivider
    Write-Host "Loading data for $sheet_name..."
    [DataPacket[]]$raw_data = $io_handle.GetResourceData($resource_config)
    [DataPacket[]]$intermediate_data = @($raw_data | ForEach-Object { $io_handle.ParseToIntermediate($resource_config, $_) })
    [Int]$num_data = $intermediate_data.Count
    if ($num_data -eq 0) { Write-Host "Nothing to do!"; return }

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
            format = $resource_config.format
            unique_check_map = $unique_check_map
        }
        try { $to_deploy += ParseIntermediate @parse_intermediate_params }
        catch {
            [String]$err_message = $_.Exception.Message
            [String]$short_info = $err_message.Split([System.Environment]::NewLine)[0].Split(":")[0]
            [String]$message = Format-Error -Message "Parse error in ${sheet_name}" -Cause "$err_message"
            [OutputValue]$val = [OutputValue]::New($message, $short_info, $config.color.parse_error, $data_packet.row_index)
            $Host.UI.WriteErrorLine($message)
            $io_handle.UpdateOutput($resource_config, $val)
        }
    }

    [Int]$num_to_deploy = $to_deploy.Length
    Write-Host "$num_to_deploy/$num_data parsed successfully$(Punctuate $num_to_deploy $num_data)"
    if ($num_to_deploy -eq 0) { NothingMoreToDo; return }

    [String]$last_action = $null
    foreach ($action in $actions) {
        [String]$action_verb = "$action".ToLower()
        if ($last_action) {
            [String]$adverb = if ("$action" -eq $last_action) { "again" } else { "instead" }
            Write-Host "I'll attempt to $action_verb the failed resource$(PluralityIn $num_to_deploy) $adverb."
        }

        $last_action = "$action"

        # Deploy requests
        [Hashtable[]]$deployed = @()
        Write-Host "Deploying $num_to_deploy ${action}-request$(PluralityIn $num_to_deploy)..."
        for ($i = 0; $i -lt $num_to_deploy; $i++) {
            ShowPercentage $i $num_to_deploy
            [Hashtable]$data = $to_deploy[$i].data
            [String]$tenant = $to_deploy[$i].tenant
            [String]$deployment_name = "$action $($resource_config.resource_name) - $(Get-Date -UFormat %s -Millisecond 0) - LR Automation"

            try {
                [Hashtable]$inputs = & $resource_config.converter -data $data -action $action
                $deployed += @{
                    id = $api_handle.Deploy($deployment_name, $tenant, $resource_config.catalog_id, $inputs)
                    row_index = $to_deploy[$i].row_index 
                    preconverted = $data
                }
            } catch {
                [String]$short_info = "Deployment Failed"
                [String]$message = "->> Deploy error in ${sheet_name}: $($_.Exception.Message)"
                [OutputValue]$val = [OutputValue]::New($message, $short_info, $config.color.dploy_error, $to_deploy[$i].row_index)
                $Host.UI.WriteErrorLine($message)
                $io_handle.UpdateOutput($resource_config, $val)
            }

            # Start-Sleep $resource_config.ddos_sleep_time # Mandatory because of DDoS protection probably
        }
        
        [Int]$num_deployed = $deployed.Length
        Write-Host "$num_deployed/$num_to_deploy deployed$(Punctuate $num_deployed $num_to_deploy)"
        if ($num_deployed -eq 0) { NothingMoreToDo; return }

        # Await Deployments
        $to_deploy = @()
        Write-Host "Waiting for status of $num_deployed deployment$(PluralityIn $num_deployed)..."
        for ($i = 0; $i -lt $num_deployed; $i++) {
            ShowPercentage $i $num_deployed
            [Hashtable]$deployment = $deployed[$i]
            [DeploymentStatus]$status = $api_handle.WaitForDeployment($deployment.id)

            if ($status -eq [DeploymentStatus]::Successful) {
                [String]$short_info = "$action Successful"
                [String]$message = "Resource at row $($deployment.row_index) in $sheet_name was ${$action_verb}d successfully."
                [OutputValue]$val = [OutputValue]::New($message, $short_info, $config.color.success, $deployment.row_index)
                $io_handle.UpdateOutput($resource_config, $val)
            } else {
                $to_deploy += @{
                    data = $deployment.preconverted
                    row_index = $deployment.row_index
                }
            }
        }

        $num_to_deploy = $to_deploy.Length
        [Int]$num_successful = $num_deployed - $num_to_deploy
        Write-Host "$num_successful/$num_deployed ${action_verb}d successfully$(Punctuate $num_successful $num_deployed)"
        if ($num_to_deploy -eq 0) { NothingMoreToDo; return }
    }

    [String]$actions_str = Join @($actions | ForEach-Object { "$_" }) "/"
    [String]$requests_str = "$actions_str-request$(PluralityIn $actions.Length)"
    foreach ($failed in $to_deploy) {
        $row_index = $failed.row_index
        [String]$short_info = "$actions_str Failed"
        [String]$message = "->> $requests_str for resource at $row_index in $sheet_name failed"
        [OutputValue]$val = [OutputValue]::New($message, $short_info, $config.color.dploy_error, $row_index)
        $Host.UI.WriteErrorLine($message)
        $io_handle.UpdateOutput($resource_config, $val)
    }

    NothingMoreToDo
}

function Main ([String]$conf_path, [String]$tenant, [String]$inline_json, [String]$specific_action = "") {
    Write-Host "Loading config from $conf_path..."
    [Hashtable]$config = Get-Config $conf_path # might throw
    [Hashtable[]]$resource_configs = @(
        (Get-SecurityGroupsConfig $config)
        (Get-ServicesConfig $config)
        (Get-RulesConfig $config)
    )

    [ApiAction[]]$default_actions = @([ApiAction]::Create, [ApiAction]::Update)
    [ApiAction[]]$actions = switch ($specific_action.ToLower()) {
        ""       { $default_actions }
        "create" { @([ApiAction]::Create) }
        "update" { @([ApiAction]::Update) }
        "delete" {
            [Array]::Reverse($resource_configs)
            @([ApiAction]::Delete)
        }

        default {
            throw Format-Error -Message "Failed to parse specified action" -Hints @(
                "'$specific_action' is not a valid request-action"
                "Please use 'create', 'update' or 'delete'"
                "Leave blank to attempt both create and update requests"
            )
        }
    }

    Write-Host "Initialising communication with API..."
    # very dangerously disabling validating certification
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [ApiHandle]$api_handle = [ApiHandle]::New($config); $api_handle.Init() # might throw
    [IOHandle]$io_handle = if ($inline_json) {
        Write-Host "Loading JSON-data..."
        if ($tenant) { $Host.UI.WriteWarningLine("Since commandline argument Tenant=$tenant was provided, json data will be altered! It's recommended to provide tenants only via inline json!") }
        [JsonHandle]::New($inline_json, $config.nsx_image_path, $tenant)
    } else {
        Write-Host "Opening Excel-instance..."
        if (-not $tenant) { throw "Please provide a tenant name" }
        [ExcelHandle]$excel_handle = [ExcelHandle]::New($config.nsx_image_path, $tenant)
        [Bool]$opened = $false
        foreach ($_ in 0..$EXCEL_OPEN_ATTEMPTS) {
            try { $excel_handle.Open($config.excel.filepath); $opened = $true; break }
            catch { $excel_handle.Release(); Write-Host "Failed. Trying again..."; Start-Sleep 1 }
        }
        if (-not $opened) { throw "Failed to open Excel-instance. :(" }
        $excel_handle 
    }

    $actions_str = Join ($actions | ForEach-Object { "$_".ToLower() }) "/"
    $sheet_names_str = Join ($resource_configs | ForEach-Object { $_.excel_sheet_name }) ", "
    Write-Host "Request-Plan: $actions_str resources in $sheet_names_str."

    try {
        foreach ($resource_config in $resource_configs) {
            $handle_datasheet_params = @{
                actions = $actions + @($actions | ForEach-Object { @($_) * $resource_config.additional_deploy_chances })
                io_handle = $io_handle
                api_handle = $api_handle
                resource_config = $resource_config
                config = $config
            }

            try { HandleDataSheet @handle_datasheet_params | Out-Null }
            catch { $Host.UI.WriteErrorLine($_.Exception.Message) }
        }
    } finally {
        PrintDivider
        Write-Host "Releasing IO-Handle..."
        $io_handle.Release()
    }
}

try { Main $ConfigPath $Tenant $InlineJson $Action }
catch { $Host.UI.WriteErrorLine($_.Exception.Message); exit 666 }
Write-Host "Done!"
