Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# TLS 1.2 fix for Windows PowerShell 5.1
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# Enforce UTF8 output for modern UI characters
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

#region ------ UI CHARACTER MAP -----------------------------------------------
# All box-drawing / symbol chars are built from Unicode codepoints at runtime.
# This keeps the source file byte-for-byte ASCII - safe for irm | iex from
# GitHub raw / Vercel regardless of encoding headers or BOM handling.
$_V = [char]0x2551                       # vertical border   |
$_H = [string][char]0x2550               # horizontal (string so * repetition works)
$_TL = [char]0x2554                       # corner top-left
$_TR = [char]0x2557                       # corner top-right
$_BL = [char]0x255A                       # corner bottom-left
$_BR = [char]0x255D                       # corner bottom-right
$_ML = [char]0x2560                       # mid-left  (section divider)
$_MR = [char]0x2563                       # mid-right
$_ARR = [char]0x25B6                       # menu selector arrow
$_DIA = [char]0x25C6                       # section bullet
$_CHK = [char]0x2713                       # success tick
$_CRS = [char]0x2717                       # failure cross
$_INF = [char]0x2139                       # info symbol
$_GT = [char]0x203A                       # item prefix (single right angle)
$_CEL = [char]::ConvertFromUtf32(0x1F389)  # party popper emoji (surrogate pair)

# Pre-built border strings  (94 chars = corner + 92x horizontal + corner)
$_TOP = "$_TL" + ($_H * 92) + "$_TR"
$_BOT = "$_BL" + ($_H * 92) + "$_BR"
$_EMPTY = "$_V" + (' ' * 92) + "$_V"
$_SEC_COURSE = "$_TL" + ($_H * 2) + " COURSE OVERVIEW " + ($_H * 73) + "$_TR"
$_SEC_RUN = "$_ML" + ($_H * 2) + " RUN COMPLETE " + ($_H * 76) + "$_MR"
#endregion -----------------------------------------------------------------------


#region ------ CONFIGURATION ------------------------------------------------------------------------------------------------------------------------------------------------------------------

$Config = [pscustomobject]@{
    Origin         = 'https://online.vtu.ac.in'
    BaseUrl        = 'https://online.vtu.ac.in/api/v1'
    LoginEndpoint  = '/auth/login'
    EnrollEndpoint = '/student/my-enrollments'

    # Server strictly enforces chunk size between 0-120 seconds.
    WatchChunk     = 120

    # Absolute safety cap. Natural exit is ceil(totalSeconds / 120) chunks.
    # 300 x 120s = 10 hours. Prevents infinite loops on bad API responses.
    MaxRetries     = 300

    RetryCount     = 4    # HTTP-level retries per failed API request
    RetryDelayMs   = 2000  # ms between HTTP retries
    DelayMs        = 180   # ms between consecutive API calls. Network RTT (~600ms) is the natural rate limiter.
}

#endregion ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

#region ------ LOGGING ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

$Global:LogFile = $null

function Initialize-Logging {
    $logDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'VTULogs'
    $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
    $Global:LogFile = Join-Path $logDir ('VTU_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Add-Content -Path $Global:LogFile -Encoding UTF8 -Value ('[{0}] Session started' -f (Get-Date))
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    if (-not $Global:LogFile) { return }
    $ts = (Get-Date).ToString('HH:mm:ss.fff')
    Add-Content -Path $Global:LogFile -Encoding UTF8 -Value "[$ts][$Level] $Message"
}

#endregion ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

#region ------ UTILITIES ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function Get-UIPad {
    $w = $host.UI.RawUI.WindowSize.Width
    $boxW = 94
    if ($w -gt $boxW) { return ' ' * [math]::Floor(($w - $boxW) / 2) }
    return ''
}

function Get-IncompleteCourses {
    param($Enrollments)
    return $Enrollments | Where-Object {
        $slug = $_.details.slug
        $progress = if ($null -ne $_.progress_percent) { [double]$_.progress_percent } else { 0 }
        -not [string]::IsNullOrWhiteSpace($slug) -and $progress -lt 100
    }
}

function ConvertFrom-VTUDuration {
    # Parses VTU duration string "HH:MM:SS mins" -> total seconds (int).
    param([string]$Duration)
    if ([string]::IsNullOrWhiteSpace($Duration)) { return 0 }
    $parts = @()
    foreach ($p in ($Duration -split '[:\s]+')) { if ($p -match '^\d+$') { $parts += $p } }
    if ($parts.Count -lt 3) { return 0 }
    return ([int]$parts[0] * 3600) + ([int]$parts[1] * 60) + [int]$parts[2]
}

function ConvertTo-ProgressBar {
    param([int]$Current, [int]$Total, [int]$Width = 22)
    $fb = [string][char]0x2588  # full block
    $eb = [string][char]0x2591  # light shade (empty)
    if ($Total -le 0) { return ($fb * $Width) + ' 100%' }
    $pct = [math]::Min(100, [math]::Round(($Current / $Total) * 100))
    $fill = [math]::Round(($pct / 100) * $Width)
    $empt = $Width - $fill
    return ($fb * $fill) + ($eb * $empt) + " $pct%"
}

