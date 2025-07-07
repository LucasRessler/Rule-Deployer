# Rule Deployer
Rule Deployer is a T-Systems in-house tool for faster deployment of NSX Security Groups, Services and Firewall Rules specific to FCI.
The input data is provided via either inline JSON-input or an Excel sheet, parsed, checked, converted to API-calls and deployed.
Unfortunately, the API currently lacks bulk request support, requiring sequential deployment, which may increase the time needed. 


# Usage
<TODO/>

Minimal execution with JSON input:
```powershell
.\rule_deployer -InlineJson '<Json String>' -Action '[auto|create|update|delete]'
```

Minimal execution with Excel input:
```powershell
.\rule_deployer -ExcelFilePath '<Path to the Excel File>' -Tenant '<Tenant to deploy on>' -Action '[auto|create|update|delete]'
```

Additional Parameters:
`VRAHostName`: Overwrites the default VRA target
`RequestID`: Uses the given Request ID as each resource's request id, or adds it to its update id list, if `request_id` is already filled out.
<TODO>I'll add the rest, I just want this in a somewhat clean structure first...</TODO>

# Config
<TODO>I'll write this section, don't worry TuT</TODO>


# Environment Variables
Rule Deployer depends on a few environment variables for various usernames and passwords.
These can either be defined in the environment the script is launched, or in a .env file
in the script's root folder, which will be automatically loaded on execution.

> NOTE: The .env parsing is very basic.
> Everything after the first `=` of a line will be interpreted as the variable's value.
> This also includes quotation marks!

The following environment variables must be set.
```.env
cmdb_user=NEO\{cmdb-username}
cmdb_password={cmdb-password}
catalogdb_user=neo\{catalogdb-username}
catalogdb_password={catalogdb-password}
rmdb_user={rmdb-username}
rmdb_password={rmdb-password}
```

The following environment variables are optional.
However, defining them greatly increases the reliability of integrity checks.
```.env
nsx_user="{nsx-username}"
nsx_password="{nsx-password}"
```


# Input Overview
<TODO/>

## Input Values for Security Groups
- ### Security Group Name
  The name of the Security Group.

  - **JSON Field Name:** `name`
  - **Value Format:** String of lowercase or uppercase letters (a-z), numbers, and these symbols: `-`, `_`, `.`
  - This field is **required**
  - This field can only contain **one value**
  - This field's value should be **unique**


- ### IP-Addresses
  The IP-addresses that constitute the Security Group.

  - **JSON Field Name:** `ip_addresses`
  - **Value Format:** IPv4-address, with or without network part  
    `<ipv4>` | `<ipv4>/<net>`
  - **Examples:** `1.2.3.4`, `1.2.3.4/24`
  - This field is **required** for Create and Update requests
  - This field may contain **multiple values**

- ### Hostname
  Hostnames associated with the Security Group.  
  They will be added to the resource description.

  - **JSON Field Name:** `hostname`
  - **Value Format:** Any string
  - This field is **optional**
  - This field may contain **multiple values**

- ### Security Group Comment
  A comment about or description of the Security Group.  
  It will be added to the resource description.

  - **JSON Field Name:** `comment`
  - **Value Format:** Any string
  - This field is **optional**
  - This field can only contain **one value**

- ### Request ID
  Request IDs associated with the Security Group.  
  They will be added to the resource description.

  - **JSON Field Name:** `request_id`
  - **Value Format:** String of lowercase or uppercase letters (a-z) followed by a string of numbers
  - **Examples:** `SCTASK01234567`, `INC01234567`
  - This field is **optional**
  - This field may contain **multiple values**

- ### Update IDs
<TODO/>


## Input Values for Services
- ### Service Name
  The name of the Service.

  - **JSON Field Name:** `name`
  - **Value Format:** String of lowercase or uppercase letters (a-z), numbers, and these symbols: `-`, `_`, `.`
  - This field is **required**
  - This field can only contain **one value**
  - This field's value should be **unique**

