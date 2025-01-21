using module ".\io_handle.psm1"

function DiagnoseFailure {
    param (
        [IOHandle]$io_handle,
        [DataPacket]$failed_packet,
        [ApiAction[]]$failed_actions
    )

    function clear_recursive([Hashtable]$nested) {
        [String[]]$keys = $nested.Keys
        foreach ($key in $keys) {
            if ($nested[$key] -is [Hashtable]) { clear_recursive $nested[$key] }
            else { $nested.Remove($key) }
        }
    }

    [Hashtable]$needle = & $failed_packet.resource_config.convert_to_image $failed_packet
    clear_recursive $needle
    $tracked = $io_handle.ExistsInNsxImage($needle)
    
    switch ($failed_actions) {
        @([ApiAction]::Create) {
            if ($tracked) { @(
                "The resource was found in the NSX-Image"
                "It's very likely that it already exists"
                "You could try updating it instead"
            ) } elseif ($depends_not_found.Count) { @(
                "Make sure that all security groups and services used in the rule exist"
                ($depends_not_found | ForEach-Object { "$_ not found in the NSX-Image" })
            ) } else { @(
                "The resource was not found in the NSX-Image"
                "It's possible that it already exists, if it was created manually or with a different tool"
                "You could try updating it instead"
            ) }
        }
        @([ApiAction]::Update) {
            if ($tracked) { @(

            ) } else { @(
                "The resource was not found in the NSX-Image"
                "It's likely that it doesn't exist yet"
                "You could try creating it instead"
            ) }
        }
        @([ApiAction]::Delete) {
            if ($dependees_found.Count) { @(

            ) } elseif ($tracked) { @(

            ) } else { @(
                "The resource was not found in the NSX-Image"
                "It's possible that it doesn't exists at all"
            ) }
        }
    }
}
