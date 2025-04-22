using module ".\nsx_api_handle.psm1"
using module ".\shared_types.psm1"
using module ".\io_handle.psm1"

# With NSX Image
function CheckDependenciesFromImg {
    param ([IOHandle]$io_handle, [DataPacket]$failed_packet)
    if ($failed_packet.resource_config.id -ne [ResourceID]::Rule) { return @() }
    [String[]]$missing_depends = @()
    [String]$tenant = $failed_packet.tenant
    foreach ($used_service in $failed_packet.data["services"]) {
        [String[]]$service_keys = @($tenant, "services", $used_service)
        if ($null -eq $io_handle.GetImage($service_keys)) { $missing_depends += "$used_service (Service)" }
    }
    foreach ($used_source in $failed_packet.data["sources"]) {
        [String[]]$source_keys = @($tenant, "security_groups", $used_source)
        if ($null -eq $io_handle.GetImage($source_keys)) { $missing_depends += "$used_source (Source Security Group)" }
    }
    foreach ($used_destination in $failed_packet.data["destinations"]) {
        [String[]]$desitnation_keys = @($tenant, "security_groups", $used_destination)
        if ($null -eq $io_handle.GetImage($desitnation_keys)) { $missing_depends += "$used_destination (Destination Security Group)" }
    }
    return $missing_depends
}

function CheckDependeesFromImg {
    param ([IOHandle]$io_handle, [DataPacket]$failed_packet, [Bool]$tried_delete)
    if (-not $tried_delete -or $failed_packet.resource_config.id -eq [ResourceId]::Rule) { return @() }
    [String[]]$dependees = @()
    [String]$name = $failed_packet.data["name"]
    [Hashtable]$relevant_rules = @{}
    [Hashtable]$this_tenant = $io_handle.nsx_image[$failed_packet.tenant]
    if ($this_tenant -and $this_tenant["rules"]) { $relevant_rules = $this_tenant["rules"] }
    foreach ($gateway in $relevant_rules.Keys) {
        [Hashtable]$service_requests = $relevant_rules[$gateway]
        foreach ($service_request in $service_requests.Keys) {
            [Hashtable]$indeces = $service_requests[$service_request]
            foreach ($index in $indeces.Keys) {
                [Hashtable]$rule = $indeces[$index]
                [String[]]$depends = @(
                    $rule["services"]
                    $rule["sources"]
                    $rule["destinations"]
                )
                if ($name -in $depends) { $dependees += $rule["name"] }
            }
        }
    }
    return $dependees
}

function DiagnoseWithImg {
    param (
        [IOHandle]$io_handle,
        [DataPacket]$failed_packet,
        [ApiAction[]]$failed_actions
    )

    [Bool]$tried_create = [ApiAction]::Create -in $failed_actions
    [Bool]$tried_update = [ApiAction]::Update -in $failed_actions
    [Bool]$tried_delete = [ApiAction]::Delete -in $failed_actions
    [Bool]$already_exists = $null -ne $io_handle.GetImage($failed_packet.GetImageKeys())
    [String[]]$missing_depends = CheckDependenciesFromImg $io_handle $failed_packet
    [String[]]$dependees_found = CheckDependeesFromImg $io_handle $failed_packet $tried_delete

    # Give Feedback
    [String[]]$faults = @()
    if (($tried_create -or $tried_update) -and $missing_depends.Count) {
        $faults += @( # Can only happen for FW Rules
            "Make sure that all security groups and services used in the rule exist"
            "It's likely that one or more of the following resources don't exist:"
            @($missing_depends | ForEach-Object { "- '$_'" })
            "Note: I can only make statements for resources that were modified with this tool"
        )
    }
    if ($tried_create -and -not $tried_update -and $already_exists) {
        $faults += @(
            "The resource was found in the NSX-Image"
            "It's very likely that it already exists"
            "You could try updating it instead"
        )
    }
    if ($tried_update -and -not $tried_create -and -not $already_exists) {
        $faults += @(
            "The resource was not found in the NSX-Image"
            "It's likely that it doesn't exist yet"
            "You could try creating it instead"
        )
    }
    if ($tried_delete -and $dependees_found.Count) {
        $faults += @( # Can only happen for Security Groups and Services
            "Make sure that no rules still use this resource"
            "It's likely that one or more of the following rules still use it:"
            @($dependees_found | ForEach-Object { "- '$_'" })
            "Note: I can only make statements for resources that were modified with this tool"
        )
    }
    if ($tried_delete -and -not $already_exists) {
        $faults += @(
            "The resource was not found in the NSX-Image"
            "It's likely that it doesn't exist at all"
        )
    }
    if ($faults.Count -eq 0) {
        $faults += @(
            "It's possible that the API has run into a collision"
            "You could try deploying the request for this resource again"
            "Note: I can only make statements for resources that were modified with this tool"
        )
        if ($tried_create -and -not ($tried_update -or $tried_delete)) {
            $faults += "The resource may have already been created manually or with a different tool"
        }
        if (-not $tried_create -and ($tried_update -or $tried_delete)) {
            $faults += "The resource may have been removed manually or with a different tool"
        }
    }
    return $faults
}


