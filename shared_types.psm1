enum ApiAction {
    Create
    Update
    Delete
}

enum ResourceId {
    SecurityGroup
    Service
    Rule
}

class DataPacket {
    [Hashtable]$data
    [Hashtable]$resource_config
    [String]$tenant
    [String]$origin_info
    [Int]$row_index

    [String]$deployment_id = $null
    [Hashtable]$value_origins = @{}
    [Hashtable]$api_conversions = @{}
    [Hashtable]$img_conversion = $null

    DataPacket ([DataPacket]$source, [Hashtable]$data) {
        $this.Init($data, $source.resource_config, $source.value_origins, $source.tenant, $source.origin_info, $source.row_index)
    }

    DataPacket ([Hashtable]$data, [Hashtable]$resource_config, [String]$tenant, [String]$origin_info) {
        $this.Init($data, $resource_config, @{}, $tenant, $origin_info, 0)
    }

    DataPacket ([Hashtable]$data, [Hashtable]$resource_config, [String]$tenant, [String]$origin_info, [Int]$row_index) {
        $this.Init($data, $resource_config, @{}, $tenant, $origin_info, $row_index)
    }

    [Void] Init ([Hashtable]$data, [Hashtable]$resource_config, [Hashtable]$value_origins, [String]$tenant, [String]$origin_info, [Int]$row_index) {
        $this.data = $data
        $this.tenant = $tenant
        $this.row_index = $row_index
        $this.origin_info = $origin_info
        $this.value_origins = $value_origins
        $this.resource_config = $resource_config
    }

    [Void] ClearCache () {
        $this.api_conversions = @{}
        $this.img_conversion = $null
    }

    [String[]] GetImageKeys() {
        return @(
            $this.tenant
            $this.resource_config.field_name
            $this.resource_config.json_nesting | ForEach-Object { $this.data[$_] }
        )
    }

    [Hashtable] GetImageConversion() {
        if (-not $this.img_conversion) {
            $this.img_conversion = ConvertToImage $this
        }; return $this.img_conversion
    }

    [Hashtable] GetApiConversion([ApiAction]$action) {
        if (-not $this.api_conversions[$action]) {
            $this.api_conversions[$action] = ConvertToInput -data_packet $this -action $action
        }; return $this.api_conversions[$action]
    }
}
