using module ".\shared_types.psm1"
using module ".\io_handle.psm1"

function DiagnoseFailure {
    param (
        [IOHandle]$io_handle,
        [DataPacket]$failed_packet,
        [ApiAction[]]$failed_actions
    )
    function scrape_recursive([Hashtable]$nested, [Hashtable]$store, [String[]]$store_keys) {
        [String[]]$keys = $nested.Keys
        foreach ($key in $keys) {
            if ($key -in $store_keys) { $store[$key] = $nested[$key] }
            if ($nested[$key] -is [Hashtable]) { scrape_recursive $nested[$key] $store $store_keys }
            else { $nested.Remove($key) }
        }
    }

    [Bool]$tried_create = [ApiAction]::Create -in $failed_actions
    [Bool]$tried_update = [ApiAction]::Update -in $failed_actions
    [Bool]$tried_delete = [ApiAction]::Delete -in $failed_actions
    [String]$tenant = $failed_packet.tenant
    [ResourceId]$resource_id = $failed_packet.resource_config.id

    [Hashtable]$dependency_store = @{}
    [Hashtable]$needle = $failed_packet.GetImageConversion()
    scrape_recursive $needle $dependency_store @("services", "sources", "destinations")
    $tracked = $io_handle.ExistsInNsxImage($needle)

    # Check dependencies
    [String[]]$depends_not_found = @()
    if ($resource_id -eq [ResourceId]::Rule) {
        foreach ($used_service in $dependency_store["services"]) {
            $service_needle = @{ $tenant = @{ services = @{ $used_service = @{} } } }
            if (-not ($io_handle.ExistsInNsxImage($service_needle))) { $depends_not_found += $used_service }
        }
        foreach ($used_source in $dependency_store["sources"]) {
            $source_needle = @{ $tenant = @{ security_groups = @{ $used_source = @{} } } }
            if (-not ($io_handle.ExistsInNsxImage($source_needle))) { $depends_not_found += $used_source }
        }
        foreach ($used_destination in $dependency_store["destinations"]) {
            $destination_needle = @{ $tenant = @{ security_groups = @{ $used_destination = @{} } } }
            if (-not ($io_handle.ExistsInNsxImage($destination_needle))) { $depends_not_found += $used_destination }
        }
    }

    # Check reverse dependencies
    [String[]]$dependees_found = @()
    if ($resource_id -ne [ResourceId]::Rule) {
        [String]$name = $needle[$tenant][$failed_packet.resource_config.field_name].Keys[0]
        [Hashtable]$rules_for_this_tenant = $io_handle.nsx_image[$tenant]["rules"]
        foreach ($gateway in $rules_for_this_tenant.Keys) {
            [Hashtable]$service_requests = $rules_for_this_tenant[$gateway]
            foreach ($service_request in $service_requests.Keys) {
                [Hashtable]$indeces = $service_requests[$service_request]
                foreach ($index in $indeces.Keys) {
                    [Hashtable]$rule = $indeces[$index]
                    [String[]]$depends = @(
                        $rule["services"]
                        $rule["sources"]
                        $rule["destinations"]
                    )
                    if ($name -in $depends) { $dependees_found += $rule["name"] }
                }
            }
        }
    }
    
    # Give feedback
    switch ($true) {
        ($tried_create -and $tried_update) {
            if ($depends_not_found.Count) {
            return @( # Can only happen for FW Rules
                "Make sure that all security groups and services used in the rule exist"
                "It's likely that one or more of the following resources don't exist:"
                @($depends_not_found)
                "Note: I can only make statements for resources that were modified with this tool"
            ) } else {
            return @(
                "It's possible that the API has run into a collision"
                "You could try creating or updating the resource again"
            ) }
        }
        ($tried_create) {
            if ($tracked) {
            return @(
                "The resource was found in the NSX-Image"
                "It's very likely that it already exists"
                "You could try updating it instead"
            ) } elseif ($depends_not_found.Count) {
            return @( # Can only happen for FW Rules
                "Make sure that all security groups and services used in the rule exist"
                "It's likely that one or more of the following resources don't exist:"
                @($depends_not_found)
                "Note: I can only make statements for resources that were modified with this tool"
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
            if ($depends_not_found.Count) {
            return @( # Can only happen for FW Rules
                "Make sure that all security groups and services used in the rule exist"
                "It's likely that one or more of the following resources don't exist:"
                @($depends_not_found)
                "Note: I can only make statements for resources that were modified with this tool"
            ) } elseif ($tracked) {
            return @(
                "The resource was found in the NSX-Image"
                "It's possible that the API has run into a collision"
            ) } else {
            return @(
                "The resource was not found in the NSX-Image"
                "It's likely that it doesn't exist yet"
                "You could try creating it instead"
            ) }
        }
        ($tried_delete) {
            if ($dependees_found.Count) {
            return @(
                "Make sure that no rules still use this resource"
                "It's likely that one or more of the following rules still use it:"
                @($dependees_found)
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
