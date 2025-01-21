using module ".\io_handle.psm1"

function DiagnoseFailure {
    param (
        [IOHandle]$io_handle,
        [DataPacket]$failed_packet,
        [ApiAction[]]$failed_actions
    )
    function clear_recursive([Hashtable]$nested, [Hashtable]$store, [String[]]$store_keys) {
        [String[]]$keys = $nested.Keys
        foreach ($key in $keys) {
            if ($key -in $store_keys) { $store[$key] = $nested[$key] }
            if ($nested[$key] -is [Hashtable]) { clear_recursive $nested[$key] $store $store_keys }
            else { $nested.Remove($key) }
        }
    }

    [Bool]$tried_create = [ApiAction]::Create -in $failed_actions
    [Bool]$tried_update = [ApiAction]::Update -in $failed_actions
    [Bool]$tried_delete = [ApiAction]::Delete -in $failed_actions

    [Hashtable]$dependency_store = @{}
    [Hashtable]$needle = & $failed_packet.resource_config.convert_to_image $failed_packet
    clear_recursive $needle $dependency_store @("services", "sources", "destinations")
    $tracked = $io_handle.ExistsInNsxImage($needle)

    # Check dependencies
    $depends_not_found = @()
    foreach ($used_service in $dependency_store["services"]) {
        $service_needle = @{ $failed_packet.tenant = @{ services = @{ $used_service = @{} } } }
        if (-not ($io_handle.ExistsInNsxImage($service_needle))) { $depends_not_found += $used_service }
    }
    foreach ($used_source in $dependency_store["sources"]) {
        $source_needle = @{ $failed_packet.tenant = @{ security_groups = @{ $used_source = @{} } } }
        if (-not ($io_handle.ExistsInNsxImage($source_needle))) { $depends_not_found += $used_source }
    }
    foreach ($used_destination in $dependency_store["destinations"]) {
        $destination_needle = @{ $failed_packet.tenant = @{ security_groups = @{ $used_destination = @{} } } }
        if (-not ($io_handle.ExistsInNsxImage($destination_needle))) { $depends_not_found += $used_destination }
    }
    
    # Give feedback
    switch ($true) {
        ($tried_create -and $tried_update) {
            if ($depends_not_found.Count) {
            return @(
                "Make sure that all security groups and services used in the rule exist"
                ($depends_not_found | ForEach-Object { "$_ not found in the NSX-Image" })
                "Note: The NSX-Image only represents resources that were modified with this tool"
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
            return @(
                "Make sure that all security groups and services used in the rule exist"
                ($depends_not_found | ForEach-Object { "$_ not found in the NSX-Image" })
                "Note: The NSX-Image only represents resources that were modified with this tool"
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
            return @(
                "Make sure that all security groups and services used in the rule exist"
                ($depends_not_found | ForEach-Object { "$_ not found in the NSX-Image" })
                "Note: The NSX-Image only represents resources that were modified with this tool"
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
                ($dependees_found | ForEach-Object { "$_ found in the NSX-Image" })
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
