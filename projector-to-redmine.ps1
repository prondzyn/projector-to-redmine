# $ProjectId = 347
# $UserId = 243

param (
    [string]$ApiKey,
    [string]$RedmineUrl,
    [string]$CsvPath,
    [int]$ProjectId,
    [int]$UserId
)

if (-not $ApiKey -or -not $RedmineUrl -or -not $CsvPath -or -not $ProjectId -or -not $UserId) {
    Write-Error "Missing required parameters. Usage: powershell -File script.ps1 -ApiKey <token> -RedmineUrl <url> -CsvPath <path> -ProjectId <id> -UserId <id>"
    exit 1
}

function Get-CsvData {
    param (
        [string]$CsvPath
    )
    if ($CsvPath -match '^(https?://)') {
    Write-Host "Downloading CSV file from URL: $CsvPath"
        try {
            $response = Invoke-WebRequest -Uri $CsvPath -ErrorAction Stop
            if ($response.StatusCode -ne 200) {
                Write-Error "Failed to download CSV file from the provided URL. Status: $($response.StatusCode)"
                exit 2
            }
            $csvContent = $response.Content
            return $csvContent | ConvertFrom-Csv
        } catch {
            Write-Error "`nError downloading CSV file from URL: $CsvPath`nException: $($_.Exception.Message)`nCheck if the file exists and if the URL is correct.`n"
            exit 2
        }
    } else {
        Write-Host "Loading CSV file locally: $CsvPath"
        return Import-Csv -Path $CsvPath -Delimiter ','
    }
}

function Compare-HoursPerDay {
    param (
        [array]$Data,
        [array]$UniqueDates,
        [string]$RedmineUrl,
        [int]$ProjectId,
        [int]$UserId,
        [string]$ApiKey
    )

    foreach ($date in $UniqueDates) {
        # Sum of hours from CSV for the given day
        $csvHoursSum = ($Data | Where-Object { $_.data -eq $date } | ForEach-Object { [double]($_.godzin -replace ',', '.') }) | Measure-Object -Sum
        $csvTotal = $csvHoursSum.Sum

        # Get time entries from Redmine for the given day and user ID
        $redmineEntries = Invoke-RestMethod -Uri "$RedmineUrl/time_entries.json?project_id=$ProjectId&spent_on=$date&user_id=$UserId" `
            -Headers @{ "X-Redmine-API-Key" = $ApiKey }

        $redmineHoursSum = ($redmineEntries.time_entries | Where-Object { $_.spent_on -eq $date } | ForEach-Object { $_.hours }) | Measure-Object -Sum
        $redmineTotal = $redmineHoursSum.Sum

        Write-Host "Date: $date | Total hours in CSV: $csvTotal | Total hours in Redmine (user $UserId): $redmineTotal"

        if ($csvTotal -eq $redmineTotal) {
            Write-Host "Total hours match for $date (user $UserId)."
            return $true
        } else {
            Write-Warning "Total hours DO NOT match for $date (user $UserId)!"
            return $false
        }
    }
}

function Get-RedmineTimeEntryCount {
    param (
        [string]$RedmineUrl,
        [int]$ProjectId,
        [int]$UserId,
        [string]$ApiKey
    )
    $date = (Get-Date).ToString("yyyy-MM-dd")
    try {
        $response = Invoke-RestMethod -Uri "$RedmineUrl/time_entries.json?project_id=$ProjectId&spent_on=$date&user_id=$UserId" `
            -Headers @{ "X-Redmine-API-Key" = $ApiKey }
    } catch {
        Write-Error "`nFailed to fetch time entries from Redmine:`nException: $($_.Exception.Message)`n"
        exit 4
    }
    return $response.time_entries.Count
}

function Compare-RecordCount {
    param (
        [array]$Data,
        [int]$RedmineCount
    )

    # Count records in CSV (excluding header, which Import-Csv already does)
    $csvCount = $Data.Count

    $difference = $RedmineCount - $csvCount
    Write-Host "CSV records: $csvCount | Redmine time entries: $RedmineCount | Difference: $difference"
    return $difference
}

function Get-ActivityMap {
    param (
        [string]$RedmineUrl,
        [int]$ProjectId,
        [string]$ApiKey
    )

    try {
        $activitiesResponse = Invoke-RestMethod -Uri "$RedmineUrl/projects/$ProjectId.json?include=time_entry_activities" `
            -Headers @{ "X-Redmine-API-Key" = $ApiKey }
    } catch {
        Write-Error "`nFailed to fetch time entry activities from Redmine:`nException: $($_.Exception.Message)`n"
        exit 5
    }

    $activityMap = @{}
    foreach ($act in $activitiesResponse.project.time_entry_activities) {
        $activityMap[$act.name] = $act.id
    }

    Write-Host "Fetched time entry activities:"
    $activityMap.GetEnumerator() | ForEach-Object { Write-Host "$($_.Key) -> $($_.Value)" }

    return $activityMap
}