function Send-StartupPing {
    # Fire-and-forget ping to counter.dev - runs natively to avoid Start-Job overhead.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [System.Net.WebRequest]::Create("https://t.counter.dev/track?id=48b364ab-0c36-4a3a-a010-165c74bbf7d6&utcoffset=6&referrer=https://vtu-skip.cli&screen=0x0")
        $req.Method = "GET"
        $req.Headers.Add("Origin", "https://13arathp.vercel.app")
        $null = $req.GetResponseAsync()
    }
    catch { }
}

#endregion ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

#region ------ HTTP HELPERS ------------------------------------------------------------------------------------------------------------------------------------------------------------------

function New-Headers {
    # Builds request headers to mimic a real browser session.
    param(
        [Parameter(Mandatory)][string]$Referer,
        [Parameter(Mandatory)][string]$CookieHeader,
        [switch]$JsonContent,
        [switch]$IncludeXHR
    )
    $h = @{
        'Accept'             = 'application/json'
        'Accept-Language'    = 'en-US,en;q=0.9'
        'DNT'                = '1'
        'Origin'             = $Config.Origin
        'Referer'            = $Referer
        'Sec-Fetch-Dest'     = 'empty'
        'Sec-Fetch-Mode'     = 'cors'
        'Sec-Fetch-Site'     = 'same-origin'
        'User-Agent'         = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0'
        'sec-ch-ua'          = '"Microsoft Edge";v="143", "Chromium";v="143", "Not A(Brand";v="24"'
        'sec-ch-ua-mobile'   = '?0'
        'sec-ch-ua-platform' = '"Windows"'
        'Cookie'             = $CookieHeader
    }
    if ($JsonContent) { $h['Content-Type'] = 'application/json' }
    if ($IncludeXHR) { $h['X-Requested-With'] = 'XMLHttpRequest' }
    return $h
}

function Invoke-Api {
    # Central HTTP wrapper: delays, retries, logs, and captures response body on errors.
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][hashtable]$Headers,
        [object]$Body,
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession]$Session
    )
    $lastErr = $null
    for ($r = 0; $r -lt $Config.RetryCount; $r++) {
        Start-Sleep -Milliseconds $Config.DelayMs
        Write-Log "$Method $Url"
        try {
            if ($Method -eq 'GET') {
                return Invoke-RestMethod -Uri $Url -Method GET -Headers $Headers -WebSession $Session -ErrorAction Stop
            }
            else {
                $jsonBody = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 10 } else { '{}' }
                Write-Log "Body: $jsonBody" 'DEBUG'
                return Invoke-RestMethod -Uri $Url -Method POST -Headers $Headers -Body $jsonBody -WebSession $Session -ErrorAction Stop
            }
        }
        catch {
            $lastErr = $_
            $msg = $_.Exception.Message
            Write-Log "FAILED $Method $Url (Retry $($r+1)/$($Config.RetryCount)): $msg" 'WARN'
            try {
                if ($_.Exception.Response -and $_.Exception.Response.GetResponseStream()) {
                    $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    Write-Log "ResponseBody: $($sr.ReadToEnd())" 'ERROR'
                }
            }
            catch { }

            Start-Sleep -Milliseconds $Config.RetryDelayMs
        }
    }
    throw $lastErr
}

function Get-CookieHeaderFromSession {
    # Extracts access_token and refresh_token from the session cookie jar.
    param([Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession]$Session)
    $cookies = $Session.Cookies.GetCookies([uri]$Config.Origin)
    $at = ($cookies | Where-Object Name -eq 'access_token'  | Select-Object -First 1).Value
    $rt = ($cookies | Where-Object Name -eq 'refresh_token' | Select-Object -First 1).Value
    if (-not $at -or -not $rt) { throw 'Login succeeded but tokens not found in cookies.' }
    return "access_token=$at; refresh_token=$rt"
}

function Format-EnrollmentArray {
    # Normalises enrollment API response into a flat array.
    # Handles both JSON array and object-with-numeric-keys formats.
    param([Parameter(Mandatory)]$Resp)
    $data = if ($Resp.data) { $Resp.data } else { $Resp }
    if ($data -is [System.Array]) { return $data }
    $items = @()
    foreach ($p in $data.PSObject.Properties) {
        if ($p.Name -match '^\d+$') { $items += $p.Value }
    }
    return $items
}

#endregion ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

