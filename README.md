# Rule Deployer
**Rule Deployer** is an internal T-Systems tool that streamlines the deployment of NSX Security Groups, Services, and Firewall Rules, specifically for FCI environments.

It supports both JSON-based and Excel-based input formats, and automates conversion into the necessary API calls for deployment.

> **Note**: Due to API limitations, bulk operations are not supported. All resources are deployed sequentially, which may increase execution time.

## 📦 Quick Start
### Minimal execution with JSON input:
```powershell
.\rule_deployer -InlineJson '<Json String>' -Action '[auto|create|update|delete]'
```

### Minimal execution with Excel input:
```powershell
.\rule_deployer -ExcelFilePath '<Path to Excel>' -Tenant '<Tenant>' -Action '[auto|create|update|delete]'
```

### Optional Parameters:
- `-VRAHostName`: Override default VRA host
- `-RequestID`: Inject a request ID to be used for all resources (or added as an update ID)


## ⚙️ Configuration
### Environment Variables
These can be set either in your shell environment or in a `.env` file located in the root folder.
The `.env` file will be auto-loaded at runtime.

> ⚠️ Parsing is simplistic: everything after the first `=` is taken as the value (including quotes).

#### **Required Variables**
```env
cmdb_user=NEO\{cmdb-username}
cmdb_password={cmdb-password}
catalogdb_user=neo\{catalogdb-username}
catalogdb_password={catalogdb-password}
rmdb_user={rmdb-username}
rmdb_password={rmdb-password}
```

#### **Optional Variables**
```env
nsx_user="{nsx-username}"
nsx_password="{nsx-password}"
```

Providing these improves reliability of certain integrity checks.


## 🧪 Usage
Coming soon...

## 📥 Input Overview
Rule Deployer supports two input formats:
- **JSON input** via the `-InlineJson` parameter.
- **Excel input** via the `-ExcelFilePath` parameter.

Despite different formats, the same resource types and value structures apply:
- Security Groups
- Services
- Firewall Rules

Some fields behave differently depending on input format (notably Gateway selection for Rules). These differences are noted where applicable.

## 🧾 Input Schema Reference
### 🔐 Security Groups
| Field            | Required              | JSON Field        | Format                              | Notes                             |
| ---------------- | --------------------- | ----------------- | ----------------------------------- | --------------------------------- |
| **IP-Addresses** | ✅ (for Create/Update) | `ip_addresses`    | `IPv4` or `IPv4/CIDR`               | Multiple allowed                  |
| **Hostname**     | ❌                     | `hostname`        | Any string                          | Multiple allowed                  |
| **Comment**      | ❌                     | `comment`         | Any string                          | One only                          |
| **Request ID**   | ❌                     | `request_id`      | `SCTASK1234567`, `INC1234567`, etc. | First = create ID, rest = updates |
| **Update IDs**   | ❌                     | `update_requests` | Same format as above                | Alternative field for updates     |

### ⚙️ Services
| Field          | Required              | JSON Field        | Format                                            | Notes                                     |
| -------------- | --------------------- | ----------------- | ------------------------------------------------- | ----------------------------------------- |
| **Ports**      | ✅ (for Create/Update) | `ports`           | `<protocol>:<port>` or `<protocol>:<start>-<end>` | Protocols: `tcp`, `udp`; multiple allowed |
| **Comment**    | ❌                     | `comment`         | Any string                                        | One only                                  |
| **Request ID** | ❌                     | `request_id`      | Same as Security Groups                           |                                           |
| **Update IDs** | ❌                     | `update_requests` | Same format                                       |                                           |

> 🔸 ICMP is not supported. Use predefined NSX ICMP Services (e.g. "ICMP ALL", "ICMP Echo Request").


