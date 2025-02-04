using module ".\shared_types.psm1"
using module ".\api_handle.psm1"
using module ".\io_handle.psm1"
using module ".\parsing.psm1"
using module ".\utils.psm1"

class DeployBucket {
    [ApiAction[]]$actions
    [DataPacket[]]$to_deploy = @()
    [DataPacket[]]$deployed = @()
    [Int]$action_index = 0

    DeployBucket ([ApiAction[]]$actions) { $this.actions = $actions }
    DeployBucket ([ApiAction[]]$actions, [DataPacket[]]$to_deploy) {
        $this.to_deploy = $to_deploy
        $this.actions = $actions
    }

    [Void] NextAction () { $this.action_index++ }
    [Int] QueuedActions () { return $this.actions.Count - $this.action_index }
    [ApiAction] GetCurrentAction () { return $this.actions[$this.action_index] }
    [ApiAction] GetPreviousAction () { return $this.actions[$this.action_index - 1] }
}

function AlignBucket {
    param ([DeployBucket]$bucket, [IoHandle]$io_handle)
    [ApiAction]$action = $bucket.GetCurrentAction()
    [String]$k_sr = "servicerequest"; [String]$k_ur = "updaterequests"; [String]$k_dt = "date_creation"

    foreach ($data_packet in $bucket.to_deploy) {
        [Hashtable]$data = $data_packet.data
        $data_packet.ClearCache()
        if ($action -eq [ApiAction]::Update -and ($img = $io_handle.GetImage($data_packet.GetImageKeys()))) {
            [String]$sr_cur = $data[$k_sr]; [String]$sr_img = $img[$k_sr]
            [Bool]$sr_changed = $sr_img -and $sr_img -ne $sr_cur
            [String[]]$ur_cur = $data[$k_ur]; [String[]]$ur_img = $img[$k_ur]
            [String[]]$ur_new = $ur_cur + $ur_img
            $data["__old.$k_sr"] = $data[$k_sr]
            $data["__old.$k_ur"] = $data[$k_ur]
            if ($sr_changed) { $ur_new += $sr_cur; $data[$k_sr] = $sr_img }
            $data[$k_ur] = NormalizeArray $ur_new
            $data[$k_dt] = $img[$k_dt]
        } else {
            if ($data["__old.$k_sr"]) { $data[$k_sr] = $data["__old.$k_sr"] }
            if ($data["__old.$k_ur"]) { $data[$k_ur] = $data["__old.$k_ur"] }
        }
    }
}

function DeploySingleBucket {
    param (
        [DeployBucket]$bucket,
        [ApiHandle]$api_handle,
        [IoHandle]$io_handle,
        [Hashtable]$config
    )

    $bucket.deployed = @()
    [ApiAction]$action = $bucket.GetCurrentAction()
    [Int]$num_to_deploy = $bucket.to_deploy.Count
    if ($num_to_deploy -eq 0) { return 0 }
    if ($bucket.action_index -gt 0) {
        [String]$prev_action = "$($bucket.GetPreviousAction())".ToLower()
        [String]$adverb = if ($action -eq $bucket.GetPreviousAction()) { "again" } else { "instead" }
        Write-Host "I'll attempt to $("$action".ToLower()) the resource$(PluralityIn $num_to_deploy) that failed to $prev_action $adverb."
    }

    Write-Host "Deploying $num_to_deploy ${action}-request$(PluralityIn $num_to_deploy)..."
    for ($i = 0; $i -lt $num_to_deploy; $i++) {
        ShowPercentage $i $num_to_deploy
        [DataPacket]$data_packet = $bucket.to_deploy[$i]
        [Hashtable]$resource_config = $data_packet.resource_config
        [Hashtable]$inputs = $data_packet.GetApiConversion($action)
        [String]$name = $data_packet.GetApiConversion([ApiAction]::Create).name
        [String]$date = Get-Date -Format "yyy-MM-dd HH:mm:ss"
        [String]$deployment_name = "$action $(Join @($resource_config.resource_name, $name) " ") - $date - LR Automation"

        try {
            $data_packet.deployment_id = $api_handle.Deploy($deployment_name, $data_packet.tenant, $resource_config.catalog_id, $inputs)
            $bucket.deployed += $data_packet
        } catch {
            [String]$short_info = "Deployment Failed"
            [String]$message = "Deploy error at $($data_packet.origin_info): $($_.Exception.Message)"
            [OutputValue]$val = [OutputValue]::New($message, $short_info, $config.color.dploy_error, $data_packet.row_index)
            $Host.UI.WriteErrorLine($message)
            $io_handle.UpdateOutput($resource_config, $val)
        }

        Start-Sleep $resource_config.ddos_sleep_time # Mandatory because of DDoS protection probably
    }

    [Int]$num_deployed = $bucket.deployed.Count
    Write-Host "$num_deployed/$num_to_deploy deployed$(Punctuate $num_deployed $num_to_deploy)"
    return $num_deployed
}