#region ------ API CALLS ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function Invoke-Login {
    param([string]$Email, [securestring]$Password)
    # ZeroFreeBSTR wipes the unmanaged BSTR memory immediately after use,
    # preventing the plain-text password from lingering in process memory.
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $url = $Config.BaseUrl + $Config.LoginEndpoint
    $headers = New-Headers -Referer "$($Config.Origin)/auth/login?returnTo=%2Fstudent%2Fenrollments" `
        -CookieHeader 'refresh_token=' -JsonContent
    $body = @{ email = $Email; password = $plain }

    # Send body as a plain JSON object (not array). Skip body logging to protect credentials.
    $loginJson = $body | ConvertTo-Json -Depth 10
    Write-Log "POST $url" ; Write-Log '[login body redacted]' 'DEBUG'
    Start-Sleep -Milliseconds $Config.DelayMs
    $null = Invoke-RestMethod -Uri $url -Method POST -Headers $headers -Body $loginJson -WebSession $session -ErrorAction Stop
    return [pscustomobject]@{
        Session      = $session
        CookieHeader = (Get-CookieHeaderFromSession -Session $session)
    }
}

function Get-Enrollments {
    param($Session, [string]$CookieHeader)
    $url = $Config.BaseUrl + $Config.EnrollEndpoint
    $headers = New-Headers -Referer "$($Config.Origin)/student/enrollments" -CookieHeader $CookieHeader -IncludeXHR
    $resp = Invoke-Api -Method GET -Url $url -Headers $headers -Session $Session
    return Format-EnrollmentArray -Resp $resp
}

function Get-CourseDetails {
    param($Session, [string]$CookieHeader, [string]$Slug)
    $url = "$($Config.BaseUrl)/student/my-courses/$Slug"
    $headers = New-Headers -Referer "$($Config.Origin)/student/course/$Slug" -CookieHeader $CookieHeader
    return Invoke-Api -Method GET -Url $url -Headers $headers -Session $Session
}

function Get-LectureDetails {
    # Fetches individual lecture metadata, including data.duration ("HH:MM:SS mins").
    param($Session, [string]$CookieHeader, [string]$Slug, [string]$LectureId)
    $url = "$($Config.BaseUrl)/student/my-courses/$Slug/lectures/$LectureId"
    $headers = New-Headers -Referer "$($Config.Origin)/student/learning/$Slug" -CookieHeader $CookieHeader -IncludeXHR
    return Invoke-Api -Method GET -Url $url -Headers $headers -Session $Session
}

function Send-ProgressWithRetry {
    # Submits one 120s watch-chunk to the progress endpoint.
    # The server accumulates chunks and sets is_completed = true once fully watched.
    param(
        $Session,
        [string]$CookieHeader,
        [string]$Slug,
        [string]$LectureId,
        [int]$CurrentTime,    # cumulative seconds watched (playback cursor)
        [int]$TotalDuration,  # actual lecture duration in seconds
        [int]$Watched         # seconds in this chunk (server max: 120)
    )
    $url = "$($Config.BaseUrl)/student/my-courses/$Slug/lectures/$LectureId/progress"
    $headers = New-Headers -Referer "$($Config.Origin)/student/learning/$Slug" `
        -CookieHeader $CookieHeader -JsonContent -IncludeXHR
    $body = @{
        current_time_seconds   = 99999
        total_duration_seconds = $TotalDuration
        seconds_just_watched   = $Watched
    }

    # Log the outgoing request payload
    Write-Log "PROGRESS req  lec=$LectureId  current=$CurrentTime  total=$TotalDuration  watched=$Watched"

    $resp = Invoke-Api -Method POST -Url $url -Headers $headers -Body $body -Session $Session
    # Log what the server came back with
    $pct = $resp.data.percent
    $isDone = [bool]$resp.data.is_completed
    Write-Log "PROGRESS resp lec=$LectureId  percent=$pct  is_completed=$isDone"
    return $resp
}

#endregion ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

