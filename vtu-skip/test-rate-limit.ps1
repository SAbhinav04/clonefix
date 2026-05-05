Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Config = [pscustomobject]@{
    Origin         = 'https://online.vtu.ac.in'
    BaseUrl        = 'https://online.vtu.ac.in/api/v1'
    LoginEndpoint  = '/auth/login'
    EnrollEndpoint = '/student/my-enrollments'
}

function New-Headers {
    param($Referer, $CookieHeader, [switch]$JsonContent, [switch]$IncludeXHR)
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

function Invoke-Login {
    param([string]$Email, [securestring]$Password)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $url = $Config.BaseUrl + $Config.LoginEndpoint
    $headers = New-Headers -Referer "$($Config.Origin)/auth/login" -CookieHeader 'refresh_token=' -JsonContent
    $loginJson = @{ email = $Email; password = $plain } | ConvertTo-Json -Depth 10
    
    $null = Invoke-RestMethod -Uri $url -Method POST -Headers $headers -Body $loginJson -WebSession $session -ErrorAction Stop
    $cookies = $session.Cookies.GetCookies([uri]$Config.Origin)
    $at = ($cookies | Where-Object Name -eq 'access_token').Value
    $rt = ($cookies | Where-Object Name -eq 'refresh_token').Value
    return [pscustomobject]@{ Session = $session; CookieHeader = "access_token=$at; refresh_token=$rt" }
}

function Format-EnrollmentArray {
    param($Resp)
    $data = if ($Resp.data) { $Resp.data } else { $Resp }
    if ($data -is [System.Array]) { return $data }
    $items = @()
    foreach ($p in $data.PSObject.Properties) {
        if ($p.Name -match '^\d+$') { $items += $p.Value }
    }
    return $items
}

function Start-RateLimitTest {
    Clear-Host
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  VTU Delay/Rate Limit Tester" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    
    Write-Host "Email: " -NoNewline; $email = Read-Host
    Write-Host "Password: " -NoNewline; $secPass = Read-Host -AsSecureString
    
    Write-Host "`n[*] Logging in..." -ForegroundColor Yellow
    $auth = Invoke-Login -Email $email -Password $secPass
    
    Write-Host "[*] Fetching first available course..." -ForegroundColor Yellow
    $enrollUrl = $Config.BaseUrl + $Config.EnrollEndpoint
    $eHeaders = New-Headers -Referer "$($Config.Origin)/student/enrollments" -CookieHeader $auth.CookieHeader -IncludeXHR
    $enrollmentsResp = Invoke-RestMethod -Uri $enrollUrl -Method GET -Headers $eHeaders -WebSession $auth.Session
    $enrollments = Format-EnrollmentArray -Resp $enrollmentsResp
    
    $firstCourse = $null
    foreach ($e in $enrollments) {
        $prog = if ($null -ne $e.progress_percent) { [double]$e.progress_percent } else { 0 }
        if ($null -ne $e.details -and -not [string]::IsNullOrWhiteSpace($e.details.slug) -and $prog -lt 100) {
            $firstCourse = $e
            break
        }
    }
    
    if (-not $firstCourse) {
        Write-Host "[!] Could not find any INCOMPLETE enrollments to test." -ForegroundColor Red
        return
    }
    
    $slug = $firstCourse.details.slug
    
    Write-Host "[*] Fetching course details for '$slug'..." -ForegroundColor Yellow
    $cUrl = "$($Config.BaseUrl)/student/my-courses/$slug"
    $cHeaders = New-Headers -Referer "$($Config.Origin)/student/course/$slug" -CookieHeader $auth.CookieHeader
    $course = Invoke-RestMethod -Uri $cUrl -Method GET -Headers $cHeaders -WebSession $auth.Session
    
    Write-Host "[*] Searching for a 'working' lecture to test against..." -ForegroundColor Yellow
    $testLectureId = $null
    $testTotalSeconds = 0
    
    foreach ($l in $course.data.lessons) {
        foreach ($lec in $l.lectures) {
            if (-not [bool]$lec.is_completed) {
                Write-Host "    -> Testing lecture ID $($lec.id)... " -NoNewline
                
                try {
                    # Fetch real duration
                    $lectDetailUrl = "$($Config.BaseUrl)/student/my-courses/$slug/lectures/$($lec.id)"
                    $lHeaders = New-Headers -Referer "$($Config.Origin)/student/learning/$slug" -CookieHeader $auth.CookieHeader -IncludeXHR
                    $lectDetail = Invoke-RestMethod -Uri $lectDetailUrl -Method GET -Headers $lHeaders -WebSession $auth.Session
                    
                    $dur = ""
                    try { $dur = $lectDetail.data.duration } catch {}
                    
                    $parts = @()
                    if ($dur) {
                        foreach ($p in ($dur -split '[:\s]+')) { if ($p -match '^\d+$') { $parts += $p } }
                    }
                    $ts = 0
                    if ($parts.Count -ge 3) { $ts = ([int]$parts[0] * 3600) + ([int]$parts[1] * 60) + [int]$parts[2] }

                    # Test ping
                    $testUrl = "$($Config.BaseUrl)/student/my-courses/$slug/lectures/$($lec.id)/progress"
                    $testHeaders = New-Headers -Referer "$($Config.Origin)/student/learning/$slug" -CookieHeader $auth.CookieHeader -JsonContent -IncludeXHR
                    $testBody = @{ current_time_seconds = 99999; total_duration_seconds = $ts; seconds_just_watched = 10 } | ConvertTo-Json
                    
                    $null = Invoke-RestMethod -Uri $testUrl -Method POST -Headers $testHeaders -Body $testBody -WebSession $auth.Session -ErrorAction Stop
                    
                    Write-Host "WORKING!" -ForegroundColor Green
                    $testLectureId = $lec.id
                    $testTotalSeconds = $ts
                    break
                }
                catch {
                    Write-Host "BROKEN ($($_.Exception.Message))" -ForegroundColor Red
                }
            }
        }
        if ($testLectureId) { break }
    }

    if (-not $testLectureId) {
        Write-Host "`n[!] Could not find any working incomplete lecture to test against! Every single one threw an error." -ForegroundColor Red
        return
    }

    Write-Host "`n[*] Starting Rate Limit Tests on Lecture ID: $testLectureId" -ForegroundColor Cyan
    $url = "$($Config.BaseUrl)/student/my-courses/$slug/lectures/$testLectureId/progress"
    $headers = New-Headers -Referer "$($Config.Origin)/student/learning/$slug" -CookieHeader $auth.CookieHeader -JsonContent -IncludeXHR
    $body = @{ current_time_seconds = 99999; total_duration_seconds = $testTotalSeconds; seconds_just_watched = 10 } | ConvertTo-Json
    
    $delaysToTest = @(0, 50, 100, 150, 200, 300, 500)
    
    Write-Host "`n[*] Starting Rate Limit Tests (Sending 10 requests per delay tier)`n" -ForegroundColor Cyan
    
    foreach ($delay in $delaysToTest) {
        Write-Host "Testing DelayMs = $delay ms ... " -NoNewline
        $success = 0
        $fails = 0
        $firstError = ""
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        
        for ($i = 0; $i -lt 10; $i++) {
            try {
                $null = Invoke-RestMethod -Uri $url -Method POST -Headers $headers -Body $body -WebSession $auth.Session -ErrorAction Stop
                $success++
            }
            catch {
                $fails++
                if (-not $firstError) {
                    $firstError = $_.Exception.Message
                    if ($_.Exception.Response) {
                        try {
                            $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                            $firstError += " | Body: " + $sr.ReadToEnd()
                        } catch {}
                    }
                }
            }
            if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
        }
        $sw.Stop()
        
        if ($fails -eq 0) {
            Write-Host "PERFECT ($success/10 succeeded) - Took $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
        } else {
            Write-Host "FAILED ($fails/10 failed) - Took $($sw.ElapsedMilliseconds)ms" -ForegroundColor Red
            Write-Host "   -> Error: $firstError" -ForegroundColor DarkGray
        }
        
        # Cooldown between tests so server resets rate limit window
        Start-Sleep -Seconds 2
    }
    
    Write-Host "`n[i] Test complete. Pick the lowest DelayMs that consistently gets PERFECT (0 fails)." -ForegroundColor Cyan
}

try {
    Start-RateLimitTest
}
finally {
    Write-Host "`nPress Enter to exit..."
    $null = Read-Host
}
