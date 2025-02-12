using module ".\shared_types.psm1"
using module ".\converters.psm1"
using module ".\utils.psm1"

class OutputValue {
    [String]$short_info
    [String]$message
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
    
    IOHandle ([String]$nsx_image_path) {
        $this.nsx_image_path = $nsx_image_path
        try { $img_json = Get-Content $nsx_image_path -ErrorAction Stop } catch { $img_json = "{}" }
        $this.nsx_image = $img_json | ConvertFrom-Json | ConvertTo-Hashtable
    }

    [Hashtable] GetImage ([String[]]$image_keys) {
        function get_recursive([String[]]$keys, [Hashtable]$haystack) {
            if ($keys.Count -eq 0) { return $haystack }
            $sub = $haystack[$keys[0]]
            if ($null -eq $sub -or $sub -isnot [Hashtable]) { return $null }
            return get_recursive $keys[1..$keys.Count] $sub
        }
        return get_recursive $image_keys $this.nsx_image
    }

    [Void] UpdateNsxImage ([Hashtable]$expanded_data, [ApiAction]$action) {
        function is_leaf ([Hashtable]$target) {
            foreach ($key in $target.Keys) {
                if ($target[$key] -is [Hashtable]) { return $false }
            }
            return $true
        }

        [String]$date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        function update_recursive([Hashtable]$source, [Hashtable]$target) {
            foreach ($key in $source.Keys) {
                $value = $source[$key]
                if ($value -isnot [Hashtable]) { continue }
                if (-not $target[$key] ) { $target[$key] = @{} }
                update_recursive $value $target[$key]
                if (-not (is_leaf $target[$key])) { continue }
                if ($action -ne [ApiAction]::Delete) { 
                    $target[$key] = $value
                    if ($action -eq [ApiAction]::Create) { $target[$key]["date_creation"] = $date }
                    if ($action -eq [ApiAction]::Update) { $target[$key]["date_last_update"] = $date }
                } else { $target.Remove($key) }
            }
        }

        update_recursive $expanded_data $this.nsx_image
    }
    
    [Void] SaveNsxImage () {
        CustomConvertToJson -obj $this.nsx_image | Set-Content -Path $this.nsx_image_path
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
                    $data_packet.value_origins[$key] = "column $([Char]([Int][Char]'A' + $col - 1))"
                    $data_packet.data[$key] = $cell_data
                }

                if (-not $is_empty) { $data_packets += $data_packet }
            }
        }

        return $data_packets | ForEach-Object { PrepareExcelData -data_packet $_ }
    }

    [Void] UpdateOutput ([Hashtable]$resource_config, [OutputValue]$value) {
        [Int]$output_column = $resource_config.excel_format.Length + 1
        [String]$sheet_name = $resource_config.excel_sheet_name
        [String]$col = $value.excel_color
        if (-not $value.short_info) { return }
        try { $sheet = $this.workbook.Worksheets.Item($sheet_name) }
        catch { throw Format-Error -Message "Sheet '$sheet_name' could not be opened" -Cause $_.Exception.Message }
        $cell = $sheet.Cells.Item($value.excel_index, $output_column)
        if ($cell.Text -ne $value.short_info) {
            $cell.Value = Join @($cell.Text, $value.short_info) ", "
            if ($col) { $cell.Font.Color = $col }
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
        } | ForEach-Object { PrepareJsonData -data_packet $_ })
    }

    [Void] UpdateOutput ([Hashtable]$resource_config, [OutputValue]$value) {}
}
