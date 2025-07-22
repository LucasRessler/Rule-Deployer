# Rule Deployer

**Rule Deployer** is a PowerShell tool that streamlines the deployment of NSX Security Groups, Services, and Firewall Rules, specific to FCI.

It supports both JSON-based and Excel-based input formats, and automates conversion into the necessary API calls for deployment.

The tool pre-parses values that require special formatting, performs preemptive integrity checks, and logs detailed error messages to catch mistakes before deployment.

> 💡 Requests for Security Groups, Services and Firewall Rules can be deployed in a single execution, even if the resources depend on each other.
> Rule Deployer ensures that Rules are handled **last** when **creating or updating**, and **first** when **deleting**.

> ⏱️ Due to VRA API limitations, bulk operations are not supported. All resources are deployed sequentially, which may increase execution time.

## 📖 Table of Contents
- [📦 Quick Start](#-quick-start)
- [🔧 Prerequisites](#-prerequisites)
- [🧪 Usage](#-usage)
- [⚙️ Configuration](#️-configuration)
- [🗝️ Environment Variables](#️-environment-variables)
- [📥 Input Overview](#-input-overview)
- [🧾 Input Schema Reference](#-input-schema-reference)
- [📘 JSON Input](#-json-input--inlinejson)
- [📗 Excel Input](#-excel-input--excelfilepath)
- [🗂️ NSX-Image](#️-nsx-image)
- [🎯 Exit Code Reference](#-exit-code-reference)

---

## 📦 Quick Start

### Basic usage with JSON input:

```
.\rule_deployer -InlineJson <JSON String> -Action { auto | create | update | delete }
```

### Basic usage with Excel input:

```
.\rule_deployer -ExcelFilePath <Path to Excel workbook> -Tenant <Tenant name> -Action { auto | create | update | delete }
```

### 📋 Example Executions

- #### 📘 Create resources from a JSON file:

  ```powershell
  .\rule_deployer -InlineJson (Get-Content '.\fw-rules.json' -Raw) -Action create
  ```

- #### 📗 Create or update resources from an Excel workbook:

  ```powershell
  .\rule_deployer -ExcelFilePath '.\FW-Rules.xlsx' -Tenant t001 -Action auto
  ```

- #### 🗑️ Delete a specific service:

  ```powershell
  .\rule_deployer -InlineJson '{"t001": {"services": [{"name": "unused-service"}]}}' -Action delete
  ```

---

## 🔧 Prerequisites

To use Rule Deployer successfully, ensure the following are in place:
- ✅ PowerShell 5.1+ (Windows) or PowerShell Core 7+ (cross-platform)
- ✅ The [`ImportExcel`](https://www.powershellgallery.com/packages/ImportExcel) PowerShell module for Excel input
- ✅ Access to NSX and VRA APIs from your machine
- ✅ A valid configuration file (`config.json`) or CLI overrides
- ✅ Required credentials set via environment variables or a `.env` file
- ✅ (Optional) Excel installed, if editing `.xlsx` files manually

> 💡 **Need to enable script execution?**  
> Open PowerShell **as Administrator** and run:
> ```powershell
> Set-ExecutionPolicy Unrestricted
> ```

> 💡 **Need Excel input support?**  
> Install the `ImportExcel` module by running:
> ```powershell
> Install-Module ImportExcel -Scope CurrentUser
> ```

---

## 🧪 Usage

Rule Deployer is launched by executing the `rule_deployer.ps1` script from a PowerShell command line.

Input can be provided either as an inline JSON string or via a path to an Excel workbook.

The script relies on a [configuration file](#️-configuration) and a few [environment variables](#-environment-variables).

💡 These values must be provided at a minimum for execution:
- The action to perform (`-Action`)
- One input source (`-InlineJson` or `-ExcelFilePath` + `-Tenant`)
- The VRA host (`-VraHostName` via CLI or [config](#️-configuration))
- VRA Catalog IDs of the resources (via [config](#️-configuration))
- Credentials for CatalogDB, CMDB and RMDB (via [environment variables](#️-environment-variables))

### Synopsis

```
.\rule_deployer { -InlineJson <JSON string> [ -Tenant <Tenant name> ] | -ExcelFilePath <Path to Excel> -Tenant <Tenant name> } -Action { auto | create | update | delete }
  [ -RequestId <Request ID> ] [ -ConfigPath <Path to config file> ] [ -EnvFile <Path to Env file> ] [ -LogDir <Path to log output directory> ]
  [ -NsxImagePath <Path to NSX Image file> ] [ -VraHostName <Name of VRA host> ] [ -NsxHostDomain <Domain of NSX host> ]
```

### CLI Parameters:

- `-InlineJson`: Provide input via an inline JSON string
  - See the [JSON Input section](#-json-input--inlinejson) for details
- `-ExcelFilePath`: Provide input via an Excel workbook
  - See the [Excel Input section](#-excel-input--excelfilepath) for details
- `-Tenant`: Specify the tenant to deploy on
  - Required when using `-ExcelFilePath`
  - Optional when using `-InlineJson`, but affects how input is parsed:
    - If set, the JSON input must contain top-level resource keys only (no tenant nesting)
    - If not set, the input must contain one or more tenant blocks as top-level keys
- `-Action`: Specify the deployment action
  - Use `create`, `update`, and `delete` to explicitly control behavior
  - Use `auto` to automatically create new resources and update existing ones
- `-RequestId`: Inject a request ID to be used for all resources
  - Fills out empty `request_id` fields or is added to `update_requests`
- `-ConfigPath` : Set where the config file is located
- `-EnvFile` : Override the configured path to the environment file
- `-NsxImagePath`: Override the path to the [NSX Image file](#️-nsx-image)
- `-LogDir` : Override the configured path to the log output directory
- `-NsxHostDomain`: Override the configured domain of the NSX host
- `-VRAHostName`: Override the configured VRA host name
  - **Must be set** either here or in the config file

| Parameter        | Required      | Can also be set in config | Default Value                 |
| ---------------- | ------------- | ------------------------- | ----------------------------- |
| `-InlineJson`    | ✅ Required*  | ❌ Only via CLI           | -                             |
| `-ExcelFilePath` | ✅ Required*  | ❌ Only via CLI           | -                             |
| `-Tenant`        | ✅ Required** | ❌ Only via CLI           | -                             |
| `-Action`        | ✅ Required   | ❌ Only via CLI           | -                             |
| `-RequestId`     | ❌ Optional   | ❌ Only via CLI           | -                             |
| `-ConfigPath`    | ❌ Optional   | ❌ Only via CLI           | `<ScriptRoot>\config.json`    |
| `-EnvFile`       | ❌ Optional   | ✅ Can be set in config   | `<ScriptRoot>\.env`           |
| `-NsxImagePath`  | ❌ Optional   | ✅ Can be set in config   | `<ScriptRoot>\nsx_image.json` |
| `-LogDir`        | ❌ Optional   | ✅ Can be set in config   | `<ScriptRoot>\logs\`          |
| `-NsxHostDomain` | ❌ Optional   | ✅ Can be set in config   | -                             |
| `-VraHostName`   | ✅ Required   | ✅ Can be set in config   | -                             |

> ✅*: One of either `-InlineJson` or `-ExcelFilePath` is required for input

> ✅**: `-Tenant` is required for `-ExcelFilePath` and slightly changes the behavior of `-InlineJson`

---

## ⚙️ Configuration

Rule Deployer can be configured with a `config.json` file.

This file provides a centralized way to manage default values, paths, and catalog configuration -
especially useful in automated pipelines or when using the tool repeatedly in the same environment.

> 💡 Many of these values can also be set directly with CLI input-parameters.
> In this case, the CLI-arguments take priority over the configured values.

### Configuration File Format:

```jsonc
{
  "EnvFile": "path/to/.env_file",           // Default: <ScriptRoot>/.env
  "NsxImagePath": "path/to/nsx_image",      // Default: <ScriptRoot>/nsx_image.json
  "LogDir": "path/to/log_output_directory", // Default: <ScriptRoot>/logs/

  "NsxHostDomain": "https://nsx.host.url", // No Default; Optional
  "VraHostName": "name-of-vra-host",       // No Default; Required

  "excel_sheetnames": {
    "security_groups": "SecurityGroups-SheetName", // Default: SecurityGroups
    "services": "Services-SheetName",              // Default: Services
    "rules": "FirewallRules-SheetName"             // Default: Rules
  },

  "catalog_ids": {
    "security_groups": "SecurityGroups-VRA-Catalog-ID", // No Default; Required
    "services": "Services-VRA-Catalog-ID",              // No Default; Required
    "rules": "FirewallRules-VRA-Catalog-ID"             // No Default; Required
  }
}
```

> 📌 `NsxHostDomain` is entirely optional, but strongly recommended, if accessing the underlying NSX-infrastructure is a possibility.
> Providing this together with NSX-specific environment variables greatly improves the reliability of resource integrity checks and `-Action auto`.

---

## 🗝️ Environment Variables

Rule Deployer depends on a few environment variables for various credentials.

These can be set either in your shell environment or in a `.env` file located in the root folder.
The `.env` file will be auto-loaded at runtime.

> ⚠️ Parsing of the `.env` file is simplistic:
> Everything after the first `=` is taken as the value (including quotes).

### **Required Variables**

```env
cmdb_user=NEO\cmdb-username
cmdb_password=cmdb-password
catalogdb_user=neo\catalogdb-username
catalogdb_password=catalogdb-password
rmdb_user=rmdb-username
rmdb_password=rmdb-password
```

### **Optional Variables**

```env
nsx_user=nsx-username
nsx_password=nsx-password
```

> 📌 Providing these together with the `NsxHostDomain` config-value greatly improves the reliability of resource integrity checks and `-Action auto`.

---

## 📥 Input Overview

Rule Deployer supports two input formats:
- **📘 JSON input** via the `-InlineJson` parameter.
- **📗 Excel input** via the `-ExcelFilePath` parameter.

Despite different formats, the same resource types and value structures apply:
- 🛡️ Security Groups
- ⚙ Services
- 🔥 Firewall Rules

Some fields behave differently depending on input format (notably Gateway selection for Rules).  
These differences are noted where applicable.

---

## 🧾 Input Schema Reference

### 🛡️ Security Groups

| Field            | Required                      | JSON Field        | Format                                    | Notes                      |
| ---------------- | ----------------------------- | ----------------- | ----------------------------------------- | -------------------------- |
| **Name**         | ✅ Always Required            | `name`            | String of letters, numbers, `.`, `-`, `_` | Identifier; must be unique |
| **IP-Addresses** | ✅ Required for Create/Update | `ip_addresses`    | `IPv4` or `IPv4/CIDR`                     | Multiple allowed           |
| **Hostname**     | ❌ Optional                   | `hostname`        | Any string                                | Multiple allowed           |
| **Comment**      | ❌ Optional                   | `comment`         | Any string                                | One value only             |
| **Request ID**   | ❌ Optional                   | `request_id`      | `SCTASK1234567`, `INC1234567`, etc.       | One value only             |
| **Update IDs**   | ❌ Optional                   | `update_requests` | Same format as Request ID                 | Multiple allowed           |

### ⚙️ Services

| Field          | Required                      | JSON Field        | Format                                            | Notes                                     |
| -------------- | ----------------------------- | ----------------- | ------------------------------------------------- | ----------------------------------------- |
| **Name**       | ✅ Always Required            | `name`            | String of letters, numbers, `.`, `-`, `_`         | Identifier; must be unique                |
| **Ports**      | ✅ Required for Create/Update | `ports`           | `<protocol>:<port>` or `<protocol>:<start>-<end>` | Protocols: `tcp`, `udp`; multiple allowed |
| **Comment**    | ❌ Optional                   | `comment`         | Any string                                        | One value only                            |
| **Request ID** | ❌ Optional                   | `request_id`      | `SCTASK1234567`, `INC1234567`, etc.               | One value only                            |
| **Update IDs** | ❌ Optional                   | `update_requests` | Same format as Request ID                         | Multiple allowed                          |

> ⚠️ ICMP is not supported. Use predefined NSX ICMP Services (e.g. "ICMP ALL", "ICMP Echo Request").


### 🔥 Firewall Rules

| Field            | Required                      | JSON Field        | Format                                          | Notes                                                |
| ---------------- | ----------------------------- | ----------------- | ----------------------------------------------- | ---------------------------------------------------- |
| **CIS ID**       | ✅ Always Required            | `cis_id`          | String of 4-8 digits                            | ID of associated CIS-request; One value only         |
| **Index**        | ✅ Always Required            | `index`           | Numeric                                         | Differentiates rules per CIS ID                      |
| **Sources**      | ✅ Required for Create/Update | `sources`         | Alphanumeric / `any`                            | Refers to defined Security Groups; Multiple allowed  |
| **Destinations** | ✅ Required for Create/Update | `destinations`    | Alphanumeric / `any`                            | Refers to defined Security Groups; Multiple allowed  |
| **Services**     | ✅ Required for Create/Update | `services`        | Alphanumeric / `any`                            | Refers to defined/default Services; Multiple allowed |
| **Comment**      | ❌ Optional                   | `comment`         | Any string                                      | One value only                                       |
| **Request ID**   | ❌ Optional                   | `request_id`      | Same as other types                             | One value only                                       |
| **Update IDs**   | ❌ Optional                   | `update_requests` | Same format                                     | Multiple allowed                                     |
| **Gateway**      | ❌ Optional                   | `gateway`         | One or both of: `"T0 Internet"`, `"T1 Payload"` | Defaults to `T1 Payload`; See notes below            |

> ⚠️ In Excel input, **Gateways** are selected using **two separate boolean-style fields**:
> `T0 Internet` and `T1 Payload`. If both are selected (non-empty), Rule is deployed for both.

> 🚪 If no **Gateway** is specified, `T1 Payload` is chosen by default.

> 🧠 A rule’s identity is defined by its **Tenant + Gateway + CIS ID + Index**.
> Multiple rules may share CIS ID and Index as long as one of these differs.

> 🗯️ Rule names are automatically generated as `IDC<CIS-ID>_<Index>` (eg. `IDC12345_1`).

---

## 📘 JSON Input (`-InlineJson`)

Use the `-InlineJson` parameter to pass a JSON string defining your resources.
The JSON input supports two structurally equivalent styles: **flat** and **nested**.

> 💡 You can define multiple tenants within a single JSON string.
> Alternatively, if you're using the `-Tenant` parameter, omit tenant names and provide top-level resource keys instead.

### 🧱 JSON Structure Overview

```jsonc
{
  "tenant_name": {
    "security_groups": "...",
    "services": "...",
    "rules": "..."
  },
  "other_tenant_name": {
    "security_groups": "...",
    "services": "...",
    "rules": "..."
  }
  // ...
}
```

If `-Tenant` is used, structure should look like:

```json
{
  "security_groups": "...",
  "services": "...",
  "rules": "..."
}
```

### 🔹 Flat Format

Each resource group is an **array of objects**, one per resource.

```json
{
  "tenant_name": {
    "security_groups": [
      {
        "name": "secgroup_name1",
        "ip_addresses": ["10.0.0.1", "10.0.0.20/24"],
        "hostname": ["hostname1"],
        "comment": "Optional comment",
        "request_id": "SCTASK01234567",
        "update_requests": ["SCTASK01234568"]
      }
    ],
    "services": [
      {
        "name": "service_name1",
        "ports": ["tcp:123", "udp:120-130"],
        "comment": "Service description",
        "request_id": "SCTASK01234567"
      }
    ],
    "rules": [
      {
        "gateway": ["T0 Internet"],
        "cis_id": "123456",
        "index": "1",
        "sources": ["secgroup_name1"],
        "destinations": ["secgroup_name1"],
        "services": ["service_name1"],
        "comment": "Rule description",
        "request_id": "SCTASK01234567"
      }
    ]
  }
}
```

### 🔸 Nested Format

Each group is an **object of objects**, using names or IDs as keys.

- Security Groups and Services use their **names** keys.
- Rules are grouped first by **gateway**, then **CIS ID**, then **index**.

```jsonc
{
  "tenant_name": {
    "security_groups": {
      "secgroup_name1": {
        "ip_addresses": ["10.0.0.1", "10.0.0.20/24"],
        "hostname": ["hostname1"],
        "comment": "Optional comment",
        "request_id": "SCTASK01234567"
      }
    },
    "services": {
      "service_name1": {
        "ports": ["tcp:123", "udp:120-130"],
        "comment": "Service description",
        "request_id": "SCTASK01234567"
      }
    },
    "rules": {
      "T0 Internet": {   // Gateway
        "123456": {      // CIS ID
          "1": {         // Index
            "sources": ["secgroup_name1"],
            "destinations": ["secgroup_name1"],
            "services": ["service_name1"],
            "comment": "Rule description",
            "request_id": "SCTASK01234567"
          }
        }
      }
    }
  }
}
```

### 🔀 Format Notes

| Format     | Structure                | When to Use                      |
| ---------- | ------------------------ | -------------------------------- |
| **Flat**   | Arrays of resources      | Simpler for hand-written JSON    |
| **Nested** | Objects keyed by name/ID | Useful for deterministic mapping |

> 💡 Both formats are functionally identical. Choose based on what’s easier for your generator or pipeline.

---

## 📗 Excel Input (`-ExcelFilePath`)

Use the `-ExcelFilePath` parameter to specify an Excel file with one or more worksheets:

- `SecurityGroups`
- `Services`
- `Rules`

> ⚠️ If a required worksheet is missing, an error will be logged - but processing will continue with any remaining valid sheets.

> The worksheet names can be customized via the config file (`excel_sheetnames`).

```jsonc
// Example config override
{
  "excel_sheetnames": {
    "security_groups": "MySecuritySheet",
    "services": "SvcSheet",
    "rules": "FirewallRules"
  }
}
```

### 🔍 Input Behavior Differences
| Feature            | JSON                   | Excel                                  |
| ------------------ | ---------------------- | -------------------------------------- |
| Gateways (Rules)   | `gateway: [...]` field | Separate boolean-style columns         |
| Multi-value fields | Arrays (`[]`)          | Line-break separated (use `Alt+Enter`) |

### 🧾 Worksheet Guidelines
- **Column headers** must be present, but their names **don’t need to match exactly**. Only the **column order** matters.
- Values for fields that support **multiple entries** (e.g. IPs, Ports, Request IDs) should be separated by **line breaks** (`Alt + Enter`).
- The **last column** is reserved for output. If its cell for a row is non-empty, that row will be **skipped entirely**.
- **Extra columns after the output column are allowed**, but ignored.

### 🛡️ SecurityGroups Worksheet

#### Required Columns (in order):
1. **Security Group Name**
2. **IP-Addresses**
3. Hostname
4. Security Group Comment
5. Request ID
6. Output (must be last)

#### Notes:
- The **`IP-Addresses`** and **`Request ID`** fields can have multiple entries - enter each on a new line.
- The **first Request ID** is used as the creation request; others are stored as update references.

#### Example Layout:
| Security Group Name | IP-Addresses                  | Hostname   | Security Group Comment    | Request ID                     | Output |
| ------------------- | ----------------------------- | ---------- | ------------------------- | ------------------------------ | ------ |
| ip\_Cust-Clients    | 10.250.10.2/24                | hstabc0123 | Comment can be any string | SCTASK0001234                  |        |
| ip\_CBA-servers-all | 10.250.10.3<br>10.250.10.1/24 | hstxyz43   | Another comment           | SCTASK0001234<br>SCTASK0001235 |        |


### ⚙️ Services Worksheet

#### Required Columns (in order):
1. **Service Name**
2. **Ports**
3. Service Comment
4. Request ID
5. Output

#### Notes:
- Multiple **Ports** can be specified using line breaks.
- Valid formats: `tcp:80`, `udp:100-200`
- As with other resources, **multiple Request IDs** are supported (first = create, rest = update).

#### Example Layout:
| Service Name | Ports                             | Service Comment | Request ID                     | Output |
| ------------ | --------------------------------- | --------------- | ------------------------------ | ------ |
| x1\_GHI      | udp:100-140                       | Comment here    | SCTASK0001235                  |        |
| x1\_JKL      | udp:100<br>tcp:200-210<br>tcp:220 | Another comment | SCTASK0001236<br>SCTASK0001235 |        |


### 🔥 Rules Worksheet

#### Required Columns (in order):
1. **Index**
2. **NSX-Source**
3. **NSX-Destination**
4. **NSX-Service**
5. NSX-Description
6. Request ID
7. CIS ID
8. T0 Internet
9. T1 Payload
10. Output

#### Notes:

- Gateway selection is determined by columns **`T0 Internet`** and **`T1 Payload`**:
  - If either contains any non-empty value (e.g. `x`), that gateway is selected.
  - If both are filled, the rule is deployed for **both gateways**.
  - If neither is filled, `T1 Payload` is used by default.
- Multi-value fields (`NSX-Source`, `Destination`, `Service`, `Request ID`) use line breaks for separation.
- Rule uniqueness is determined by **CIS ID + Index + Gateway**.

#### Example Layout:

| Index | NSX-Source                              | NSX-Destination | NSX-Service        | NSX-Description           | Request ID                     | CIS ID | T0 Internet | T1 Payload | Output |
| ----- | --------------------------------------- | --------------- | ------------------ | ------------------------- | ------------------------------ | ------ | ----------- | ---------- | ------ |
| 2     | ip\_Cust-Clients                        | any             | any                | A short description       | SCTASK0001245                  | 123456 |             | x          |        |
| 3     | ip\_Cust-Clients<br>ip\_CBA-servers-all | net-ABC-prod    | x1\_GHI<br>x1\_JKL | Another short description | SCTASK0001245<br>SCTASK0001246 | 123456 | x           | x          |        |

---

## 🗂️ NSX-Image

The **NSX-Image** is a structured JSON file automatically maintained by the tool.

It includes all resources ever created or updated with the tool (excluding deletions), along with rich metadata:

- Full configuration of each resource
- Timestamps for creation and last update

It serves several key purposes:

- 📚 **Local documentation** of the current state
- 🔐 **Integrity checks**
  - Used as a fallback when `NsxHostDomain` or NSX-related environment variables are unset
- 🚀 **Auto mode deployments**
  - Used as a fallback when `NsxHostDomain` or NSX-related environment variables are unset
  - May trigger multiple request attempts if the image is outdated, which can increase runtime

This file is referenced implicitly during various operations but is not intended for manual editing.

---

## 🎯 Exit Code Reference

| Code | Meaning                                                                        |
| ---- | ------------------------------------------------------------------------------ |
| 0    | Successfully deployed all specified resources                                  |
| 1    | One or more resources caused parse errors                                      |
| 2    | One or more parsed resources were not deployed successfully                    |
| 3    | Encountered both parse errors and failed deployments                           |
| 4    | Controller was interrupted while processing resources (eg. keyboard interrupt) |
| 5    | Encountered a fatal error                                                      |
