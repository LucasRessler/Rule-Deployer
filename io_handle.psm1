using module ".\utils.psm1"

enum ApiAction {
    Create
    Update
    Delete
}

class DataPacket {
    [Hashtable]$data
    [Hashtable]$resource_config
    [String]$tenant
    [String]$origin_info
    [Int]$row_index

    [String]$deployment_id = $null
    [Hashtable]$api_conversions = @{}
    [Hashtable]$img_conversion = $null

    DataPacket ([DataPacket]$source, [Hashtable]$data) {
        $this.Init($data, $source.resource_config, $source.tenant, $source.origin_info, $source.row_index)
    }

    DataPacket ([Hashtable]$data, [Hashtable]$resource_config, [String]$tenant, [String]$origin_info) {
        $this.Init($data, $resource_config, $tenant, $origin_info, 0)
    }

    DataPacket ([Hashtable]$data, [Hashtable]$resource_config, [String]$tenant, [String]$origin_info, [Int]$row_index) {
        $this.Init($data, $resource_config, $tenant, $origin_info, $row_index)
    }

    [Void] Init ([Hashtable]$data, [Hashtable]$resource_config, [String]$tenant, [String]$origin_info, [Int]$row_index) {
        $this.data = $data
        $this.tenant = $tenant
        $this.row_index = $row_index
        $this.origin_info = $origin_info
        $this.resource_config = $resource_config
    }

    [Hashtable] GetImageConversion() {
        if (-not $this.img_conversion) {
            $this.img_conversion = & $this.resource_config.convert_to_image -data_packet $this
        }; return $this.img_conversion
    }

    [Hashtable] GetApiConversion([ApiAction]$action) {
        if (-not $this.api_conversions[$action]) {
            $this.api_conversions[$action] = & $this.resource_config.converter -data $this.data -action $action
        }; return $this.api_conversions[$action]
    }
}

class OutputValue {
    [String]$message
    [String]$short_info
    [String]$excel_color
    [Int]$excel_index

    OutputValue ([String]$message, [String]$short_info, [String]$excel_color, [Int]$excel_index) {
        $this.message = $message
        $this.short_info = $short_info
        $this.excel_color = $excel_color
        $this.excel_index = $excel_index
    }
}

class IOHandle {
    [String]$nsx_image_path
    [Hashtable]$nsx_image
    [String[]]$log = @()
    
    IOHandle ([String]$nsx_image_path) {
        $this.nsx_image_path = $nsx_image_path
        try { $img_json = Get-Content $nsx_image_path -ErrorAction Stop } catch { $img_json = "{}" }
        $this.nsx_image = $img_json | ConvertFrom-Json | ConvertTo-Hashtable
    }

    [Bool] ExistsInNsxImage ([Hashtable]$expanded_data) {
        function exists_recursive([Hashtable]$needle, [Hashtable]$haystack) {
            foreach ($key in $needle.Keys) {
                if ($null -eq $haystack[$key]) { return $false }
                if ($needle[$key] -is [Hashtable]) {
                    if ($haystack[$key] -isnot [Hashtable]) { return $false }
                    if (-not (exists_recursive $needle[$key] $haystack[$key])) { return $false }
                }
            }; return $true
        }
        return exists_recursive $expanded_data $this.nsx_image
    }

    [Void] UpdateNsxImage ([Hashtable]$expanded_data, [ApiAction]$action) {
        function is_leaf ([Hashtable]$target) {
            foreach ($key in $target.Keys) {
                if ($target[$key] -is [Hashtable]) { return $false }
            }
            return $true
        }

        function update_recursive([Hashtable]$source, [Hashtable]$target, [Bool]$delete) {
            [String]$date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            foreach ($key in $source.Keys) {
                $value = $source[$key]
                if ($value -is [Hashtable]) {
                    if (-not $target[$key] ) { $target[$key] = @{} }
                    update_recursive $value $target[$key] $delete
                    if ($delete -and (is_leaf $target[$key])) { $target.Remove($key) }
                } elseif (-not $delete) {
                    if ($action -eq [ApiAction]::Create) { $target["date_creation"] = $date }
                    else { $target["date_last_update"] = $date }
                    # TODO: Update updaterequests non-destructively?
                    $target[$key] = $value
                }
            }
        }

        update_recursive $expanded_data $this.nsx_image ($action -eq [ApiAction]::Delete)
    }
    
