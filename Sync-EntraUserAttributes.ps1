#requires -Version 5.1
#requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceTenantId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetTenantId,

    [string]$UnmatchedCsvPath = (Join-Path -Path (Get-Location) -ChildPath 'unmatched-target-users.csv'),

    [string]$LogOnlyCsvPath,

    [switch]$ClearMissingAttributes,

    [switch]$SkipUnchanged
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceScopes = @('User.Read.All')
$targetScopes = @('User.ReadWrite.All')
$userProperties = @('id', 'displayName', 'userPrincipalName', 'mail', 'employeeId')

function Get-UsernameKey {
    param(
        [AllowNull()]
        [string]$UserPrincipalName
    )

    if ([string]::IsNullOrWhiteSpace($UserPrincipalName)) {
        return $null
    }

    $atIndex = $UserPrincipalName.IndexOf('@')
    if ($atIndex -lt 1) {
        return $null
    }

    return $UserPrincipalName.Substring(0, $atIndex).Trim().ToLowerInvariant()
}

function Connect-ToTenant {
    param(
        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string[]]$Scopes
    )

    Write-Verbose "Connecting to tenant '$TenantId'."
    Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -ContextScope Process -NoWelcome
}

function Get-TenantUsers {
    param(
        [Parameter(Mandatory)]
        [string]$TenantName
    )

    Write-Host "Reading users from the $TenantName tenant..."
    $users = @(Get-MgUser -All -Property $userProperties)
    Write-Host "Read $($users.Count) users from the $TenantName tenant."
    return $users
}

try {
    Connect-ToTenant -TenantId $SourceTenantId -Scopes $sourceScopes
    $sourceUsers = Get-TenantUsers -TenantName 'source'

    $sourceByUsername = @{}
    foreach ($sourceUser in $sourceUsers) {
        $usernameKey = Get-UsernameKey -UserPrincipalName $sourceUser.UserPrincipalName
        if ($null -eq $usernameKey) {
            Write-Warning "Skipping source user '$($sourceUser.Id)' because userPrincipalName has no usable username."
            continue
        }

        if (-not $sourceByUsername.ContainsKey($usernameKey)) {
            $sourceByUsername[$usernameKey] = [System.Collections.Generic.List[object]]::new()
        }

        $sourceByUsername[$usernameKey].Add($sourceUser)
    }

    Disconnect-MgGraph | Out-Null

    Connect-ToTenant -TenantId $TargetTenantId -Scopes $targetScopes
    $targetUsers = Get-TenantUsers -TenantName 'target'

    $unmatchedUsers = [System.Collections.Generic.List[object]]::new()
    $changeLog = [System.Collections.Generic.List[object]]::new()
    $updatedCount = 0
    $unchangedCount = 0

    foreach ($targetUser in $targetUsers) {
        $usernameKey = Get-UsernameKey -UserPrincipalName $targetUser.UserPrincipalName
        $matchReason = $null
        $sourceUser = $null

        if ($null -eq $usernameKey) {
            $matchReason = 'Target user has no usable userPrincipalName.'
        }
        elseif (-not $sourceByUsername.ContainsKey($usernameKey)) {
            $matchReason = 'No source user matched the username.'
        }
        elseif ($sourceByUsername[$usernameKey].Count -ne 1) {
            $matchReason = 'Multiple source users matched the username.'
        }
        else {
            $sourceUser = $sourceByUsername[$usernameKey][0]
        }

        if ($null -eq $sourceUser) {
            $unmatchedUsers.Add([pscustomobject]@{
                    TargetUserId          = $targetUser.Id
                    TargetDisplayName     = $targetUser.DisplayName
                    TargetUserPrincipalName = $targetUser.UserPrincipalName
                    Username              = $usernameKey
                    Reason                = $matchReason
                })
            continue
        }

        $updateProperties = @{}
        if ($ClearMissingAttributes -or $null -ne $sourceUser.EmployeeId) {
            $updateProperties['EmployeeId'] = $sourceUser.EmployeeId
        }
        if ($ClearMissingAttributes -or $null -ne $sourceUser.Mail) {
            $updateProperties['Mail'] = $sourceUser.Mail
        }

        $employeeIdChanged = $targetUser.EmployeeId -ne $sourceUser.EmployeeId
        $mailChanged = $targetUser.Mail -ne $sourceUser.Mail
        if ($updateProperties.Count -eq 0 -or ($SkipUnchanged -and -not ($employeeIdChanged -or $mailChanged))) {
            $unchangedCount++
            if (-not [string]::IsNullOrWhiteSpace($LogOnlyCsvPath)) {
                $changeLog.Add([pscustomobject]@{
                        Action                  = 'NoChange'
                        TargetUserId            = $targetUser.Id
                        TargetDisplayName       = $targetUser.DisplayName
                        TargetUserPrincipalName = $targetUser.UserPrincipalName
                        Username                = $usernameKey
                        CurrentEmployeeId       = $targetUser.EmployeeId
                        SourceEmployeeId        = $sourceUser.EmployeeId
                        CurrentMail             = $targetUser.Mail
                        SourceMail              = $sourceUser.Mail
                        Reason                  = if ($updateProperties.Count -eq 0) { 'Source attributes are blank; target values were preserved.' } else { 'Values are unchanged.' }
                    })
            }
            continue
        }

        $targetLabel = if ([string]::IsNullOrWhiteSpace($targetUser.UserPrincipalName)) {
            $targetUser.Id
        }
        else {
            $targetUser.UserPrincipalName
        }

        if (-not [string]::IsNullOrWhiteSpace($LogOnlyCsvPath)) {
            $changeLog.Add([pscustomobject]@{
                    Action                  = 'WouldUpdate'
                    TargetUserId            = $targetUser.Id
                    TargetDisplayName       = $targetUser.DisplayName
                    TargetUserPrincipalName = $targetUser.UserPrincipalName
                    Username                = $usernameKey
                    CurrentEmployeeId       = $targetUser.EmployeeId
                    SourceEmployeeId        = $sourceUser.EmployeeId
                    CurrentMail             = $targetUser.Mail
                    SourceMail              = $sourceUser.Mail
                    Reason                  = 'Log-only mode; no target update was made.'
                })
            continue
        }

        if ($PSCmdlet.ShouldProcess($targetLabel, 'Update employeeId and mail from the source tenant')) {
            Update-MgUser -UserId $targetUser.Id -BodyParameter $updateProperties
            $updatedCount++
            Write-Host "Updated $targetLabel."
        }
    }

    $csvDirectory = Split-Path -Path $UnmatchedCsvPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($csvDirectory)) {
        New-Item -Path $csvDirectory -ItemType Directory -Force | Out-Null
    }

    $unmatchedUsers | Export-Csv -Path $UnmatchedCsvPath -NoTypeInformation -Encoding UTF8

    if (-not [string]::IsNullOrWhiteSpace($LogOnlyCsvPath)) {
        $logDirectory = Split-Path -Path $LogOnlyCsvPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        }

        $changeLog | Export-Csv -Path $LogOnlyCsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Log-only report: $LogOnlyCsvPath"
    }

    Write-Host "Completed. Updated: $updatedCount; unchanged/skipped: $unchangedCount; unmatched: $($unmatchedUsers.Count)."
    Write-Host "Unmatched-user report: $UnmatchedCsvPath"
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}