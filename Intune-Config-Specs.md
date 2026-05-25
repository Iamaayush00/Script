# HP Bloatware Removal — Intune Configuration Specifications

## App Information

| Field       | Value                                                        |
|-------------|--------------------------------------------------------------|
| Name        | `HP Bloatware Removal`                                       |
| Description | `Removes HP and Poly bloatware during Autopilot provisioning` |
| Publisher   | Your org name                                                |
| App version | `5.0`                                                        |
| Category    | `Computer Management`                                        |

---

## Program

| Field                   | Value                                                                                            |
|-------------------------|--------------------------------------------------------------------------------------------------|
| Install command         | `powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File Install.ps1`   |
| Uninstall command       | `powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File Uninstall.ps1` |
| Install behavior        | System                                                                                           |
| Device restart behavior | App install may force a device restart                                                           |

---

## Requirements

| Field          | Value              |
|----------------|--------------------|
| OS architecture | 64-bit            |
| Minimum OS     | Windows 11 21H2    |

---

## Detection Rules

| Field                        | Value                              |
|------------------------------|------------------------------------|
| Rules format                 | Manually configure detection rules |
| Rule type                    | File                               |
| Path                         | `C:\Logs`                          |
| File or folder               | `HPBloatware.log`                  |
| Detection method             | File or folder exists              |
| Associated with a 32-bit app | No                                 |

---

## Assignments

| Field           | Value                          |
|-----------------|--------------------------------|
| Assignment type | Required                       |
| Assign to       | Your Autopilot device group    |
| Mode            | Device                         |

---

## ESP Profile

*Devices → Enrollment → Windows → Enrollment Status Page*

| Field                                                        | Value                        |
|--------------------------------------------------------------|------------------------------|
| Block device use until all apps and profiles are installed   | Yes                          |
| Block device use until these required apps are installed     | Add **HP Bloatware Removal** |

---

## Notes

- **Install behavior must be System** — the script requires admin rights to remove AppX packages for all users, stop services, and modify HKLM registry keys.
- **Assign to a device group, not a user group** — user group assignments do not reliably fire during the device phase of ESP.
- **Detection logic** — Intune considers the app installed once `C:\Logs\HPBloatware.log` exists. To force a re-run on a device, delete that file and trigger a sync in Intune.