#region ------ DISPLAY ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function Show-Banner {
    Write-Host ''
    $pad = Get-UIPad
    Write-Host ($pad + $_TOP) -ForegroundColor Cyan
    Write-Host ($pad + $_EMPTY) -ForegroundColor Cyan
    
    $art = @(
        ' ____   ____  _________  _____  _____             ______   ___  ____   _____  _______   ',
        '|_  _| |_  _||  _   _  ||_   _||_   _|          .'' ____ \ |_  ||_  _| |_   _||_   __ \  ',
        '  \ \   / /  |_/ | | \_|  | |    | |    ______  | (___ \_|  | |_/ /     | |    | |__) | ',
        '   \ \ / /       | |      | ''    '' |   |______|  _.____`.   |  __''.     | |    |  ___/  ',
        '    \ '' /       _| |_      \ \__/ /             | \____) | _| |  \ \_  _| |_  _| |_     ',
        '     \_/       |_____|      `.__.''               \______.''|____||____||_____||_____|    '
    )
    foreach ($line in $art) {
        Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
        Write-Host (' ' + $line).PadRight(92) -NoNewline -ForegroundColor White
        Write-Host $_V -ForegroundColor Cyan
    }

    Write-Host ($pad + $_EMPTY) -ForegroundColor Cyan

    $esc = [char]27
    $link = 'github.com/13arathp/scripts'
    $fullUrl = 'https://github.com/13arathp/scripts'
    $hyperlink = "$esc]8;;$fullUrl$esc\$link$esc]8;;$esc\"

    # Label line
    $label = '-- source --'
    $lbPad = [math]::Floor((92 - $label.Length) / 2)
    $lbPadR = 92 - $label.Length - $lbPad
    Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
    Write-Host (' ' * $lbPad + $label + ' ' * $lbPadR) -NoNewline -ForegroundColor DarkGray
    Write-Host $_V -ForegroundColor Cyan

    # URL line - bright yellow, centered
    $lPad = [math]::Floor((92 - $link.Length) / 2)
    $lPadR = 92 - $link.Length - $lPad
    Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
    Write-Host (' ' * $lPad) -NoNewline
    Write-Host $hyperlink -NoNewline -ForegroundColor Yellow
    Write-Host (' ' * $lPadR) -NoNewline
    Write-Host $_V -ForegroundColor Cyan

    # Email line - bright yellow, centered
    $email = 'barathp.dev@gmail.com'
    $emailHref = "$esc]8;;https://mail.google.com/mail/?view=cm&fs=1&to=$email$esc\$email$esc]8;;$esc\"
    $ePad = [math]::Floor((92 - $email.Length) / 2)
    $ePadR = 92 - $email.Length - $ePad
    Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
    Write-Host (' ' * $ePad) -NoNewline
    Write-Host $emailHref -NoNewline -ForegroundColor Yellow
    Write-Host (' ' * $ePadR) -NoNewline
    Write-Host $_V -ForegroundColor Cyan

    Write-Host ($pad + $_BOT) -ForegroundColor Cyan
    Write-Host ''
}

function Show-InteractiveMenu {
    param([string]$Title, [string[]]$Options)
    $cursorHides = [Console]::CursorVisible
    if ($cursorHides -ne $null) { [Console]::CursorVisible = $false }
    
    $oldTreat = $false
    try { $oldTreat = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } catch {}
    
    try {
        $selectedIndex = 0
        while ($true) {
            Clear-Host
            Show-Banner
            $pad = Get-UIPad
        
            Write-Host ($pad + $_TOP) -ForegroundColor Cyan
            Write-Host ($pad + $_EMPTY) -ForegroundColor Cyan
        
            $tPad = [math]::Floor((92 - $Title.Length) / 2)
            $tPadR = 92 - $Title.Length - $tPad
            Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
            Write-Host (' ' * $tPad + $Title + ' ' * $tPadR) -NoNewline -ForegroundColor White
            Write-Host $_V -ForegroundColor Cyan
        
            Write-Host ($pad + $_EMPTY) -ForegroundColor Cyan

            foreach ($i in 0..($Options.Count - 1)) {
                $opt = $Options[$i]
                $optStrLen = $opt.Length + 4
                $oPad = [math]::Floor((92 - $optStrLen) / 2)
                $oPadR = 92 - $optStrLen - $oPad
            
                Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
                Write-Host (' ' * $oPad) -NoNewline
                if ($i -eq $selectedIndex) {
                    Write-Host "$_ARR " -NoNewline -ForegroundColor Cyan
                    Write-Host "[$opt]" -NoNewline -ForegroundColor White
                }
                else {
                    Write-Host "  $opt  " -NoNewline -ForegroundColor DarkGray
                }
                Write-Host (' ' * $oPadR) -NoNewline
                Write-Host $_V -ForegroundColor Cyan
            }
            Write-Host ($pad + $_EMPTY) -ForegroundColor Cyan
            Write-Host ($pad + $_BOT) -ForegroundColor Cyan
            Write-Host ''
        
            $help = '[Use Up/Down Arrows to select, Enter to confirm]'
            $hPad = [math]::Floor((94 - $help.Length) / 2)
            Write-Host ($pad + ' ' * $hPad + $help) -ForegroundColor DarkGray
        
            $keyInfo = [Console]::ReadKey($true)
            if (([int]$keyInfo.Modifiers -band [int][ConsoleModifiers]::Control) -and $keyInfo.Key -eq 'C') {
                if ($cursorHides -ne $null) { try { [Console]::CursorVisible = $true } catch {} }
                return -1
            }
        
            $key = $keyInfo.Key
            if ($key -eq 'UpArrow') {
                $selectedIndex--
                if ($selectedIndex -lt 0) { $selectedIndex = $Options.Count - 1 }
            }
            elseif ($key -eq 'DownArrow') {
                $selectedIndex++
                if ($selectedIndex -ge $Options.Count) { $selectedIndex = 0 }
            }
            elseif ($key -eq 'Enter') {
                if ($cursorHides -ne $null) { try { [Console]::CursorVisible = $true } catch {} }
                return $selectedIndex
            }
        }
    }
    finally {
        try { [Console]::TreatControlCAsInput = $oldTreat } catch {}
    }
}

