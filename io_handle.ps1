enum ApiAction {
    Create
    Update
    Delete
}

class DataPacket {
    [Object]$data
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
        try { $this.nsx_image = Get-Content $nsx_image_path -ErrorAction Stop | ConvertFrom-Json | ConvertTo-Hashtable }
        catch { $this.nsx_image = @{} }
    }

    [Void] UpdateNsxImage ([Hashtable]$input_data, [ApiAction]$action) {
        function update_recursive([Hashtable]$source, [Hashtable]$target, [Bool]$delete) {
            foreach ($key in $source.Keys) {
                $value = $source[$key]
                if ($value -is [Hashtable]) {
                    if (-not $delete -and -not $target[$key] ) { $target[$key] = @{} }
                    general $value $target[$key] $delete
                    if ($delete -and -not $target[$key].Keys.Length) { $target.Remove($key) }
                } else {
                    if ($delete) { $target.Remove($key) }
                    else { $target[$key] = $value }
                }
            }
        }
        update_recursive $input_data $this.nsx_image ($action -eq [ApiAction]::Delete)
    }
    
    [Void] SaveNsxImage () {
        $this.nsx_image | ConvertTo-Json -Depth 8 -Compress | Set-Content -Path $this.nsx_image_path
    }

    [String] GetLog () {
        return Join $this.log "`n"
    }

    [DataPacket[]]GetResourceData ([Hashtable]$resource_config) { throw [System.NotImplementedException] "GetResourceData must be implemented!" }
    [DataPacket]ParseToIntermediate ([Hashtable]$resource_config, [DataPacket]$data) { throw [System.NotImplementedException] "ParseToIntermediate must be implemented!" }
    [Void] UpdateOutput ([Hashtable]$resource_config, [OutputValue]$value) { throw [System.NotImplementedException] "UpdateOutput must be implemented!" }
    [Void] Release () { $this.SaveNsxImage() }
}

class ExcelHandle : IOHandle {
    [__ComObject]$app
    [__ComObject]$workbook
    [Bool]$should_close
    
    ExcelHandle ([String]$file_path, [String]$nsx_image_path) : base ($nsx_image_path) {
        try {
            $this.app = [Runtime.Interopservices.Marshal]::GetActiveObject('Excel.Application')
            foreach ($wb in $this.app.Workbooks) {
                if ($wb.FullName -eq $file_path) {
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

    [Hashtable[]] GetResourceData ([Hashtable]$resource_config) {
        [String]$sheet_name = $resource_config.excel_sheet_name
        [Int]$output_column = $resource_config.format.Length + 1
        try { $sheet = $this.workbook.Worksheets.Item($sheet_name) }
        catch { throw Format-Error -Message "Sheet '$sheet_name' could not be opened" -Cause $_.Exception.Message }

        $num_rows = $sheet.UsedRange.Rows.Count
        [Hashtable[]]$data = @()

        for ($row = 1; $row -le $num_rows; $row++) {
            # Only include data if the output-cell is empty
            if (-not $sheet.Cells.Item($row, $output_column).Text) {
                $row_data = @{
                    cells = @()
                    row_index = $row
                }

                $is_empty = $true
                for ($col = 1; $col -lt $output_column; $col++) {
                    $cell_data = $sheet.Cells.Item($row, $col).Text
                    $is_empty = ($is_empty -and ($cell_data.Trim() -eq ""))
                    $row_data.cells += $cell_data
                }

                if (-not $is_empty) { $data += $row_data }
            }
        }

        return $data 
    }

    [DataPacket]ParseToIntermediate ([Hashtable]$resource_config, [DataPacket]$data) {
        return & $resource_config.excel_parser -data $data
    }

    [Void] UpdateOutput ([Hashtable]$resource_config, [OutputValue]$value) {
        [Int]$output_column = $resource_config.format.Length + 1
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

class JsonHandle : IOHandle {
    [Hashtable]$input_data

    JsonHandle ([String]$raw_json, [String]$nsx_image_path) : base ($nsx_image_path) {
        $this.input_data = $raw_json | ConvertFrom-Json | ConvertTo-Hashtable
    }

    [Hashtable[]] GetResourceData ([Hashtable]$resource_config) {
        $data = @($this.input_data[$resource_config.field_name])
        if (-not $data) { return @() }
        if (-not $data -is [Hashtable[]]) { throw "Received invalid json format" }
        [Hashtable[]]$output_data = @()
        for ($i = 0; $i -lt $data.Length; $i++) {
            $packet = @()
            foreach ($key in $resource_config.format | ForEach-Object { $_.field_name }) {
                $packet += Join $data[$i][$key] "`n"
            }
            $output_data += @{
                row_index = $i
                cells = $packet
            }
        }
        return $output_data
    }

    [Void] UpdateOutput ([Hashtable]$resource_config, [OutputValue]$value) {
        $this.log += $value.message
    }
}