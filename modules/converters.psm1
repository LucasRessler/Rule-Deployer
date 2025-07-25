using module ".\shared_types.psm1"
using module ".\utils.psm1"

# $TEST_PREFIX = "LR-Test---"

# Json Preparation
function RulesDataFromJsonData ([DataPacket]$data_packet) {
    [String[]]$gateways = @()
    foreach ($gw in $data_packet.data["gateway"]) { $gateways += "$gw"}
    if ($gateways.Count -eq 0) { $gateways += "T1 Payload" }
    return @($gateways | ForEach-Object {
        [DataPacket]$new_packet = [DataPacket]::New($data_packet, (DeepCopy $data_packet.data))
        $new_packet.data["gateway"] = $_
        $new_packet
    })
}

# Excel Preparation
function SplitRequestIDsInExcelData ([DataPacket]$data_packet) {
    [String[]]$req = $data_packet.data["all_request_ids"]
    if ($req.Count -gt 0) { $data_packet.data["request_id"] = $req[0] }
    if ($req.Count -gt 1) { $data_packet.data["update_requests"] = $req[1..$req.Count] }
    $data_packet.value_origins["request_id"] = $data_packet.value_origins["all_request_ids"]
    $data_packet.value_origins.Remove("all_request_ids")
    $data_packet.data.Remove("all_request_ids")
    return $data_packet
}

function RulesDataFromExcelData ([DataPacket]$data_paket) {
    [String[]]$gateways = @()
    if ($data_packet.data["t0_internet"]) { $gateways += "T0 Internet" }
    if ($data_packet.data["t1_payload"] -or $gateways.Count -eq 0) { $gateways += "T1 Payload" }
    $data_packet.data.Remove("t0_internet")
    $data_packet.data.Remove("t1_payload")
    $data_packet = SplitRequestIDsInExcelData $data_packet
    return @($gateways | ForEach-Object {
        [DataPacket]$new_packet = [DataPacket]::New($data_packet, (DeepCopy $data_packet.data))
        if ($gateways.Count -gt 1) { $new_packet.origin_info += " ($_)" }
        $new_packet.data["gateway"] = $_
        $new_packet
    })
}

# API Converters
function ConvertSecurityGroupsData ([Hashtable]$data, [ApiAction]$action) {
    [String]$name = "$TEST_PREFIX$($data.name)"
    if ($action -eq [ApiAction]::Delete) {
        return @{
            action = "$action"
            elementsToDelete = @("$name (IPSET)")
        }
    }

    [Hashtable]$body = @{
        action = "$action"
        name = $name
        groupType = "IPSET"
        ipAddress = Join @($data.ip_addresses | ForEach-Object { Join @($_.address, $_.net) "/" }) ", "
    }

    [String]$requests = Join @($data.request_id, $data.update_requests) ", "
    [String]$description = Join @($requests, $data.hostname, $data.comment) " - "
    if ($description) { $body["description"] = $description }
    if ($action -eq [ApiAction]::Update) { $body["elementToUpdate"] = "$name (IPSET)" }
    return $body
}

function ConvertServicesData ([Hashtable]$data, [ApiAction]$action) {
    [String]$name = "$TEST_PREFIX$($data.name)"
    if ($action -eq [ApiAction]::Delete) {
        return @{
            action = "$action"
            elementsToDelete = @($name)
        }
    }

    [Hashtable]$body =  @{
        action = "$action"
        name = $name
    }

    [Hashtable]$used_protocols = @{}
    foreach ($portrange in $data.ports) {
        [String]$protocol = $portrange.protocol.ToUpper()
        [String]$portstring = $portrange.start
        if ($portrange.start -ne $portrange.end) { $portstring += "-$($portrange.end)" }
        if ($used_protocols[$protocol]) { $used_protocols[$protocol] += $portstring }
        else { $used_protocols[$protocol] = @($portstring) }
    }

    [Int]$i = 1
    foreach ($protocol in $used_protocols.Keys) {
        [String[]]$portranges = $used_protocols[$protocol]
        $body["protocol$i"] = $protocol
        $body["destinationPorts$i"] = $portranges
        $i++
    }

    [String]$requests = Join @($data.request_id, $data.update_requests) ", "
    [String]$description = Join @($requests, $data.comment) " - "
    if ($description) { $body["description"] = $description }
    if ($action -eq [ApiAction]::Update) { $body["elementToUpdate"] = $name }
    return $body
}

function ConvertRulesData ([Hashtable]$data, [ApiAction]$action) {
    [String]$name = "${TEST_PREFIX}$($data.name)"
    if ($action -eq [ApiAction]::Delete) {
        return @{
            action = "$action"
            gateway = $data.gateway
            elementsToDelete = @($name)
        } 
    }

    [Hashtable]$body = @{
        action = "$action"
        name = $name
        gateway = $data.gateway
        firewallAction = "Allow"
        sourceType = if ($data.sources.Length) { "Group" } else { "Any" }
        destinationType = if ($data.destinations.Length) { "Group" } else { "Any" }
        serviceType = if ($data.services.Length) { "Service" } else { "Any" }
        sources = @($data.sources | ForEach-Object { "${TEST_PREFIX}$_" })
        destinations = @($data.destinations | ForEach-Object { "${TEST_PREFIX}$_" })
        services = @($data.services | ForEach-Object { "${TEST_PREFIX}$_" })
    }

    [String]$comment = Join @( (Join $data.update_requests ", "), $data.comment) " - "
    if ($comment) { $body["comment"] = $comment }
    if ($action -eq [ApiAction]::Update) { $body["elementToUpdate"] = $name }
    return $body
}