function Invoke-FetchDetails {
    param($Session, $CookieHeader, $Enrollments, $CourseCache)
    Clear-Host
    Show-Banner
    $pad = Get-UIPad
    Write-Host ($pad + $_SEC_COURSE) -ForegroundColor Cyan
    $courseIndex = 0
    foreach ($e in $Enrollments) {
        $courseIndex++
        $slug = $e.details.slug
        $title = $e.details.title
        $titleShort = if ($title.Length -gt 85) { $title.Substring(0, 82) + '...' } else { $title }
        
        if ([string]::IsNullOrWhiteSpace($slug)) { continue }

        $progress = if ($null -ne $e.progress_percent) { $e.progress_percent } else { '?' }
        $progressNum = if ($progress -ne '?' -and $null -ne $progress) { [int][double]$progress } else { 0 }
        
        Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
        Write-Host " [$courseIndex/$($Enrollments.Count)] $titleShort".PadRight(92) -NoNewline -ForegroundColor White
        Write-Host $_V -ForegroundColor Cyan
        
        $course = if ($CourseCache.ContainsKey($slug)) { $CourseCache[$slug] } else { $null }
        if ($course) {
            $lessons = $course.data.lessons
            $done = 0; $total = 0
            if ($lessons) {
                foreach ($l in $lessons) {
                    if (-not $l.lectures) { continue }
                    foreach ($lec in $l.lectures) {
                        $total++
                        if ([bool]$lec.is_completed) { $done++ }
                    }
                }
            }
            $pending = $total - $done
            $bar = ConvertTo-ProgressBar -Current $progressNum -Total 100 -Width 40
            
            Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
            Write-Host "   $_GT Progress : $bar".PadRight(92) -NoNewline -ForegroundColor DarkCyan
            Write-Host $_V -ForegroundColor Cyan
            
            Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
            Write-Host "   $_GT Lectures : $done Done  $pending Pending".PadRight(92) -NoNewline -ForegroundColor DarkGray
            Write-Host $_V -ForegroundColor Cyan
            Write-Host ($pad + $_EMPTY) -ForegroundColor Cyan
        }
        else {
            Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
            Write-Host "   $_CRS Course data unavailable".PadRight(92) -NoNewline -ForegroundColor Red
            Write-Host $_V -ForegroundColor Cyan
        }
    }
    Write-Host ($pad + $_BOT) -ForegroundColor Cyan
    Write-Host ''
    
    $help = '[Press Enter to return to menu]'
    $hPad = [math]::Floor((94 - $help.Length) / 2)
    Write-Host ($pad + ' ' * $hPad + $help) -NoNewline -ForegroundColor DarkGray
    $null = Read-Host
}

function Show-Divider {
    Write-Host '  ----------------------------------------' -ForegroundColor DarkGray
}

function Show-Step {
    param([string]$Num, [string]$Text)
    Write-Host ''
    $pad = Get-UIPad
    Write-Host ($pad + " +- [$Num] ") -NoNewline -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor White
}

function Show-CourseHeader {
    param([int]$Index, [int]$Total, [string]$Title, $Progress)
    $progressNum = if ($Progress -ne '?' -and $null -ne $Progress) { [int][double]$Progress } else { 0 }
    $bar = ConvertTo-ProgressBar -Current $progressNum -Total 100 -Width 40
    $titleShort = if ($Title.Length -gt 85) { $Title.Substring(0, 82) + '...' } else { $Title }
    $pad = Get-UIPad
    Write-Host ''
    Write-Host ($pad + $_TOP) -ForegroundColor Cyan
    
    Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
    Write-Host " Course $Index of $Total".PadRight(92) -NoNewline -ForegroundColor DarkGray
    Write-Host $_V -ForegroundColor Cyan

    Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
    Write-Host " $titleShort".PadRight(92) -NoNewline -ForegroundColor White
    Write-Host $_V -ForegroundColor Cyan

    Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
    Write-Host " $bar".PadRight(92) -NoNewline -ForegroundColor DarkCyan
    Write-Host $_V -ForegroundColor Cyan
    
    Write-Host ($pad + $_BOT) -ForegroundColor Cyan
}

function Show-Summary {
    param([int]$Skipped, [int]$Already, [int]$Failed, [string]$Elapsed)
    $pad = Get-UIPad
    Write-Host ''
    Write-Host ($pad + $_SEC_RUN) -ForegroundColor Cyan
    
    Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
    Write-Host "  Completed : $Skipped lecture(s)".PadRight(92) -NoNewline -ForegroundColor Green
    Write-Host $_V -ForegroundColor Cyan

    Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
    Write-Host "  Already   : $Already lecture(s)".PadRight(92) -NoNewline -ForegroundColor Gray
    Write-Host $_V -ForegroundColor Cyan

    if ($Failed -gt 0) {
        Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
        Write-Host "  Failed    : $Failed lecture(s)".PadRight(92) -NoNewline -ForegroundColor Red
        Write-Host $_V -ForegroundColor Cyan
    }

    Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
    Write-Host "  Time      : $Elapsed".PadRight(92) -NoNewline -ForegroundColor White
    Write-Host $_V -ForegroundColor Cyan

    Write-Host ($pad + $_BOT) -ForegroundColor Cyan
    Write-Host ''
}

