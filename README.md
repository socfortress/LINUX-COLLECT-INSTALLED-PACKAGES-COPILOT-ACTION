## Collect-Installed-Packages.sh

This script collects a list of installed packages, available updates, and recent installations from the system's package manager, providing a JSON-formatted output for integration with security tools like OSSEC/Wazuh.

### Overview

The `Collect-Installed-Packages.sh` script detects the system's package manager (APT or RPM/YUM/DNF), collects installed packages, lists available updates, and reports packages installed in the last 7 days. Output is formatted as JSON for active response workflows.

### Script Details

#### Core Features

1. **Package Manager Detection**: Supports both Debian-based (APT) and RedHat-based (RPM/YUM/DNF) systems.
2. **Installed Packages**: Lists all installed packages and their versions.
3. **Available Updates**: Lists packages with available updates.
4. **Recent Installs**: Reports packages installed in the last 7 days.
5. **JSON Output**: Generates a structured JSON report for integration with security tools.
6. **Logging Framework**: Provides detailed logs for script execution.
7. **Log Rotation**: Implements automatic log rotation to manage log file size.

### How the Script Works

#### Command Line Execution
```bash
./Collect-Installed-Packages.sh
```

#### Parameters

| Parameter | Type | Default Value | Description |
|-----------|------|---------------|-------------|
| `ARLog`   | string | `/var/ossec/active-response/active-responses.log` | Path for active response JSON output |
| `LogPath` | string | `/tmp/Collect-Installed-Packages.sh-script.log` | Path for detailed execution logs |
| `LogMaxKB` | int | 100 | Maximum log file size in KB before rotation |
| `LogKeep` | int | 5 | Number of rotated log files to retain |

### Script Execution Flow

#### 1. Initialization Phase
- Clears the active response log file
- Rotates the detailed log file if it exceeds the size limit
- Logs the start of the script execution

#### 2. Package Collection
- Detects the system's package manager
- Collects installed packages and versions
- Lists available updates
- Reports recent installs (last 7 days)

#### 3. JSON Output Generation
- Formats package details into a JSON object
- Writes the JSON result to the active response log

### JSON Output Format

#### Example Response
```json
{
  "timestamp": "2025-07-18T10:30:45.123Z",
  "host": "HOSTNAME",
  "action": "Collect-Installed-Packages.sh",
  "data": {
    "package_manager": "apt",
    "installed_packages": [
      "bash 5.0-6ubuntu1.1",
      "coreutils 8.30-3ubuntu2"
    ],
    "available_updates": [
      "bash 5.0-6ubuntu1.2"
    ],
    "recent_installs_7days": [
      "2025-07-17 bash 5.0-6ubuntu1.1"
    ]
  },
  "copilot_soar": true
}
```

### Implementation Guidelines

#### Best Practices
- Run the script with appropriate permissions to access package manager data
- Validate the JSON output for compatibility with your security tools
- Test the script in isolated environments

#### Security Considerations
- Ensure minimal required privileges
- Protect the output log files

### Troubleshooting

#### Common Issues
1. **Permission Errors**: Ensure read access to package manager logs and databases
2. **Missing Data**: Some package managers may not log recent installs
3. **Log File Issues**: Check write permissions

#### Debugging
Enable verbose logging:
```bash
VERBOSE=1 ./Collect-Installed-Packages.sh
```

### Contributing

When modifying this script:
1. Maintain the package collection and JSON output structure
2. Follow Shell scripting best practices
3. Document any additional functionality
4. Test thoroughly in isolated environments