- ### Ports
  The ports and/or port-ranges that constitute the Service.

  - **JSON Field Name:** `ports`
  - **Value Format:** Protocol:Port or Protocol:Port-range  
    `<protocol>:<port>` | `<protocol>:<port-start>-<port-end>`  
    Supported protocols are `tcp` and `udp`  
    For the protocol-part, lowercase and uppercase letters both work  
    `icmp` is not supported; Please use default ICMP Services (i.e. 'ICMP ALL' or 'ICMP Echo Request'), instead of creating a custom one!
  - **Examples:** `tcp:100`, `udp:120-130`
  - This field is **required** for Create and Update requests
  - This field may contain **multiple values**

- ### Service Comment
  A comment about or description of the Service.  
  It will be added to the resource description.

  - **JSON Field Name:** `comment`
  - **Value Format:** Any string
  - This field is **optional**
  - This field can only contain **one value**

- ### Request ID
  Request IDs associated with the Service.  
  They will be added to the resource description.

  - **JSON Field Name:** `request_id`
  - **Value Format:** String of lowercase or uppercase letters (a-z) followed by a string of numbers
  - **Examples:** `SCTASK01234567`, `INC01234567`
  - This field is **optional**
  - This field may contain **multiple values**
    The first value will be interpreted as the initial Request ID  
    Any other values will be interpreted as update Request IDs

- ### Update IDs
<TODO/>


## Input Values for Rules
- ### CIS ID
  ID of the CIS Request associated with the Rule.
  It will be part of the resource name.

  - **JSON Field Name:** `cis_id`
  - **Value Format:** String of 5 to 8 numbers
  - **Example:** `01234`, `12345678`
  - This field is **required**

- ### Index
  Used to differentiate rules with the same CIS ID.  
  It will be part of the resource name.

  - **JSON Field Name:** `index`
  - **Value Format:** Any number
  - This field is **required**
  - This field can only contain **one value**

- ### NSX-Source
  Names of Security Groups to use as sources for the Rule.

  - **JSON Field Name:** `sources`
  - **Value Format:** String of lowercase or uppercase letters (a-z), numbers, and these symbols: `-`, `_`, `.`
  - **Special Value:** `any` - apply the Rule for any source
  - This field is **required** for Create and Update requests
  - This field may contain **multiple values**

- ### NSX-Destination
  Names of Security Groups to use as destinations for the Rule.

  - **JSON Field Name:** `destinations`
  - **Value Format:** String of lowercase or uppercase letters (a-z), numbers, and these symbols: `-`, `_`, `.`
  - **Special Value:** `any` - apply the Rule for any destination
  - This field is **required** for Create and Update requests
  - This field may contain **multiple values**

- ### NSX-Services
  Names of Services to apply the Rule to.  
  Can refer to either previously defined Services within the same tenant, or to default Services.

  - **JSON Field Name:** `services`
  - **Value Format:** String of lowercase or uppercase letters (a-z), numbers, and these symbols: `-`, `_`, `.`, ` `
  - **Special Value:** `any` - apply the Rule for any Services
  - This field is **required** for Create and Update requests
  - This field may contain **multiple values**

- ### NSX-Description
  A comment about or description of the Rule.  
  It will be added to the resource description.

  - **JSON Field Name:** `comment`
  - **Value Format:** Any string
  - This field is **optional**
  - This field can only contain **one value**

- ### Request ID
  Request IDs associated with the Rule.  
  They will be added to the resource description.  
  The initial Request ID will be part of the resource name.

  - **JSON Field Name:** `request_id`
  - **Value Format:** String of lowercase or uppercase letters (a-z) followed by a string of numbers
  - **Examples:** `SCTASK01234567`, `INC01234567`
  - This field is **optional**
  - This field may contain **multiple values**
    The first value will be interpreted as the initial Request ID  
    Any other values will be interpreted as update Request IDs