    [Void] SaveNsxImage () {
        CustomConvertToJson -obj $this.nsx_image | Set-Content -Path $this.nsx_image_path
    }

    [String] GetLog () {
        return Join $this.log "`n"
    }

    [DataPacket[]]GetResourceData ([Hashtable]$resource_config) { throw [System.NotImplementedException] "GetResourceData must be implemented!" }
    [Void] UpdateOutput ([Hashtable]$resource_config, [OutputValue]$value) { throw [System.NotImplementedException] "UpdateOutput must be implemented!" }
    [Void] Release () { $this.SaveNsxImage() }
}

class ExcelHandle : IOHandle {
    [__ComObject]$app
    [__ComObject]$workbook
    [Bool]$should_close
    [String]$tenant
    
    ExcelHandle ([String]$nsx_image_path, [String]$tenant) : base ($nsx_image_path) {
        $this.tenant = $tenant
    }

    [Void] Open([String]$file_path) {
        try {
            Add-Type -AssemblyName System.Web
            $this.app = [Runtime.Interopservices.Marshal]::GetActiveObject('Excel.Application')
            $sanitised_file_path = if (-not $file_path.StartsWith("https://")) { $file_path }
            else { UrlDecode($file_path.Split("?")[0]) }
            foreach ($wb in $this.app.Workbooks) {
                if ($wb.FullName -eq $sanitised_file_path) {
                    $this.workbook = $wb
                    break
                }
            }
            if (-not $this.workbook) { throw }
            $this.should_close = $false
            Write-Host "Attached to and hid running Excel-Instance."
        } catch {
            try {
                $this.app = New-Object -ComObject Excel.Application
                $this.workbook = $this.app.Workbooks.Open($file_path)
                $this.should_close = $true
                Write-Host "Created new Excel-Instance."
            } catch {
                $this.Release()
                throw $_.Exception.Message
            }
        }
        $this.app.Visible = $false
    }

    [DataPacket[]] GetResourceData ([Hashtable]$resource_config) {
        [String]$sheet_name = $resource_config.excel_sheet_name
        [Int]$output_column = $resource_config.excel_format.Length + 1
        try { $sheet = $this.workbook.Worksheets.Item($sheet_name) }
        catch { throw Format-Error -Message "Sheet '$sheet_name' could not be opened" -Cause $_.Exception.Message }

        $num_rows = $sheet.UsedRange.Rows.Count
        $data_packets = @()

        for ($row = 1; $row -le $num_rows; $row++) {
            # Only include data if the output-cell is empty
            if (-not $sheet.Cells.Item($row, $output_column).Text) {
                [String]$origin_info = "row $row in $sheet_name"
                [DataPacket]$data_packet = [DataPacket]::New(@{}, $resource_config, $this.tenant, $origin_info, $row)
                $is_empty = $true
                for ($col = 1; $col -lt $output_column; $col++) {
                    $key = $resource_config.excel_format[$col - 1]
                    $cell_data = $sheet.Cells.Item($row, $col).Text.Split([System.Environment]::NewLine).Trim()
                    $is_empty = ($is_empty -and ($cell_data -eq ""))
                    $data_packet.data[$key] = $cell_data
                }

                if (-not $is_empty) { $data_packets += $data_packet }
            }
        }

        return $data_packets | ForEach-Object { & $resource_config.prepare_excel -data_packet $_ }
    }

