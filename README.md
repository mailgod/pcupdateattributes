# Entra user attribute synchronization

`Sync-EntraUserAttributes.ps1` copies `employeeId` and `mail` from a source Microsoft Entra tenant to matching users in a target tenant. Matching is case-insensitive and uses the part of `userPrincipalName` before `@`.

The script writes `unmatched-target-users.csv` by default. The report includes target users with no source match, an unusable username, or multiple source matches.

Use `-LogOnlyCsvPath` to perform the full read and comparison without changing the target tenant. The resulting CSV lists matched users with current and source values, plus unmatched target users with `Action` set to `Unmatched` and a reason. The separate unmatched-user CSV is still written as well. This parameter takes precedence over updates, even without `-WhatIf`.

## Prerequisites

Install the Microsoft Graph PowerShell modules once:

```powershell
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users -Scope CurrentUser
```

The signed-in account needs these delegated Microsoft Graph permissions:

- Source tenant: `User.Read.All`
- Target tenant: `User.ReadWrite.All`

An administrator may need to grant consent for these permissions. The script does not store credentials.

## Usage

Run a dry run first:

```powershell
.\Sync-EntraUserAttributes.ps1 `
    -SourceTenantId 'source-tenant-id' `
    -TargetTenantId 'target-tenant-id' `
    -SkipUnchanged `
    -WhatIf
```

Run in log-only mode:

```powershell
.\Sync-EntraUserAttributes.ps1 `
    -SourceTenantId 'source-tenant-id' `
    -TargetTenantId 'target-tenant-id' `
    -LogOnlyCsvPath '.\output\proposed-user-updates.csv' `
    -SkipUnchanged
```

Apply the updates:

```powershell
.\Sync-EntraUserAttributes.ps1 `
    -SourceTenantId 'source-tenant-id' `
    -TargetTenantId 'target-tenant-id' `
    -UnmatchedCsvPath '.\output\unmatched-target-users.csv' `
    -SkipUnchanged
```

By default, a blank source `employeeId` or `mail` does not overwrite a target value. Add `-ClearMissingAttributes` when blank source values should clear the corresponding target attributes.