function Remove-TimeEntriesForDates {
    param (
        [array]$UniqueDates,
        [string]$RedmineUrl,
        [int]$ProjectId,
        [string]$ApiKey,
        [int]$UserId
    )

    foreach ($date in $UniqueDates) {
        # Get time entries from Redmine for the given date and user
        $entriesToDelete = Invoke-RestMethod -Uri "$RedmineUrl/time_entries.json?project_id=$ProjectId&spent_on=$date&user_id=$UserId" `
            -Headers @{ "X-Redmine-API-Key" = $ApiKey }

        foreach ($entry in $entriesToDelete.time_entries) {
            $entryId = $entry.id
            Invoke-RestMethod -Uri "$RedmineUrl/time_entries/$entryId.json" `
                -Method DELETE `
                -Headers @{ "X-Redmine-API-Key" = $ApiKey } | Out-Null
            Write-Host "Deleted time entry with ID $entryId for date $date and user $UserId"
        }
    }
}

function Add-TimeEntriesFromCsv {
    param (
        [array]$Data,
        [hashtable]$ActivityMap,
        [string]$RedmineUrl,
        [int]$ProjectId,
        [string]$ApiKey,
        [int]$UserId,
        [int]$SkipFirstN = 0
    )

    $rowsToProcess = $Data
    if ($SkipFirstN -gt 0) {
        $rowsToProcess = $Data[$SkipFirstN..($Data.Count - 1)]
    }

    foreach ($row in $rowsToProcess) {
        $spentOn = $row.data
        $issueId = $row.zagadnienie
        $hours = $row.godzin
        $activityName = $row.activity

        # Skip row if any required field is empty
        $missingFields = @()
        if ([string]::IsNullOrWhiteSpace($spentOn)) { $missingFields += "data" }
        if ([string]::IsNullOrWhiteSpace($issueId)) { $missingFields += "zagadnienie" }
        if ([string]::IsNullOrWhiteSpace($hours)) { $missingFields += "godzin" }
        if ([string]::IsNullOrWhiteSpace($activityName)) { $missingFields += "activity" }
        if ($missingFields.Count -gt 0) {
            Write-Warning "Skipped row due to missing required field(s): $($missingFields -join ', ')"
            continue
        }

        $issueId = [int]$issueId
        $hours = [double]($hours -replace ',', '.')

        if ($ActivityMap.ContainsKey($activityName)) {
            $activityId = $ActivityMap[$activityName]
        } else {
            Write-Warning "Activity '$activityName' not found; entry skipped."
            continue
        }

        $body = @{
            time_entry = @{
                project_id = $ProjectId
                issue_id = $issueId
                spent_on = $spentOn
                hours = $hours
                activity_id = $activityId
                user_id = $UserId
            }
        } | ConvertTo-Json -Depth 4

        Invoke-RestMethod -Uri "$RedmineUrl/time_entries.json" `
            -Method POST `
            -Headers @{ "X-Redmine-API-Key" = $ApiKey; "Content-Type" = "application/json" } `
            -Body $body | Out-Null

        Write-Host "Added time entry [Project: $ProjectId, Issue: $issueId, Hours: $hours, Activity: $activityName, User: $UserId]"
    }
}

function Get-FilteredCsvData {
    param (
        [string]$CsvPath
    )

    $data = Get-CsvData -CsvPath $CsvPath

    $filteredData = @()

    foreach ($row in $data) {
        $missingFields = @()
        if ([string]::IsNullOrWhiteSpace($row.data))   { $missingFields += "data" }
        if ([string]::IsNullOrWhiteSpace($row.zagadnienie))   { $missingFields += "zagadnienie" }
        if ([string]::IsNullOrWhiteSpace($row.godzin))     { $missingFields += "godzin" }
        if ([string]::IsNullOrWhiteSpace($row.activity)) { $missingFields += "activity" }

        if ($missingFields.Count -gt 0) {
            Write-Warning "Skipped row due to missing required field(s): $($missingFields -join ', ')"
            continue
        }

        $filteredData += $row
    }

    return $filteredData
}

$data = Get-FilteredCsvData -CsvPath $CsvPath

$uniqueDates = $data | Select-Object -ExpandProperty data | Sort-Object -Unique

$hoursAreEqual = Compare-HoursPerDay -Data $data -UniqueDates $uniqueDates -RedmineUrl $RedmineUrl -ProjectId $ProjectId -UserId $UserId -ApiKey $ApiKey

$redmineCount = Get-RedmineTimeEntryCount -RedmineUrl $RedmineUrl -ProjectId $ProjectId -UserId $UserId -ApiKey $ApiKey

$recordDifference = Compare-RecordCount -Data $data -RedmineCount $redmineCount

if ($hoursAreEqual -and $recordDifference -eq 0) {
    Write-Host "No differences found; exiting."
    exit 0
}

$cleanRedmine = $false

if (-not $hoursAreEqual -and $recordDifference -eq 0) {
    Write-Host "Hours differ but record counts match; Setting Redmine to clean."
    $cleanRedmine = $true
}

if ($recordDifference -gt 0) {
    Write-Host "More records in Redmine than in CSV; Setting Redmine to clean."
    $cleanRedmine = $true
}

if ($cleanRedmine) {
    Write-Host "Cleaning Redmine; resetting record count."
    Remove-TimeEntriesForDates -UniqueDates $uniqueDates -RedmineUrl $RedmineUrl -ProjectId $ProjectId -UserId $UserId -ApiKey $ApiKey
    $redmineCount = 0
}

$activityMap = Get-ActivityMap -RedmineUrl $RedmineUrl -ProjectId $ProjectId -ApiKey $ApiKey

Add-TimeEntriesFromCsv -Data $data -ActivityMap $activityMap -RedmineUrl $RedmineUrl -ProjectId $ProjectId -UserId $UserId -ApiKey $ApiKey -SkipFirstN $redmineCount

Compare-HoursPerDay -Data $data -UniqueDates $uniqueDates -RedmineUrl $RedmineUrl -ProjectId $ProjectId -UserId $UserId -ApiKey $ApiKey | Out-Null