    [Void] UpdateOutput ([Hashtable]$resource_config, [OutputValue]$value) {
        [Int]$output_column = $resource_config.excel_format.Length + 1
        [String]$sheet_name = $resource_config.excel_sheet_name
        $this.log += $value.message
        try { $sheet = $this.workbook.Worksheets.Item($sheet_name) }
        catch { throw Format-Error -Message "Sheet '$sheet_name' could not be opened" -Cause $_.Exception.Message }
        $cell = $sheet.Cells.Item($value.excel_index, $output_column)
        if ($cell.Text -ne $value.short_info) {
            $cell.Value = Join @($cell.Text, $value.short_info) ", "
            $cell.Font.Color = $value.excel_color
        }
    }
    
    [Void] Release () {
        $this.SaveNsxImage()
        if ($this.app) { $this.app.Visible = $this.initially_visible }
        if ($this.should_close) {
            if ($this.workbook) { $this.workbook.Close($true) }
            if ($this.app) { $this.app.Quit() }
        }
        elseif ($this.app) { $this.app.Visible = $true }
        if ($this.workbook) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($this.workbook)
            $this.workbook = $null
        }
        if ($this.app) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($this.app)
            $this.app = $null
        }
        $this.Finalize()
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}

function SplitServicerequestsInExcelData ([DataPacket]$data_packet) {
    [String[]]$req = $data_packet.data.all_servicerequests
    if ($req.Count -gt 0) { $data_packet.data["servicerequest"] = $req[0] }
    if ($req.Count -gt 1) { $data_packet.data["updaterequests"] = $req[1..$req.Count] }
    $data_packet.data.Remove("all_servicerequests")
    return $data_packet
}

function RulesDataFromExcelData ([DataPacket]$data_paket) {
    [String[]]$gateways = @()
    [DataPacket[]]$data_packets = @()
    if ($data_packet.data["t0_internet"]) { $gateways += "T0 Internet" }
    if ($data_packet.data["t1_payload"] -or $gateways.Count -eq 0) { $gateways += "T1 Payload" }
    $data_packet.data.Remove("t0_internet")
    $data_packet.data.Remove("t1_payload")
    $data_packet = SplitServicerequestsInExcelData $data_packet
    foreach ($gateway in $gateways) {
        [DataPacket]$new_packet = [DataPacket]::New($data_packet, (DeepCopy $data_packet.data))
        $new_packet.data["gateway"] = $gateway
        $data_packets += $new_packet
    }
    return $data_packets
}

class JsonHandle : IOHandle {
    [String[]]$accepted_keys = @("security_groups", "services", "rules")
    [Hashtable]$input_data

    JsonHandle ([String]$raw_json, [String]$nsx_image_path, [String]$tenant) : base ($nsx_image_path) {
        try { [Hashtable]$data = $raw_json | ConvertFrom-Json | ConvertTo-Hashtable }
        catch { $this.Release(); throw Format-Error -Message "Received incompatible json data!" -Hints @(
            "Ensure that your top-level json structure is an object!"
        ) -Cause $_.Exception.Message }
        $this.input_data =  if ($tenant) { @{ $tenant = $data } }
        else { $data }
    }

    [String[]]UnusedResources () {
        [String[]]$unused = @()
        foreach ($tenant in $this.input_data.Keys) {
            foreach ($key in $this.input_data[$tenant].Keys) {
                if ($key -notin $this.accepted_keys) { $unused += "resource '$key' for tenant '$tenant'" }
            }
        }
        return $unused
    }

    [DataPacket[]] GetResourceData ([Hashtable]$resource_config) {
        return @($this.input_data.Keys | ForEach-Object {
            [String]$tenant = $_
            [String]$origin_info_base = "'$tenant'.'$($resource_config.field_name)'"
            $raw = $this.input_data[$tenant][$resource_config.field_name]
            if ($raw) { CollapseNested $raw $resource_config.json_nesting `
            | ForEach-Object { 
                [String]$origin_info = $origin_info_base + $_["__o"]; $_.Remove("__o")
                [DataPacket]::New($_, $resource_config, $tenant, $origin_info)
            } }
        })
    }

    [Void] UpdateOutput ([Hashtable]$resource_config, [OutputValue]$value) {
        $this.log += $value.message
    }
}