- ### T0 Internet, T1 Payload
  <TODO>AHHH, this doesn't even make sense now that it's not in the Excel section</TODO>

  The Gateways to use.  
  T1 Payload is chosen by default.
  If any of these fields is filled out, only the selected Gateway will be used.
  Selecting both Gateways will result in one deployment for each.

  - **Value Format:** Empty or 'x'  
    The format of these fields are not checked, any non-empty string is treated as a boolean `true`.  
    However, it is advised to use a consistent format, like a simple cross `x`.
  - These fields are **optional**  
    If neither is specified, `T1 Payload` is set to `true` by default.
  - These fields can only contain **one value**

### Notes:
- While neither the `Gateway`, `CIS ID`, nor `Index` fields have to be unique,
  there cannot be multiple Rules within the same Tenant that use the exact same combination
  of these values, as they are used to uniquely identify a Rule.


# Input with `-InlineJson`
Rule Deployer accepts JSON-formatted input via the `-InlineJson` parameter.
This input defines the resources to be deployed, grouped by tenant.

## JSON Structure Overview
At the top level, the JSON should define one or more **tenant names** as keys.
Each tenant maps to an object that may contain one or more of the following resource group fields:
- `security_groups`
- `services`
- `rules`

> **Note:** If you are using the `-Tenant` parameter, you must not include tenants within the JSON.
> In that case, the JSON is assumed to directly define the resource groups, and Rule Deployer will
> automatically wrap them with the tenant specified via `-Tenant`.

## Supported JSON Formats
Rule Deployer supports two main formats for JSON input:

### **1. Flat Format**
In the flat format, each resource group (`security_groups`, `services`, `rules`) contains an **array of objects**.
Each object represents a resource.

#### Example (Flat Format)
```json
{
  "t001": {
    "security_groups": [
      {
        "name": "secgroup_name1",
        "ip_addresses": ["10.0.0.1", "10.0.0.20/24"],
        "hostname": ["hostname1"],
        "comment": "description...",
        "request_id": "SCTASK01234567",
        "update_requests": ["SCTASK01234568"]
      }
    ],
    "services": [
      {
        "name": "service_name1",
        "ports": ["tcp:123", "tcp:124-126", "udp:321"],
        "comment": "description...",
        "request_id": "SCTASK01234567",
        "update_requests": ["SCTASK01234568"]
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
        "comment": "description...",
        "request_id": "SCTASK01234567",
        "update_requests": ["SCTASK01234568"]
      }
    ]
  }
}
```

### **2. Nested Format**
The nested format uses **objects instead of arrays**, where each key corresponds to the resource's name (or ID) and maps to its properties.
- `security_groups` and `services` use **resource names as keys**.
- `rules` are organized first by **gateway**, then by **CIS ID**, then by **index**.

#### Example (Nested Format)
```json
{
  "t001": {
    "security_groups": {
      "secgroup_name1": {
        "ip_addresses": ["10.0.0.1", "10.0.0.20/24"],
        "hostname": ["hostname1"],
        "comment": "description...",
        "request_id": "SCTASK01234567",
        "update_requests": ["SCTASK01234568"]
      }
    },
    "services": {
      "service_name1": {
        "ports": ["tcp:123", "tcp:124-126", "udp:321"],
        "comment": "description...",
        "request_id": "SCTASK01234567",
        "update_requests": ["SCTASK01234568"]
      }
    },
    "rules": {
      "T0 Internet": {
        "123456": {
          "1": {
            "sources": ["secgroup_name1"],
            "destinations": ["secgroup_name1"],
            "services": ["service_name1"],
            "comment": "description...",
            "request_id": "SCTASK01234567",
            "update_requests": ["SCTASK01234568"]
          }
        }
      }
    }
  }
}
```

### Notes
- Rule names are generated automatically in the format: `IDC<cis_id>_<index>`.
- For `rules`, if no `gateway` is provided, the default is `"T1 Payload"`.
- Both input formats are functionally equivalent.
  Choose the one that best fits your workflow or data source.


# Input with `ExcelFilePath`
Input can alternatively be provided with an Excel file with the `ExcelFilePath` parameter.
This file should contain 3 worksheets for the 3 different resource types.
- SecurityGroups
- Services
- Rules

If one of these is not found, Rule Deployer will display an error message,
but continue with the other worksheets without issue.