# With NSX API
function CheckDependenciesFromApi {
    param ([NsxApiHandle]$nsx_api_handle, [DataPacket]$failed_packet)
    if ($failed_packet.resource_config.id -ne [ResourceId]::Rule) { return @() }
    [String[]]$missing_depends = @()
    [String]$tenant = $failed_packet.tenant
    foreach ($used_service in $failed_packet.data["services"]) {
        [DataPacket]$service_dp = [DataPacket]::New(@{ name = $used_service }, @{ id = [ResourceId]::Service }, $tenant, $null)
        if (-not $nsx_api_handle.ResourceExists($service_dp)) { $missing_depends += "$used_service (Service)" }
    }
    foreach ($used_source in $failed_packet.data["sources"]) {
        [DataPacket]$source_dp = [DataPacket]::New(@{ name = $used_source }, @{ id = [ResourceId]::SecurityGroup }, $tenant, $null)
        if (-not $nsx_api_handle.ResourceExists($source_dp)) { $missing_depends += "$used_source (Source Security Group)" }
    }
    foreach ($used_destination in $failed_packet.data["destinations"]) {
        [DataPacket]$destination_dp = [DataPacket]::New(@{ name = $used_destination }, @{ id = [ResourceId]::SecurityGroup }, $tenant, $null)
        if (-not $nsx_api_handle.ResourceExists($destination_dp)) { $missing_depends += "$used_destination (Destination Security Group)" }
    }
    return $missing_depends
}

function CheckDependeesFromApi {
    param ([NsxApiHandle]$nsx_api_handle, [DataPacket]$failed_packet, [Bool]$tried_delete)
    if (-not $tried_delete -or $failed_packet.resource_config.id -eq [ResourceId]::Rule) { return @() }
    [String]$dependency_path = "/" + $nsx_api_handle.ResourcePath($failed_packet)
    [String]$payload_rules_path = $nsx_api_handle.RulePath($failed_packet.tenant, "Payload", "")   -replace '[^/]+$', ""
    [String]$internet_rules_path = $nsx_api_handle.RulePath($failed_packet.tenant, "Internet", "") -replace '[^/]+$', ""
    return @(
        $nsx_api_handle.ApiGet($payload_rules_path).results
        $nsx_api_handle.ApiGet($internet_rules_path).results
    ) | Where-Object {
        $dependency_path -in $_.services -or `
        $dependency_path -in $_.source_groups -or `
        $dependency_path -in $_.destination_groups
    } | ForEach-Object { $_.id }
}

function DiagnoseWithApi {
    param (
        [NsxApiHandle]$nsx_api_handle,
        [DataPacket]$failed_packet,
        [ApiAction[]]$failed_actions
    )

    [Bool]$tried_create = [ApiAction]::Create -in $failed_actions
    [Bool]$tried_update = [ApiAction]::Update -in $failed_actions
    [Bool]$tried_delete = [ApiAction]::Delete -in $failed_actions
    [Bool]$already_exists = $nsx_api_handle.ResourceExists($failed_packet)
    [String[]]$missing_depends = CheckDependenciesFromApi $nsx_api_handle $failed_packet
    [String[]]$dependees_found = CheckDependeesFromApi $nsx_api_handle $failed_packet $tried_delete

    # Give Feedback
    [String[]]$faults = @()
    if (($tried_create -or $tried_update) -and $missing_depends.Count) {
        $faults += @( # Can only happen for FW Rules
            "The rule depends on these nonexistent resources:"
            @($missing_depends | ForEach-Object { "- '$_'" })
        )
    }
    if ($tried_create -and -not $tried_update -and $already_exists) {
        $faults += @(
            "The resource could not be created because it already exists"
            "You could try updating it instead"
        )
    }
    if ($tried_update -and -not $tried_create -and -not $already_exists) {
        $faults += @(
            "The resource could not be updated because it doesn't exist"
            "You could try creating it instead"
        )
    }
    if ($tried_delete -and $dependees_found.Count) {
        $faults += @( # Can only happen for Security Groups and Services
            "One or more rules still depends on this resource:"
            @($dependees_found | ForEach-Object { "- '$_'" })
        )
    }
    if ($tried_delete -and -not $already_exists) {
        $faults += "The resource could not be deleted because it doesn't exist"
    }
    if ($faults.Count -eq 0) {
        $faults += @(
            "It's possible that the API has run into a collision"
            "You could try deploying the request for this resource again"
        )
    }
    return $faults
}


# Abstracted Interface
function DiagnoseFailure {
    param (
        [IOHandle]$io_handle,
        [DataPacket]$failed_packet,
        [ApiAction[]]$failed_actions,
        [NsxApiHandle]$nsx_api_handle
    )
    if ($nsx_api_handle) { return DiagnoseWithApi $nsx_api_handle $failed_packet $failed_actions }
    else { return DiagnoseWithImg $io_handle $failed_packet $failed_actions }
}
