Option Explicit

Dim shell, fileSystem, arguments, applicationRoot, mode, scriptName
Dim command, index, exitCode, operation

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
Set arguments = WScript.Arguments
applicationRoot = fileSystem.GetParentFolderName(WScript.ScriptFullName)
operation = "Launcher.Startup"

On Error Resume Next

If arguments.Count = 0 Then
    WriteCrashReport operation, "A launcher mode is required."
    WScript.Quit 1
End If

mode = LCase(CStr(arguments(0)))
If mode = "--ui" Then
    operation = "Launcher.UserInterface"
    scriptName = "WingetAutoUpdater.ps1"
ElseIf mode = "--engine" Then
    operation = "Launcher.UpdateEngine"
    scriptName = "WingetUpdateEngine.ps1"
Else
    WriteCrashReport operation, "The launcher mode is not supported."
    WScript.Quit 1
End If

Dim scriptPath, powerShellPath
scriptPath = fileSystem.BuildPath(applicationRoot, scriptName)
powerShellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")

If Not fileSystem.FileExists(scriptPath) Then
    WriteCrashReport operation, "A required Orbit Updater script is missing: " & scriptPath
    WScript.Quit 1
End If
If Not fileSystem.FileExists(powerShellPath) Then
    WriteCrashReport operation, "Windows PowerShell is unavailable: " & powerShellPath
    WScript.Quit 1
End If

command = QuoteArgument(powerShellPath) & " -NoProfile -NonInteractive -ExecutionPolicy Bypass"
If mode = "--ui" Then command = command & " -STA"
command = command & " -File " & QuoteArgument(scriptPath)
If mode = "--engine" Then
    For index = 1 To arguments.Count - 1
        command = command & " " & QuoteArgument(CStr(arguments(index)))
    Next
End If

Err.Clear
exitCode = shell.Run(command, 0, True)
If Err.Number <> 0 Then
    WriteCrashReport operation, "The hidden PowerShell process could not be started. Error " & Err.Number & ": " & Err.Description
    WScript.Quit 1
End If

WScript.Quit exitCode

Function QuoteArgument(value)
    QuoteArgument = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function

Sub EnsureFolder(path)
    Dim parent
    If fileSystem.FolderExists(path) Then Exit Sub
    parent = fileSystem.GetParentFolderName(path)
    If Len(parent) > 0 And Not fileSystem.FolderExists(parent) Then EnsureFolder parent
    fileSystem.CreateFolder path
End Sub

Sub WriteCrashReport(reportOperation, message)
    On Error Resume Next
    Dim localData, crashRoot, fileName, reportFile
    localData = shell.ExpandEnvironmentStrings("%LocalAppData%")
    crashRoot = fileSystem.BuildPath(localData, "OrbitUpdater\Logs\Crashes")
    EnsureFolder crashRoot
    fileName = Replace(Replace(Replace(Replace(CStr(Now), "/", "-"), ":", "-"), " ", "_"), ".", "-")
    fileName = fileName & "_" & Replace(reportOperation, " ", "_") & "_launcher.log"
    Set reportFile = fileSystem.CreateTextFile(fileSystem.BuildPath(crashRoot, fileName), True, True)
    reportFile.WriteLine "Timestamp: " & CStr(Now)
    reportFile.WriteLine "App version: 0.9.1-beta.1"
    reportFile.WriteLine "Operation: " & reportOperation
    reportFile.WriteLine "Windows version: " & shell.ExpandEnvironmentStrings("%OS%")
    reportFile.WriteLine "Message: " & message
    reportFile.Close
End Sub
