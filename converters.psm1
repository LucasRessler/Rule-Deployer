using module ".\utils.psm1"
using module ".\io_handle.psm1"

$TEST_PREFIX = "Arca-Ignis---"

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

    [String]$requests = Join @($data.servicerequest, $data.updaterequests) ", "
    [String]$description = Join @($requests, $data.hostname, $data.comment) " - "
    if ($description) { $body["description"] = $description }
    if ($action -eq [ApiAction]::Update) { $body["elementToUpdate"] = "$name (IPSET)" }
    $body
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
        # TODO: Are specifically the source ports always empty?
        # $body["sourcePorts$i"] = $portranges
        $i++
    }

    [String]$requests = Join @($data.servicerequest, $data.updaterequests) ", "
    [String]$description = Join @($requests, $data.comment) " - "
    if ($description) { $body["description"] = $description }
    if ($action -eq [ApiAction]::Update) { $body["elementToUpdate"] = $name }
    $body
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
        sources = @($data.sources | ForEach-Object { "${TEST_PREFIX}$_ (IPSET)" })
        destinations = @($data.destinations | ForEach-Object { "${TEST_PREFIX}$_ (IPSET)" })
        services = @($data.services | ForEach-Object { "${TEST_PREFIX}$_" })
    }

    if ($data.comment) { $body["comment"] = $data.comment }
    if ($action -eq [ApiAction]::Update) { $body["elementToUpdate"] = $name }
    $body
}

# Image Converters
function ImageFromSecurityGroup ([DataPacket]$data_packet) {
    $data = $data_packet.data
    $name = "$TEST_PREFIX$($data.name)"
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
    if ($data.servicerequest) { $image["servicerequest"] = $data.servicerequest }
    if ($data.updaterequests.Count) { $image["updaterequests"] = $data.updaterequests }
    $expanded = ExpandCollapsed $image @("name")
    @{ $data_packet.tenant = @{ security_groups = $expanded } }
}

function ImageFromService ([DataPacket]$data_packet) {
    $data = $data_packet.data
    $name = "$TEST_PREFIX$($data.name)"
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
    if ($data.servicerequest) { $image["servicerequest"] = $data.servicerequest }
    if ($data.updaterequests.Count) { $image["updaterequests"] = $data.updaterequests }
    $expanded = ExpandCollapsed $image @("name")
    @{ $data_packet.tenant = @{ services = $expanded } }
}

function ImageFromRule ([DataPacket]$data_packet) {
    $data = $data_packet.data
    $name = "${TEST_PREFIX}$($data.name)"
    $image = @{
        gateway = $data.gateway
        servicerequest = $data.servicerequest
        index = $data.index
        name = $name

        source_type = if ($data.sources.Length) { "Group" } else { "Any" }
        destination_type = if ($data.destinations.Length) { "Group" } else { "Any" }
        service_type = if ($data.services.Length) { "Service" } else { "Any" }

        sources = @($data.sources | ForEach-Object { "${TEST_PREFIX}$_" })
        destinations = @($data.destinations | ForEach-Object { "${TEST_PREFIX}$_" })
        services = @($data.services | ForEach-Object { "${TEST_PREFIX}$_" })
    }

    if ($data.comment) { $image["comment"] = $data.comment }
    if ($data.updaterequests.Count) { $image["updaterequests"] = $data.updaterequests}
    $expanded = ExpandCollapsed $image @("gateway", "servicerequest", "index")
    @{ $data_packet.tenant = @{ rules = $expanded } }
}
