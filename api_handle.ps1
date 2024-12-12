enum DeploymentStatus {
    InProgress
    Successful
    Failed
}

class ApiHandle {
    [String]$project_id
    [Hashtable]$headers

    [String]$url_deployments
    [String]$url_items
    
    ApiHandle ([Hashtable]$config, [String]$tenant) {
        $this.url_deployments = $config.api.urls.deployments
        $this.url_items = $config.api.urls.items
        $username = $config.api.credentials.username
        $password = $config.api.credentials.password

        # get refresh token
        try {
            $body = @{
                username = $username
                password = $password
            } | ConvertTo-Json
            $response = Invoke-RestMethod $config.api.urls.refresh_token -Method Post -ContentType "application/json" -Body $body -TimeoutSec 5
            $refresh_token = $response.refresh_token
        } catch {
            throw Format-Error -Message "Failed to obtain refresh token!" -Cause $_.Exception.Message -Hints @(
                "Ensure that you're connected to the Admin-LAN"
                "Ensure your username and password are valid"
            )
        }

        # get access token
        try {
            $body = @{
                refreshToken = $refresh_token
            } | ConvertTo-Json
            $response = Invoke-RestMethod $config.api.urls.login -Method Post -ContentType "application/json" -Body $body
            $access_token = $response.token

            $this.headers = @{
                Authorization = "Bearer $access_token"
            }
        } catch {
            throw Format-Error -Message "Failed to obtain access token!" -Cause $_.Exception.Message -Hints @(
                "Ensure your connection is stable"
            )
        }

        # get project id
        try {
            $url = "$($config.api.urls.project_id)?`$filter=name eq '$tenant'" 
            $response = Invoke-RestMethod $url -Method Get -Headers $this.headers
        } catch {
            throw Format-Error -Message "Failed to get project id!" -Cause $_.Exception.Message
        }

        if ($response.content.Length -eq 1) {
            $this.project_id = $response.content[0].id
        } else {
            throw Format-Error -Message "Failed to get project id!" -Hints @(
                "Expected exactly 1 project with the given Tenant name, found $($response.content.Length)"
                "Maybe '$tenant' is not a valid tenant name?"
            )
        }
    }

    [Object] Get ([String]$url) {
        return Invoke-RestMethod $url -Method Get -Headers $this.headers
    }
    [Object] Post ([String]$url, [Hashtable]$body) {
        return Invoke-RestMethod $url -Method Post -ContentType "application/json" -Headers $this.headers -Body ($body | ConvertTo-Json)
    }

    [String] Deploy ([String]$name, [String]$catalog_id, [Hashtable]$inputs) {
        $body = @{
            deploymentName = $name
            projectId = $this.project_id
            inputs = $inputs
        }

        Write-Host ($body | ConvertTo-Json)
        throw "Explicit Cancel"

        $response = $this.Post("$($this.url_items)/$catalog_id/request", $body)
        $deployment_id = $response.deploymentId
        if ($null -eq $deployment_id) { throw "Received invalid response: $($response | ConvertTo-Json)" }
        return $deployment_id
    }

    [DeploymentStatus] CheckDeployment ([String]$deployment_id) {
        $response = $this.Get("$($this.url_deployments)/$deployment_id")
        switch ($response.status) {
            "CREATE_INPROGRESS" { return [DeploymentStatus]::InProgress }
            "CREATE_SUCCESSFUL" { return [DeploymentStatus]::Successful }
            "CREATE_FAILED" { return [DeploymentStatus]::Failed }
        }
        throw "Received invalid response: $($response | ConvertTo-Json)"
    }

    [DeploymentStatus] WaitForDeployment ([String]$deployment_id) {
        $status = $null
        $complete = $false
        $wait_time = 0
        while (-not $complete) {
            Start-Sleep $wait_time
            $status = $this.CheckDeployment($deployment_id)
            $complete = $status -ne [DeploymentStatus]::InProgress
            $wait_time++
        }
        return $status
    }
}