The names of the Worksheets can be configured with the `excel_sheetnames` field in the config file.
```jsonc
{
    "excel_sheetnames": {
        "security_groups": "My-SecurityGroups-Worksheet",
        "services": "My-Services-Worksheet",
        "rules": "My-Rules-Worksheet"
    },
    // [...]
}
```

Each worksheet's final column is reserved for Rule Deployer Output.
When this field of a row is filled out, the script will ignore it entirely.
Make sure that the Output field is empty for all of and only those rows that Rule Deployer should process.

In the following sections, each of the worksheets will be described in detail.  
The headers for each worksheet are required, but the column titles don't have to follow the
naming scheme described here. The columns only need to be in the correct order.

## The SecurityGroups Worksheet
<TODO/>

The `IP-Addresses` and `Request ID` fields can each contain **multiple values**,
separated by linebreaks (Alt + Enter) within the cell.

The first value of the `Request ID` field will be interpreted as the initial Request ID.
Any other values will be interpreted as update Request IDs.

For details on the individual values, see [above](#InputValuesforSecurityGroups).

**Layout and Examples:**
| Security Group Name | IP-Addresses                  | Hostname   | Security Group Comment    | Request ID                     | Output |
| ------------------- | ----------------------------- | ---------- | ------------------------- | ------------------------------ | ------ |
| net-ABC-prod        | 10.250.10.1                   |            |                           |                                |        | 
| ip_Cust-Clients     | 10.250.10.2/24                | hstabc0123 | Comment can be any string | SCTASK0001234                  |        |
| ip_CBA-servers-all  | 10.250.10.3<br>10.250.10.1/24 | hstxyz43   | Comment can be any string | SCTASK0001234<br>SCTASK0001235 |        |


## The Services Worksheet
<TODO/>

The `Ports` and `Request ID` fields can each contain **multiple values**,
separated by linebreaks (Alt + Enter) within the cell.

The first value of the `Request ID` field will be interpreted as the initial Request ID.
Any other values will be interpreted as update Request IDs.

For details on the individual values, see [above](#InputValuesforServices).

**Layout and Examples:**
| Service Name | Ports                             | Service Comment           | Request ID                     | Output |
| ------------ | --------------------------------- | ------------------------- | ------------------------------ | ------ |
| x-DEF        | tcp:50                            |                           |                                |        | 
| x1_GHI       | upd:100-140                       | Comment can be any string | SCTASK0001235                  |        | 
| x1_JKL       | upd:100<br>tcp:200-210<br>tcp:220 | Comment can be any string | SCTASK0001236<br>SCTASK0001235 |        |


## The Rules Worksheet
<TODO/>

The `NSX-Source`, `NSX-Destination`, `NSX-Service` and `Request ID` fields can each contain **multiple values**,
separated by linebreaks (Alt + Enter) within the cell.

The first value of the `Request ID` field will be interpreted as the initial Request ID.
Any other values will be interpreted as update Request IDs.

For details on the individual values, see [above](#InputValuesforRules).

**Layout and Examples:**
| Index              | NSX-Source                            | NSX-Destination   | NSX-Service      | NSX-Description                | Request ID                     | CIS ID | T0 Internet        | T1 Payload         | Output |
| ------------------ | ------------------------------------- | ----------------- | ---------------- | ------------------------------ | ------------------------------ | ------ | ------------------ | ------------------ | ------ |
| <center>1</center> | net-ABC-prod                          | p_Cust-Clients    | x-DEF            |                                | SKTASK0001245                  | 123456 |                    |                    |        | 
| <center>2</center> | ip_Cust-Clients                       | any               | any              | Should be: A short description | SKTASK0001245                  | 123456 |                    | <center>x</center> |        | 
| <center>3</center> | ip_Cust-Clients<br>ip_CBA-servers-all | net-ABC-prod      | x1_GHI<br>x1_JKL | Should be: A short description | SCTASK0001245<br>SCTASK0001246 | 123456 | <center>x</center> | <center>x</center> |        |