function Get-AllCourseData {
    # Fetches course details for every enrollment and returns a hashtable keyed by slug.
    param($Session, $CookieHeader, $Enrollments)
    $map = @{}
    foreach ($e in $Enrollments) {
        $slug = $e.details.slug
        if ([string]::IsNullOrWhiteSpace($slug)) { continue }
        try { $map[$slug] = Get-CourseDetails -Session $Session -CookieHeader $CookieHeader -Slug $slug }
        catch { Write-Log "Could not prefetch course $slug : $($_.Exception.Message)" 'WARN' }
    }
    return $map
}

#endregion ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

#region ------ MAIN ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function Start-VTUSkipper {
    Send-StartupPing
    Initialize-Logging
    Clear-Host
    Show-Banner

    # ------ Credentials Input ------------------------------------------------------------------------------------------------------------------------------------------------------------
    $pad = Get-UIPad
    Write-Host ($pad + "  $_DIA AUTHENTICATION") -ForegroundColor Cyan
    Write-Host ($pad + '     Email    : ') -NoNewline -ForegroundColor DarkGray
    $email = Read-Host
    Write-Host ($pad + '     Password : ') -NoNewline -ForegroundColor DarkGray
    $secPass = Read-Host -AsSecureString
    Write-Host ''

    # ------ Login ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    Show-Step '1/3' 'Logging in...'
    $auth = Invoke-Login -Email $email -Password $secPass
    $session = $auth.Session
    $cookie = $auth.CookieHeader
    Write-Host ($pad + "    $_CHK OK") -ForegroundColor Green

    # ------ Check enrollments exist before entering menu ------------------------------------------------------------------
    Show-Step '2/3' 'Fetching enrollments...'
    $initialCheck = Get-Enrollments -Session $session -CookieHeader $cookie
    if (-not $initialCheck -or @($initialCheck).Count -eq 0) {
        Write-Host ($pad + '    No enrollments found.') -ForegroundColor Red
        return
    }
    Write-Host ($pad + "    $(@($initialCheck).Count) course(s) found") -ForegroundColor Green

    # ==== MENU LOOP ====
    while ($true) {
        # Prefetch everything before showing the menu so actions are instant
        $pad = Get-UIPad
        Write-Host ''
        Write-Host ($pad + '  Refreshing...') -ForegroundColor DarkGray
        $enrollments = Get-Enrollments    -Session $session -CookieHeader $cookie
        $incompleteCourses = Get-IncompleteCourses -Enrollments $enrollments
        $courseCache = Get-AllCourseData  -Session $session -CookieHeader $cookie -Enrollments $incompleteCourses

        $choices = @('Fetch Course Stats', 'Skip All Courses', 'Exit')
        $sel = Show-InteractiveMenu -Title 'MENU' -Options $choices

        if ($sel -eq -1 -or $sel -eq 2) {
            $pad = Get-UIPad
            Write-Host ''
            Write-Host ($pad + '  Thanks for using vtu-skip!') -ForegroundColor Cyan
            Write-Host ($pad + '  Star or contribute on GitHub:') -ForegroundColor DarkGray
            $esc = [char]27
            $gLnk = "$esc]8;;https://github.com/13arathp/scripts$esc\https://github.com/13arathp/scripts$esc]8;;$esc\"
            $eLnk = "$esc]8;;https://mail.google.com/mail/?view=cm&fs=1&to=barathp.dev@gmail.com$esc\barathp.dev@gmail.com$esc]8;;$esc\"
            Write-Host ($pad + "  $gLnk") -ForegroundColor Yellow
            Write-Host ($pad + "  $eLnk") -ForegroundColor Yellow
            Write-Host ''
            break
        }

        if ($sel -eq 0) {
            Invoke-FetchDetails    -Session $session -CookieHeader $cookie -Enrollments $enrollments -CourseCache $courseCache
        }
        elseif ($sel -eq 1) {
            Invoke-SkipAllCourses  -Session $session -CookieHeader $cookie -Enrollments $enrollments -CourseCache $courseCache
        }
    }
}

