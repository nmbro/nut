# Network UPS Tools: AppVeyor CI recipe step (see appveyor.yml), NUT for Windows
# with MSYS2 UCRT64 (x64): report links to the built archives in the job messages.
#
# Copyright (C) 2022-2026	Jim Klimov <jimklimov+nut@gmail.com>

# Consider APPVEYOR_PULL_REQUEST_HEAD_COMMIT (PR) vs APPVEYOR_REPO_COMMIT (target branch, or ephemeral)
$nut7z = "NUT-for-Windows-x86_64-SNAPSHOT-$($env:APPVEYOR_BUILD_VERSION).7z"
$msg = "A 7-zip archive with built NUT for Windows binaries is temporarily available: [$($nut7z)]($($env:APPVEYOR_URL)/api/buildjobs/$($env:APPVEYOR_JOB_ID)/artifacts/$($nut7z))"
echo $msg
Add-AppveyorMessage $msg
$dbg7z = "NUT-debuginfo-for-Windows-x86_64-SNAPSHOT-$($env:APPVEYOR_BUILD_VERSION).7z"
$msg = "Debug information for these binaries (unpack it into the same place as the binaries archive, for debuggers to find it): [$($dbg7z)]($($env:APPVEYOR_URL)/api/buildjobs/$($env:APPVEYOR_JOB_ID)/artifacts/$($dbg7z))"
echo $msg
echo "build-id:$($env:APPVEYOR_BUILD_ID) job-id:$($env:APPVEYOR_JOB_ID) prj-id:$($env:APPVEYOR_PROJECT_ID)"
Add-AppveyorMessage $msg
