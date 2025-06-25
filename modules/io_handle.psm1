using module ".\shared_types.psm1"
using module ".\converters.psm1"
using module ".\utils.psm1"

class OutputValue {
    [Hashtable]$additional_output
    [String]$short_info
    [String]$message
    [Int]$excel_index

    OutputValue ([String]$message, [String]$short_info, [Int]$excel_index) {
        $this.message = $message
        $this.short_info = $short_info
        $this.excel_index = $excel_index
        $this.additional_output = @{}
    }
    OutputValue ([String]$message, [String]$short_info, [Int]$excel_index, [Hashtable]$additional_output) {
        $this.message = $message
        $this.short_info = $short_info
        $this.excel_index = $excel_index
        $this.additional_output = $additional_output
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
    [String]$tenant
    [String]$file_path
    [String]$request_id
    [Hashtable]$sheets = @{}
    
    ExcelHandle ([String]$nsx_image_path, [String]$file_path, [String]$tenant, [String]$request_id) : base ($nsx_image_path) {
        if ($null -eq (Get-Module ImportExcel)) { Import-Module ImportExcel -ErrorAction Stop }
        if (-not (Test-Path "$file_path")) { throw "'$file_path' was not found :(" }
        $ext = [System.IO.Path]::GetExtension($file_path)
        if ($ext -notmatch '.xlsx$|.xlsm$') { throw "Extension type '$ext' is not supported :(" }
        $this.request_id = $request_id
        $this.file_path = $file_path
        $this.tenant = $tenant
    }

    [PSCustomObject] GetSheet ([String]$sheet_name) {
        if ($null -eq $this.sheets[$sheet_name]) {
            try { [PsCustomObject[]]$sheet_contents = Import-Excel -Path $this.file_path -WorksheetName $sheet_name }
            catch { throw Format-Error -Message "Sheet '$sheet_name' could not be opened" -Cause $_.Exception.Message }
            if ($sheet_contents.Count -eq 0) { return $null }
            [Int]$len = $sheet_contents.Count
            while (-not ([String]$sheet_contents[$len - 1].PSObject.Properties.Value).Trim()) { $len-- }
            $this.sheets[$sheet_name] = [PSCustomObject]@{
                contents = [Hashtable[]]($sheet_contents[0..$len] | ConvertTo-Hashtable)
                native_keys = $sheet_contents[0].PSObject.Properties.Name
                additional_output_keys = @()
            }
        }
        return $this.sheets[$sheet_name]
    }

    [DataPacket[]] GetResourceData ([Hashtable]$resource_config) {
        [String]$sheet_name = $resource_config.excel_sheet_name
        [PSCustomObject]$sheet = $this.GetSheet($sheet_name)
        if ($null -eq $sheet) { return @() }
        [Hashtable[]]$sheet_contents = $sheet.contents
        [String[]]$sheet_native_keys = $sheet.native_keys
        [String]$output_key = $sheet_native_keys[$resource_config.excel_format.Count]
        [DataPacket[]]$data_packets = @()
        for ($row = 0; $row -lt $sheet_contents.Count; $row++) {
            # Only include data if the output-cell is empty
            if (-not $sheet_contents[$row].$output_key) {
                [String]$origin_info = "row $($row + 2) in $sheet_name"
                [DataPacket]$data_packet = [DataPacket]::New(@{}, $resource_config, $this.tenant, $origin_info, $row)
                [Bool]$is_empty = $true
                for ($col = 0; $col -lt $resource_config.excel_format.Count; $col++) {
                    $key = $resource_config.excel_format[$col]
                    $cell_data = [String]$sheet_contents[$row]."$($sheet_native_keys[$col])"
                    if ($cell_data) { $cell_data = $cell_data.Split([System.Environment]::NewLine).Trim() }
                    $is_empty = ($is_empty -and (-not $cell_data))
                    $data_packet.value_origins[$key] = "column $([Char]([Int][Char]'A' + $col))"
                    $data_packet.data[$key] = $cell_data
                }
                if (-not $is_empty) { $data_packets += $data_packet }
            }
        }

        return $data_packets | ForEach-Object { PrepareExcelData -data_packet $_ -request_id $this.request_id }
    }

    [Void] UpdateOutput ([Hashtable]$resource_config, [OutputValue]$value) {
        [Int]$index = $value.excel_index
        [String]$sheet_name = $resource_config.excel_sheet_name
        [PSCustomObject]$sheet = $this.GetSheet($sheet_name)
        [Hashtable]$row_contents = $sheet.contents[$index]
        [String]$output_key = $sheet.native_keys[$resource_config.excel_format.Count]
        foreach ($key in $value.additional_output.Keys) {
            [String]$native_key = $sheet.native_keys[$resource_config.excel_format.IndexOf($key)]
            if ($native_key -notin $sheet.additional_output_keys) { $sheet.additional_output_keys += $native_key }
            $row_contents[$native_key] = $value.additional_output[$key]
        }
        if (-not $value.short_info) { return }
        if ($row_contents[$output_key] -ne $value.short_info) {
            $row_contents[$output_key] = Join @($row_contents[$output_key], $value.short_info) ", "
        }
    }
    
    [Void] Release () {
        $this.SaveNsxImage()
        foreach ($sheet_name in $this.sheets.Keys) {
            [PSCustomObject]$sheet = $this.GetSheet($sheet_name)
            [Int]$last_row = $sheet.contents.Count + 1
            [Int]$output_col = $sheet.native_keys.Count
            [String]$output_col_str = [Char]([Int][Char]"A" + $output_col - 1)
            [String]$format_range = "${output_col_str}2:${output_col_str}${last_row}"
            [String]$output_key = $sheet.native_keys[$output_col - 1]
            @($sheet.contents | ForEach-Object {
                [PSCustomObject]@{ $output_key = $_[$output_key] }
            }) | Export-Excel -Path $this.file_path -WorksheetName $sheet_name -StartColumn $output_col -ConditionalText @(
                New-ConditionalText -ConditionalType ContainsText "Successful" -BackgroundColor "LightGreen" -ConditionalTextColor "Green" -Range $format_range
                New-ConditionalText -ConditionalType NotContainsText "Successful" -BackgroundColor "Pink" -ConditionalTextColor "Red" -Range $format_range
            )
            foreach ($key in $sheet.additional_output_keys) {
                [Int]$column = $sheet.native_keys.IndexOf($key) + 1
                @($sheet.contents | ForEach-Object {
                    [PSCustomObject]@{ $key = $_[$key] }
                }) | Export-Excel -Path $this.file_path -WorksheetName $sheet_name -StartColumn $column -CellStyleSB {
                    param ($worksheet)
                    [String]$add_col_str= [Char]([Int][Char]"A" + $column - 1)
                    $range = $worksheet.Cells["${add_col_str}2:${add_col_str}${last_row}"]
                    $range.Style.WrapText = $true
                }
            }
        }
    }
}

class JsonHandle : IOHandle {
    [String[]]$accepted_keys = @("security_groups", "services", "rules")
    [Hashtable]$input_data
    [String]$request_id

    JsonHandle ([String]$raw_json, [String]$nsx_image_path, [String]$tenant, [String]$request_id) : base ($nsx_image_path) {
        try { [Hashtable]$data = $raw_json | ConvertFrom-Json | ConvertTo-Hashtable }
        catch { $this.Release(); throw Format-Error -Message "Received incompatible json data!" -Hints @(
            "Ensure that your top-level json structure is an object!"
        ) -Cause $_.Exception.Message }
        $this.input_data =  if ($tenant) { @{ $tenant = $data } } else { $data }
        $this.request_id = $request_id
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
            [String]$origin_info_base = "$tenant.$($resource_config.field_name)"
            $raw = $this.input_data[$tenant][$resource_config.field_name]
            if ($raw) { CollapseNested $raw $resource_config.json_nesting `
            | ForEach-Object { 
                [String]$origin_info = $origin_info_base + $_["__o"]; $_.Remove("__o")
                [DataPacket]::New($_, $resource_config, $tenant, $origin_info)
            } }
        } | ForEach-Object { PrepareJsonData -data_packet $_ -request_id $this.request_id })
    }

    [Void] UpdateOutput ([Hashtable]$resource_config, [OutputValue]$value) {}
}