function Invoke-SkipAllCourses {
    param($Session, $CookieHeader, $Enrollments, $CourseCache)
    Clear-Host
    Show-Banner
    
    $incompleteCourses = Get-IncompleteCourses -Enrollments $Enrollments
    
    if ($incompleteCourses.Count -eq 0) {
        $pad = Get-UIPad
        Write-Host ''
        Write-Host ($pad + $_TOP) -ForegroundColor Cyan
        Write-Host ($pad + $_EMPTY) -ForegroundColor Cyan
        Write-Host ($pad + $_V) -NoNewline -ForegroundColor Cyan
        Write-Host "  $_CEL ALL COURSES COMPLETE! Nothing to skip.".PadRight(92) -NoNewline -ForegroundColor Green
        Write-Host $_V -ForegroundColor Cyan
        Write-Host ($pad + $_EMPTY) -ForegroundColor Cyan
        Write-Host ($pad + $_BOT) -ForegroundColor Cyan
        Write-Host ''
        Write-Host ($pad + '  Press [Enter] to return to menu... ') -NoNewline -ForegroundColor DarkGray
        $null = Read-Host
        return
    }

    $completedCount = $Enrollments.Count - $incompleteCourses.Count
    $pad = Get-UIPad
    Write-Host ''
    Write-Host ($pad + "  Found $($incompleteCourses.Count) incomplete course(s)") -ForegroundColor Yellow
    Write-Host ($pad + "  Skipping $completedCount already-complete course(s)") -ForegroundColor DarkGray
    Write-Host ''

    Show-Step '3/3' 'Processing courses...'
    Write-Host ''

    $totalSkipped = 0
    $totalAlready = 0
    $totalFailed = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $courseIndex = 0
    foreach ($e in $incompleteCourses) {
        $courseIndex++
        $slug = $e.details.slug
        $title = $e.details.title
        $progress = if ($null -ne $e.progress_percent) { $e.progress_percent } else { '?' }

        Show-CourseHeader $courseIndex $incompleteCourses.Count $title $progress

        # Use pre-fetched course data from cache
        $course = if ($CourseCache.ContainsKey($slug)) { $CourseCache[$slug] } else { $null }
        if (-not $course) {
            Write-Host "   $_CRS No cached data for course" -ForegroundColor Red
            continue
        }

        $lessons = $course.data.lessons
        if (-not $lessons) {
            Write-Host '   ? No lessons found' -ForegroundColor Yellow
            continue
        }

        # Collect pending lectures using List to avoid O(n^2) array copying
        $pending = [System.Collections.Generic.List[object]]::new()
        $done = 0
        $total = 0

        for ($i = 0; $i -lt $lessons.Count; $i++) {
            $lects = $lessons[$i].lectures
            if (-not $lects) { continue }
            $lecNum = 1
            foreach ($lec in $lects) {
                $total++
                if ([bool]$lec.is_completed) { $done++ }
                else { $pending.Add([pscustomobject]@{ Week = ($i + 1); LecNum = $lecNum; Id = "$($lec.id)" }) }
                $lecNum++
            }
        }

        $totalAlready += $done

        Write-Host ''
        $pad = Get-UIPad
        Write-Host ($pad + "    $_GT $done done  ") -NoNewline -ForegroundColor Green
        Write-Host "$($pending.Count) pending" -NoNewline -ForegroundColor Yellow
        Write-Host "  of $total" -ForegroundColor DarkGray

        if ($pending.Count -eq 0) {
            Write-Host ($pad + '    All lectures complete!') -ForegroundColor Green
            continue
        }

        Write-Host ''

        # ------ Send Progress Chunks for Each Pending Lecture ------------------------------------------------------------
        $lecIndex = 0
        foreach ($p in $pending) {
            $pad = Get-UIPad # Update dynamically for resizing
            $lecIndex++
            $prefix = "    [$lecIndex/$($pending.Count)]  W$($p.Week) L$($p.LecNum) : $($p.Id)   "

            # Fetch lecture duration for the progress bar and total_duration_seconds in the POST body.
            $totalSeconds = 0
            try {
                $lectDetail = Get-LectureDetails -Session $Session -CookieHeader $CookieHeader -Slug $slug -LectureId $p.Id
                $totalSeconds = ConvertFrom-VTUDuration -Duration $lectDetail.data.duration
            }
            catch {
                Write-Log "Could not fetch duration for lecture $($p.Id): $($_.Exception.Message)" 'WARN'
            }

            # Always use MaxRetries as the cap - let the server decide when it's done.
            # totalChunks is kept only as a denominator for the local progress bar estimate.
            $fallbackChunks = 30 # ~1 hour fallback if duration is unknown
            $totalChunks = if ($totalSeconds -gt 0) { [math]::Ceiling($totalSeconds / $Config.WatchChunk) } else { $fallbackChunks }
            $maxIter = if ($totalSeconds -gt 0) { $Config.MaxRetries } else { $fallbackChunks }

            $currentTime = 0
            $chunk = $Config.WatchChunk
            $completed = $false
            $tries = 0
            $failed = $false
            $bar = ConvertTo-ProgressBar -Current 0 -Total 100 -Width 16
            $lastBar = ""

            # Print the static prefix for this lecture line
            Write-Host ($pad + $prefix) -NoNewline -ForegroundColor DarkGray

            # Send chunks until the server confirms is_completed=True, or we hit maxIter
            while (-not $completed -and $tries -lt $maxIter) {
                $currentTime += $chunk
                $tries++
                try {
                    $resp = Send-ProgressWithRetry -Session $Session -CookieHeader $CookieHeader `
                        -Slug $slug -LectureId $p.Id `
                        -CurrentTime $currentTime -TotalDuration $totalSeconds -Watched $chunk

                    # Check server confirmation (guard against missing percent field)
                    $percentDone = $resp.data.percent
                    if ([bool]$resp.data.is_completed -or ($null -ne $percentDone -and $percentDone -ge 100)) {
                        $completed = $true
                    }
                    else {
                        # Overwrite same line with updated progress bar
                        if ($null -ne $percentDone) {
                            $bar = ConvertTo-ProgressBar -Current ([int][double]$percentDone) -Total 100 -Width 16
                        }
                        else {
                            $bar = ConvertTo-ProgressBar -Current $tries -Total $totalChunks -Width 16
                        }
                        
                        if ($bar -ne $lastBar) {
                            $pad = Get-UIPad
                            Write-Host "`r$pad$prefix$bar" -NoNewline -ForegroundColor DarkCyan
                            $lastBar = $bar
                        }
                    }
                }
                catch {
                    $failed = $true
                    Write-Log "All retries exhausted: slug=$slug id=$($p.Id) : $($_.Exception.Message)" 'ERROR'
                    break
                }
            }

            # If MaxRetries hit without server confirmation, mark as TIMEOUT (not fake-done)

            # Clear the progress bar line, then print final coloured status
            $clearLine = ' ' * ($prefix.Length + 30)
            $pad = Get-UIPad
            Write-Host "`r$pad$clearLine`r" -NoNewline
            Write-Host ($pad + $prefix) -NoNewline -ForegroundColor DarkGray

            if ($completed) {
                $totalSkipped++
                $bar = ConvertTo-ProgressBar -Current 100 -Total 100 -Width 16
                Write-Host "$bar  " -NoNewline -ForegroundColor DarkCyan
                Write-Host 'DONE' -ForegroundColor Green
            }
            elseif ($failed) {
                $totalFailed++
                Write-Host "$bar  " -NoNewline -ForegroundColor DarkCyan
                Write-Host 'FAIL' -ForegroundColor Red
            }
            else {
                # Hit MaxRetries safety cap (only triggers on unknown-duration lectures)
                $totalFailed++
                Write-Host "$bar  " -NoNewline -ForegroundColor DarkCyan
                Write-Host 'TIME' -ForegroundColor Yellow
            }
        }
    }

    # ------ Final Summary ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    $sw.Stop()
    $elapsed = "$([math]::Floor($sw.Elapsed.TotalMinutes))m $($sw.Elapsed.Seconds)s"
    Show-Summary -Skipped $totalSkipped -Already $totalAlready -Failed $totalFailed -Elapsed $elapsed
    Write-Log "Done. Skipped=$totalSkipped Already=$totalAlready Failed=$totalFailed Time=$elapsed"
    
    $pad = Get-UIPad
    if ($Global:LogFile) {
        Write-Host ''
        Write-Host ($pad + "  $_INF Logs saved to : ") -NoNewline -ForegroundColor DarkGray
        Write-Host $Global:LogFile -ForegroundColor Gray
    }

    Write-Host "`n$pad  Press [Enter] to return to menu... " -NoNewline -ForegroundColor DarkGray
    $null = Read-Host
}

