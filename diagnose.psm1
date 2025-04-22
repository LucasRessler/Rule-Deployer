using module ".\nsx_api_handle.psm1"
using module ".\shared_types.psm1"
using module ".\io_handle.psm1"

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

function DiagnoseFailure {
    param (
        [IOHandle]$io_handle,
        [DataPacket]$failed_packet,
        [ApiAction[]]$failed_actions,
        [NsxApiHandle]$nsx_api_handle
    )

    [Bool]$tried_create = [ApiAction]::Create -in $failed_actions
    [Bool]$tried_update = [ApiAction]::Update -in $failed_actions
    [Bool]$tried_delete = [ApiAction]::Delete -in $failed_actions

    [Bool]$tracked = if ($nsx_api_handle) {
        $nsx_api_handle.ResourceExists($failed_packet)
    } else {
        $null -ne $io_handle.GetImage($failed_packet.GetImageKeys())
    }

    [String[]]$missing_depends = if ($nsx_api_handle) {
        CheckDependenciesFromApi $nsx_api_handle $failed_packet
    } else {
        CheckDependenciesFromImg $io_handle $failed_packet
    }

    [String[]]$dependees_found = if ($nsx_api_handle) {
        CheckDependeesFromApi $nsx_api_handle $failed_packet $tried_delete
    } else {
        CheckDependeesFromImg $io_handle $failed_packet $tried_delete
    }
    
    # Give feedback
    switch ($true) {
        ($tried_create -and $tried_update) {
            if ($missing_depends.Count) {
            return @( # Can only happen for FW Rules
                "Make sure that all security groups and services used in the rule exist"
                "It's likely that one or more of the following resources don't exist:"
                @($missing_depends | ForEach-Object { "- '$_'" })
                "Note: I can only make statements for resources that were modified with this tool"
            ) } else {
            return @(
                "It's possible that the API has run into a collision"
                "You could try creating or updating the resource again"
            ) }
        }
        ($tried_create) {
            if ($missing_depends.Count) {
            return @( # Can only happen for FW Rules
                "Make sure that all security groups and services used in the rule exist"
                "It's likely that one or more of the following resources don't exist:"
                @($missing_depends | ForEach-Object { "- '$_'" })
                "Note: I can only make statements for resources that were modified with this tool"
            ) } elseif ($tracked) {
            return @(
                "The resource was found in the NSX-Image"
                "It's very likely that it already exists"
                "You could try updating it instead"
            ) } else {
            return @(
                "The resource was not found in the NSX-Image"
                "It's possible that the API has run into a collision"
                "You could try creating the resource again in this case"
                "It's also possible that it already exists, if it was created manually or with a different tool"
                "You could try updating it instead"
            ) }
        }
        ($tried_update) {
            if (-not $tracked) {
                "The resource was not found in the NSX-Image"
                "It's likely that it doesn't exist yet"
                "You could try creating it instead"
            } elseif ($missing_depends.Count) {
            return @( # Can only happen for FW Rules
                "Make sure that all security groups and services used in the rule exist"
                "It's likely that one or more of the following resources don't exist:"
                @($missing_depends | ForEach-Object { "- '$_'" })
                "Note: I can only make statements for resources that were modified with this tool"
            ) } else {
            return @(
                "The resource was found in the NSX-Image"
                "It's possible that the API has run into a collision"
            ) }
        }
        ($tried_delete) {
            if ($dependees_found.Count) {
            return @( # Can only happen for Security Groups and Services
                "Make sure that no rules still use this resource"
                "It's likely that one or more of the following rules still use it:"
                @($dependees_found | ForEach-Object { "- '$_'" })
                "Note: I can only make statements for resources that were modified with this tool"
            ) } elseif ($tracked) {
            return @(
                "The resource was found in the NSX-Image"
                "It's possible that the API has run into a collision"
            ) } else {
            return @(
                "The resource was not found in the NSX-Image"
                "It's likely that it doesn't exists at all"
            ) }
        }
    }
}
