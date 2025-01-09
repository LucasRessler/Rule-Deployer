using module ".\io_handle.psm1"

function ParseIntermediate {
    param(
        [Hashtable]$format,
        [DataPacket]$data_packet,
        [Hashtable]$unique_check_map,
        [Bool]$only_deletion
    )

    [String[]]$errors = @()
    [DataPacket]$parsed_packet = [DataPacket]::New(@{})

    foreach ($key in $format.Keys) {
        $dbg_name = $format[$key]["dbg_name"]
        $generator = $format[$key]["generator"]
        $subparser = $format[$key]["subparser"]
        $postparser = $format[$key]["postparser"]
        $regex_info = $format[$key]["regex_info"]
        $regex = ` # If no regex is specified, use '.*' to match anything
            if ($format[$key]["regex"]) { $format[$key]["regex"] }
            else { ".*" }
        $value = ` # If generator is specified, use it to create the value
            if ($generator) { & $generator -data $data_packet.data }
            else { $data_packet.data[$key] }

        if (-not $value) {
            [Bool]$optional_for_delete = -not $format[$key]["required_for_deletion"] 
            [Bool]$optional = $format[$key]["is_optional"] -or ($only_deletion -and $optional_for_delete)
            if (-not $optional) { $errors += "Missing ${dbg_name}" }
            continue
        }

        $value = $value.Trim()
        if ($format[$key]["is_unique"] -and $unique_check_map) {
            if ($unique_check_map[$key]) {
                if ($unique_check_map[$key][$value]) {
                    $errors += Format-Error -Message "Duplicate ${dbg_name}" -Hints @(
                        "'$value' was already used"
                        "Ensure that each ${dbg_name} is unique"
                    )
                }
                else { $unique_check_map[$key][$value] = $true }
            }
            else { $unique_check_map[$key] = @{ $value = $true } }
        }

        $value = @($value) | ForEach-Object {
            if (-not [Regex]::IsMatch($value, "^$regex$")) {
                $errors += Format-Error -Message "Invalid ${dbg_name}: '$value'" -Hints @($regex_info)
            }
            if ($subparser) {
                try { & $subparser -value $value }
                catch {
                    $errors += Format-Error -Message "Invalid ${dbg_name}: '$value'" -Cause $_.Exception.Message
                    continue
                }
            }
            else { $value }
        }

        if ($postparser) {
            try { $value = & $postparser -value $value }
            catch { $errors += Format-Error -Message "Invalid ${dbg_name}" -Cause $_.Exception.Message }
        }

        $parsed_packet.data[$key] = $value
    }

    if ($errors) { throw $errors -join "`n" }
    foreach ($k in $format.Keys) { $data_packet.data.Remove($k) }
    foreach ($k in $data_packet.data.Keys) {
        $v = $data_packet.data[$k] 
        if ($v) { Write-Warning "Value will be ignored: {'$k': '$v'}" }
    }
    return $parsed_packet
}

# Sub- and Post-Parsers
function FailOnMatch ([String]$value, [String]$regex, [String]$fail_message) {
    if ([Regex]::IsMatch($value, "^$regex$")) { throw $fail_message }
    else { $value }
}

function ParseIP ([String]$raw_input) {
    # This function expects a prevalidated ipv4 address
    # Either with or without CIDR
    # u8.u8.u8.u8 | u8.u8.u8.u8/cidr

    $ip = @{}
    $split_input = $raw_input.Split("/")
    $ip["address"] = $split_input[0]
    if ($split_input[1]) { $ip["net"] = $split_input[1] }

    $ip
}

function ParsePort ([String]$raw_input) {
    # This function expects a prevalidated word:port pair
    # Either with a single port address or a range
    # word:port | word:start-end
    # Checked here:
    # - `word` is a valid protocol
    # - `start` less than or equal to `end`

    $split_input = $raw_input.Split(":")
    $protocol = $split_input[0].Trim().ToUpper()

    if ($protocol -in @("ICMP", "ICMP4", "ICMPV4", "ICMP6", "ICMPV6")) {
        throw "Protocol $protocol not supported - Please use default ICMP services (i.e. 'ICMP ALL' or 'ICMP Echo Request')"
    }
    if ($protocol -notin @("TCP", "UDP")) {
        throw "Invalid Protocol: '$protocol' - Expected TCP or UDP"
    }

    $port = @{ protocol = $protocol }
    $port_addresses = $split_input[1].Split("-")
    $port["start"] = $port_addresses[0].Trim()
    $port["end"] = if ($port_addresses[1]) {
        $port_addresses[1].Trim()
    } else {
        $port_addresses[0].Trim()
    }

    if ([Int]($port["start"]) -gt [Int]($port["end"])) {
        throw "Invalid Range: '$($port["start"])-$($port["end"])'"
    }

    $port
}

function ParseArrayWithAny ([String[]]$array) {
    # returns the input array if it doesn't include "any"
    # returns an empty array when the input is `@("any")` (case insensitive)
    # throws in any other case

    if ("any" -notin $array) {
        $array
    } else {
        if ($array.Length -eq 1) { @() }
        else { throw "Can't have more than 1 element when using 'any'" }
    }
}