### 🔥 Firewall Rules
| Field            | Required              | JSON Field        | Format                                          | Notes                              |
| ---------------- | --------------------- | ----------------- | ----------------------------------------------- | ---------------------------------- |
| **Index**        | ✅                     | `index`           | Numeric                                         | Differentiates rules per CIS ID    |
| **Sources**      | ✅ (for Create/Update) | `sources`         | Alphanumeric / `any`                            | Multiple allowed                   |
| **Destinations** | ✅ (for Create/Update) | `destinations`    | Same as Sources                                 |                                    |
| **Services**     | ✅ (for Create/Update) | `services`        | Same as Sources                                 | Refers to defined/default Services |
| **Comment**      | ❌                     | `comment`         | Any string                                      | One only                           |
| **Request ID**   | ❌                     | `request_id`      | Same as other types                             | First = initial, others = updates  |
| **Update IDs**   | ❌                     | `update_requests` | Same format                                     |                                    |
| **Gateway**      | ❌                     | `gateway`         | One or both of: `"T0 Internet"`, `"T1 Payload"` | See notes below                    |

> ⚠️ In Excel input, **Gateways** are selected using **two separate boolean-style fields**:
> `T0 Internet` and `T1 Payload`. If both are checked (non-empty), Rule is deployed for both.

> 🚪 If no **Gateway** is specified, `T1 Payload` is chosen by default.

> 🧠 A rule’s identity is defined by its **Tenant + CIS ID + Index + Gateway**. Multiple rules may share CIS ID and Index as long as one of these differs.


## 🧾 Supported Input Formats
Rule Deployer supports two main ways of providing input:

- **🔵 JSON (via `-InlineJson`)**
- **🟢 Excel File (via `-ExcelFilePath`)**

The tool will process either format into internal representations of:

- `security_groups`
- `services`
- `rules`

## 🔵 JSON Input (`-InlineJson`)
Use the `-InlineJson` parameter to pass a JSON string defining your resources. The JSON input supports two structurally equivalent styles: **flat** and **nested**.

> 📌 You can define multiple tenants within a single JSON string.
> Alternatively, if you're using the `-Tenant` parameter, omit tenant names and provide top-level resource keys instead.

### 🧱 JSON Structure Overview
```jsonc
{
  "tenant_name": {
    "security_groups": ["..."],
    "services": ["..."],
    "rules": ["..."]
  }
  // ...
}
```

If `-Tenant` is used, structure should look like:

```json
{
  "security_groups": ["..."],
  "services": ["..."],
  "rules": ["..."]
}
```


### 🔹 Flat Format
Each resource group is an **array of objects**, one per resource.

```json
{
  "t001": {
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

```json
{
  "t001": {
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
      "T0 Internet": {
        "123456": {
          "1": {
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

> ✨ Both formats are functionally identical. Choose based on what’s easier for your generator or pipeline.

---

## 🟢 Excel Input (`-ExcelFilePath`)
Use the `-ExcelFilePath` parameter to specify an Excel file with one or more worksheets:

- `SecurityGroups`
- `Services`
- `Rules`

> The worksheet names can be customized via the config file (`excel_sheetnames`).

> ⚠️ If a required worksheet is missing, an error will be logged - but processing will continue with any remaining valid sheets.

### ✅ Worksheet Requirements
- Column order matters - **header names don’t**.
- Last column in each sheet is **reserved for output**.
- Rows with non-empty output field are **skipped**.

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
| Feature            | JSON                   | Excel                            |
| ------------------ | ---------------------- | -------------------------------- |
| Gateways (Rules)   | `gateway: [...]` field | Separate boolean-style columns   |
| Multi-value fields | Arrays (`[]`)          | Line-break separated (Alt+Enter) |

### 🧾 Worksheet Guidelines
- **Column headers** must be present, but their names **don’t need to match exactly**. Only the **column order** matters.
- **Extra columns are allowed**, but ignored (unless one is the output column).
- The **last column** is reserved for output. If its cell for a row is non-empty, that row will be **skipped entirely**.
- Values for fields that support **multiple entries** (e.g. IPs, Ports, Request IDs) should be separated by **line breaks** (`Alt + Enter`).

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
8. **T0 Internet**
9. **T1 Payload**
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