#endregion ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# Entry point -- runs automatically whether piped via iex or executed directly
try {
    Start-VTUSkipper
}
finally {
    if ([Console]::CursorVisible -ne $null) { try { [Console]::CursorVisible = $true } catch {} }
    try {
        [Console]::WriteLine('')
        if ($Global:LogFile) {
            [Console]::ForegroundColor = 'DarkGray'
            [Console]::WriteLine("  $_INF Session logs saved to: $($Global:LogFile)")
        }
        [Console]::ForegroundColor = 'Cyan'
        [Console]::WriteLine('')
        [Console]::WriteLine('  Thanks for using vtu-skip!')
        [Console]::ForegroundColor = 'DarkGray'
        [Console]::WriteLine('  Star or contribute on GitHub:')
        [Console]::ForegroundColor = 'Yellow'
        $esc = [char]27
        $gLnk = "$esc]8;;https://github.com/13arathp/scripts$esc\https://github.com/13arathp/scripts$esc]8;;$esc\"
        $eLnk = "$esc]8;;https://mail.google.com/mail/?view=cm&fs=1&to=barathp.dev@gmail.com$esc\barathp.dev@gmail.com$esc]8;;$esc\"
        [Console]::WriteLine("  $gLnk")
        [Console]::WriteLine("  $eLnk")
        [Console]::WriteLine('')
        [Console]::ResetColor()
    }
    catch {}
}