function AwaitSingleBucket {
    param (
        [DeployBucket]$bucket,
        [ApiHandle]$api_handle,
        [IoHandle]$io_handle,
        [Hashtable]$config
    )

    $bucket.to_deploy = @()
    [ApiAction]$action = $bucket.GetCurrentAction()
    [Int]$num_deployed = $bucket.deployed.Count
    if ($num_deployed -eq 0) { return 0 }

    Write-Host "Waiting for status of $num_deployed $action-request$(PluralityIn $num_deployed)..."
    for ($i = 0; $i -lt $num_deployed; $i++) {
        ShowPercentage $i $num_deployed
        [DataPacket]$deployment = $bucket.deployed[$i]
        [Hashtable]$resource_config = $deployment.resource_config
        [DeploymentStatus]$status = $api_handle.WaitForDeployment($deployment.deployment_id)

        if ($status -eq [DeploymentStatus]::Successful) {
            [String]$short_info = "$action Successful"
            [String]$message = "Resource at $($deployment.origin_info) was ${$action_verb}d successfully."
            [OutputValue]$val = [OutputValue]::New($message, $short_info, $config.color.success, $deployment.row_index)
            $io_handle.UpdateOutput($resource_config, $val)

            [Hashtable]$image = $deployment.GetImageConversion()
            $io_handle.UpdateNsxImage($image, $action)
        } else { $bucket.to_deploy += $deployment }
    }

    [Int]$num_successful = $num_deployed - $bucket.to_deploy.Count
    Write-Host "$num_successful/$num_deployed $("$action".ToLower())d sucessfully$(Punctuate $num_successful $num_deployed)"
    return $bucket.to_deploy.Count
}

function DeployAndAwaitBuckets {
    param (
        [DeployBucket[]]$deploy_buckets,
        [ApiHandle]$api_handle,
        [IoHandle]$io_handle,
        [Hashtable]$config
    )

    [Hashtable]$shared_params = @{
        api_handle = $api_handle
        io_handle = $io_handle
        config = $config
    }

    function NothingMoreToDo { Write-Host "Nothing more to do." }
    while (($deploy_buckets | ForEach-Object { $_.QueuedActions() } | Measure-Object -Sum).Sum -gt 0) {
        $deploy_buckets | ForEach-Object { AlignBucket -bucket $_ -io_handle $io_handle }

        if (($deploy_buckets | ForEach-Object {
            DeploySingleBucket -bucket $_ @shared_params
        } | Measure-Object -Sum).Sum -eq 0) { NothingMoreToDo; return }

        if (($deploy_buckets | ForEach-Object {
            AwaitSingleBucket -bucket $_ @shared_params
        } | Measure-Object -Sum).Sum -eq 0) { NothingMoreToDo; return }

        $deploy_buckets | ForEach-Object { $_.NextAction() }
    }

    foreach ($bucket in $deploy_buckets) {
        [String]$actions_str = Join @($bucket.actions | Select-Object -Unique | ForEach-Object { "$_" }) "/"
        [String]$requests_str = "$actions_str-request$(PluralityIn $bucket.actions.Length)"
        foreach ($failed_packet in $bucket.to_deploy) {
            [String]$short_info = "$actions_str Failed"
            [String]$message = Format-Error -Message "$requests_str for resource at $($failed_packet.origin_info) failed" `
                -Hints (DiagnoseFailure $io_handle $failed_packet $bucket.actions)
            [OutputValue]$val = [OutputValue]::New($message, $short_info, $config.color.dploy_error, $failed_packet.row_index)
            $Host.UI.WriteErrorLine($message)
            $io_handle.UpdateOutput($resource_config, $val)
        }
    }

    NothingMoreToDo
}