# Image Converters
function ImageFromSecurityGroup ([DataPacket]$data_packet) {
    $data = $data_packet.data
    $name = $data.name
    $ip_addresses = @($data.ip_addresses | ForEach-Object {
        Join @($_.address, $_.net) "/"
    }); [Array]::Sort($ip_addresses)
    $image = @{
        name = $name
        group_type = "IPSET"
        ip_addresses = $ip_addresses
    }

    if ($data.comment) { $image["comment"] = $data.comment }
    if ($data.hostname) { $image["hostname"] = $data.hostname }
    if ($data.date_creation) { $image["date_creation"] = $data.date_creation }
    if ($data.request_id) { $image["request_id"] = $data.request_id }
    if ($data.update_requests.Count) { $image["update_requests"] = $data.update_requests }
    $expanded = ExpandCollapsed $image @("name")
    return @{ $data_packet.tenant = @{ security_groups = $expanded } }
}

function ImageFromService ([DataPacket]$data_packet) {
    $data = $data_packet.data
    $name = $data.name
    $ports = @($data.ports | ForEach-Object {
        $port_range = $_.start
        if ($_.end -ne $_.start) { $port_range += "-$($_.end)"}
        Join @($_.protocol, $port_range) ":"
    }); [Array]::Sort($ports)
    $image =  @{
        name = $name
        ports = $ports
    }

    if ($data.comment) { $image["comment"] = $data.comment }
    if ($data.date_creation) { $image["date_creation"] = $data.date_creation }
    if ($data.request_id) { $image["request_id"] = $data.request_id }
    if ($data.update_requests.Count) { $image["update_requests"] = $data.update_requests }
    $expanded = ExpandCollapsed $image @("name")
    return @{ $data_packet.tenant = @{ services = $expanded } }
}

function ImageFromRule ([DataPacket]$data_packet) {
    $data = $data_packet.data
    $name = $data.name
    $image = @{
        gateway = $data.gateway
        cis_id = $data.cis_id
        index = $data.index
        name = $name

        source_type = if ($data.sources.Length) { "Group" } else { "Any" }
        destination_type = if ($data.destinations.Length) { "Group" } else { "Any" }
        service_type = if ($data.services.Length) { "Service" } else { "Any" }

        sources = [String[]]@($data.sources | ForEach-Object { "$_" })
        services = [String[]]@($data.services | ForEach-Object { "$_" })
        destinations = [String[]]@($data.destinations | ForEach-Object { "$_" })
    }

    if ($data.comment) { $image["comment"] = $data.comment }
    if ($data.request_id) { $image["request_id"] = $data.request_id }
    if ($data.date_creation) { $image["date_creation"] = $data.date_creation }
    if ($data.update_requests.Count) { $image["update_requests"] = $data.update_requests}
    $expanded = ExpandCollapsed $image $data_packet.resource_config.json_nesting
    return @{ $data_packet.tenant = @{ rules = $expanded } }
}

# Splitter
function PrepareJsonData {
    param ([DataPacket]$data_packet, [String]$request_id)
    if ($request_id) {
        if ($null -eq $data_packet.data["request_id"]) { $data_packet.data["request_id"] = $request_id }
        else { $data_packet.data["update_requests"] = @($data_packet.data["update_requests"]; $request_id) | Where-Object { $_ } }
    }
    switch ($data_packet.resource_config.id) {
        ([ResourceId]::Rule) { return RulesDataFromJsonData $data_packet }
        default              { return $data_packet }
    }
}

function PrepareExcelData {
    param ([DataPacket]$data_packet, [String]$request_id)
    if ($request_id) { $data_packet.data["all_request_ids"] = @($data_packet.data["all_request_ids"]; $request_id) | Where-Object { $_ } }
    switch ($data_packet.resource_config.id) {
        ([ResourceId]::SecurityGroup) { return SplitRequestIDsInExcelData $data_packet }
        ([ResourceId]::Service)       { return SplitRequestIDsInExcelData $data_packet }
        ([ResourceId]::Rule)          { return RulesDataFromExcelData $data_packet }
        default                       { return $data_packet }
    }
}

function ConvertToInput {
    param ([DataPacket]$data_packet, [ApiAction]$action)
    switch ($data_packet.resource_config.id) {
        ([ResourceId]::SecurityGroup) { return ConvertSecurityGroupsData $data_packet.data $action }
        ([ResourceId]::Service)       { return ConvertServicesData $data_packet.data $action }
        ([ResourceId]::Rule)          { return ConvertRulesData $data_packet.data $action }
        default                       { return $data_packet }
    }
}

function ConvertToImage {
    param ([DataPacket]$data_packet)
    switch ($data_packet.resource_config.id) {
        ([ResourceId]::SecurityGroup) { return ImageFromSecurityGroup $data_packet }
        ([ResourceId]::Service)       { return ImageFromService $data_packet }
        ([ResourceId]::Rule)          { return ImageFromRule $data_packet }
        default                       { return $data_packet }
    }
}
