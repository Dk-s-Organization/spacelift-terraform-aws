\$ProfileName     = "  "
\$HubRegion       = "us-east-1"
\$RuleName        = "Forward-S3CreateBucket-To-Hub"
\$RuleDescription = "Forwards regional S3 CreateBucket CloudTrail events to the central us-east-1 hub bus."

Set-AWSCredential -ProfileName \$ProfileName
Set-DefaultAWSRegion -Region \$HubRegion

\$CallerInfo      = Get-STSCallerIdentity
AccountId = CallerInfo.Account
\$TargetBusArn    = "arn:aws:events:" + HubRegion + ":" + AccountId + ":event-bus/default"

\$EventPattern = @'
{
  "source": ["aws.s3"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventSource": ["://amazonaws.com"],
    "eventName": ["CreateBucket"]
  }
}
'@

Write-Host "Fetching all available AWS regions..." -ForegroundColor Cyan
\$Regions = (Get-EC2Region).RegionName | Where-Object { \(_ -ne\)HubRegion }

Write-Host "Found ((Regions.Count)) spoke regions to configure." -ForegroundColor Cyan

foreach (Reg in Regions) {
    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Configuring Region: \$Reg" -ForegroundColor Yellow
    
    try {
        RuleArn = New-EVBEventRule -Name RuleName `
                                    -Description \$RuleDescription `
                                    -EventPattern $EventPattern `
                                    -State "ENABLED" `
                                    -Region $Reg `
                                    -Force

        Write-Host "Creating cross-region target parameter object..." -ForegroundColor Gray
        \$Target = New-Object Amazon.EventBridge.Model.Target
        Target.Id = "CentralHubBusTarget-" + Reg
        Target.Arn = TargetBusArn

        Write-EVBTarget -Rule \$RuleName -Target Target -Region Reg

        Write-Host "Successfully configured rule in \$Reg!" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to configure Region Reg. Error: _"
    }
}

Write-Host "========================================================" -ForegroundColor Green
Write-Host "All spoke regions processed successfully!" -ForegroundColor Green
