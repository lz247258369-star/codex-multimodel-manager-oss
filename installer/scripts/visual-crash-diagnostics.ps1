# Global crash diagnostics for the V4 WPF host.
# The log is created as soon as this runtime is loaded so a real-machine crash
# always leaves a known file to inspect, even when the narrower grouping logger
# never gets a chance to write.

$script:managerCrashDiagnosticsInstalled = $false
$script:managerCrashLogPath = Join-Path $env:LOCALAPPDATA "Codex Multi-Model Manager\logs\v4-crash.log"

function Write-ManagerCrashDiagnostic([string]$Message) {
    try {
        $logRoot = Split-Path -Parent $script:managerCrashLogPath
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        $line = "{0:o} pid={1} {2}" -f [DateTime]::UtcNow,$PID,$Message
        Add-Content -LiteralPath $script:managerCrashLogPath -Value $line -Encoding utf8
    }
    catch { }
}

function Register-ManagerCrashDiagnostics($Window) {
    if ($script:managerCrashDiagnosticsInstalled -or $null -eq $Window) { return }
    $script:managerCrashDiagnosticsInstalled = $true

    # Create the file immediately. Absence of the file after V4 launch therefore
    # means this runtime was not loaded, which is itself useful diagnostic data.
    Write-ManagerCrashDiagnostic "STARTUP diagnostics-attached"

    try {
        $dispatcherHandler = {
            param($sender,$eventArgs)
            try {
                $text = if ($null -ne $eventArgs.Exception) {
                    $eventArgs.Exception.ToString()
                }
                else {
                    "Unknown DispatcherUnhandledException"
                }
                Write-ManagerCrashDiagnostic ("DISPATCHER-UNHANDLED " + $text)
            }
            catch { }
            # Logging only. Do not mark Handled here; preserve the real failure
            # semantics so diagnostics cannot mask a production bug.
        }.GetNewClosure()
        $Window.Dispatcher.add_UnhandledException($dispatcherHandler)
        $script:managerDispatcherCrashHandler = $dispatcherHandler
    }
    catch {
        Write-ManagerCrashDiagnostic ("DIAGNOSTIC-HOOK-ERROR dispatcher " + $_.Exception.Message)
    }

    try {
        $Window.Add_Closed({
            Write-ManagerCrashDiagnostic "WINDOW-CLOSED"
        })
    }
    catch {
        Write-ManagerCrashDiagnostic ("DIAGNOSTIC-HOOK-ERROR closed " + $_.Exception.Message)
    }

    try {
        $domainHandler = [System.UnhandledExceptionEventHandler]{
            param($sender,$eventArgs)
            try {
                $payload = if ($null -ne $eventArgs.ExceptionObject) {
                    $eventArgs.ExceptionObject.ToString()
                }
                else {
                    "Unknown AppDomain exception"
                }
                Write-ManagerCrashDiagnostic ("APPDOMAIN-UNHANDLED terminating=$($eventArgs.IsTerminating) " + $payload)
            }
            catch { }
        }
        [AppDomain]::CurrentDomain.add_UnhandledException($domainHandler)
        $script:managerAppDomainCrashHandler = $domainHandler
    }
    catch {
        Write-ManagerCrashDiagnostic ("DIAGNOSTIC-HOOK-ERROR appdomain " + $_.Exception.Message)
    }
}

Register-ManagerCrashDiagnostics $window
