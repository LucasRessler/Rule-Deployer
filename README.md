# Arca-Ignis
Arca-Ignis is a T-Systems in-house tool for faster deployment of NSX Security Groups, Services and Firewall Rules specific to FCI.
The input data is provided via a centraliced Excel sheet, parsed, converted to API-calls and deployed.
Unfortunately, the API currently lacks bulk request support, requiring sequential deployment, which may increase the time needed.

# Input: The Excel file
The Arca-Ignis input file can be found at \<insert\>.
It is structured into the following sheets:
- **Servergroups** (Security Groups)
- **Portgroups**   (Services)
- **Rules**        (Perimeter FW Rules)

## General
Most fields must conform to a specified format, detailed in the field descriptions below.  
Some fields are optional, as noted explicitly in their descriptions.  
Some fields can contain multiple values, as noted explicitly in their descriptions.
Sseparate values by using multiple lines in the same cell.
In Excel, this is achieved by pressing `Alt + Enter` while editing a cell.

### Output
Each sheet's last column is reserved for Arca-Ignis output.  
> **IMPORTANT:** Arca-Ignis only processes rows with an empty output cell

**Possible output states:**
- **Parse Error**  
  `Missing Group Name`, `Invalid IP-Address`, `Duplicate NSX-Index`, ...  
  Indicates the input doesn't meet format specifications.
- **Deploy Error**  
  `Deploy Error`  
  The server connection failed, or the server rejected the API call.
  In such cases, the issue could stem from the parsing or conversion logic;
  please report any problematic input!
- **Action Successful**  
  `Created Successfully`, `Updated Successfully`, `Deleted Successfully`  
  Indicates the action completed successfully for the provided data.
- **Action(s) Failed**  
  `Create Failed`, `Create/Update Failed`, `Delete Failed`, ...  
  Indicates all queued actions failed for the provided data.

#### Failed Actions
If you encounter a failed action, here are some possible reasons:
- **Delete Failed**
  - The resource might not exist.
  - The security group or service might still be referenced by a Firewall rule.
- **Update Failed**
  - The resource might not exist.
- **Create Failed**
  - The resource might already exist.
  - The Firewall rule might reference security groups or services that don't exist yet.

If none of these are the case, double-check your data against the format specifications.
This should generally be caught by the parsing logic, but I am not immune to creating bugs,
please report the specific input in this case!

When dealing with Firewall rules, the API also seems to occasionally run into deployment collisions,
which are unfortunately beyond the tool's control. This should be reasonably rare, but the deployment will have to be
reattempted, either using Arca-Ignis (clear the output cell so Arca-Ignis will process the data), or manually.

#### Multiple Outputs
It is possible for a Firewall rule to be deployed on two separate gateways and to result in two different output states.
In this case, the output messages will be comma separated in the order that the gateways appear in the Excel sheet.  
For example: `Updated Successfully, Create/Update Failed`

## Servergroups
**NSX-Resource-name**: _Security Groups_

**Layout and Examples:**
| Group Name | IP-Address | Hostname | Comment | NSX-Servicerequest | Output |
| ---------- | ---------- | -------- | ------- | ------------------ | ------ |
|net-ABC-prod|10.250.10.1|||||
|ip_Cust-Clients|10.250.10.2/24|hstabc0123|Comment can be any string|SCTASK0001234|
|ip_CBA-servers-all|10.250.10.3<br>10.250.10.1/24|hstxyz43|Comment can be any string|SCTASK0001234<br>SCTASK0001235|

- ### Group Name
  - **Value Format:** String of lowercase or uppercase letters (a-z), numbers, and symbols `-`, `_`  
  - This field is **required**  
  - This field can only contain **one value**

  The name of the resource.

- ### IP-Address
  - **Value Format:** IPv4-address, with or without network part  
    `<ipv4>` | `<ipv4>/<net>`  
  - **Examples:** `1.2.3.4`, `1.2.3.4/24`
  - This field is **required**
  - This field can contain **multiple values**

  The group of ip-addresses.

- ### Hostname
  - **Value Format:** Any string
  - This field is **optional**
  - This field can only contain **one value**

  The hostname associated with the security group.
  It will be added to the resource description.

- ### Comment
  - **Value Format:** Any string
  - This field is **optional**
  - This field can only contain **one value**

  A comment or description of the security group.
  It will be added to the resource description.

- ### NSX-Servicerequest
  - **Value Format:** String of letters (a-z) followed by a string of numbers  
    Example: `SCTASK0000000`
  - This field is **optional**
  - This field can contain **multiple values**

  Servicerequest IDs associated with the security group.
  They will be added to the resource description.

## Portgroups
**NSX-Resource-name**: _Services_

**Layout and Examples:**
| Group Name | Port | Comment | NSX-Servicerequest | Output |
| ---------- | ---- | ------- | ------------------ | ------ |
|x-DEF|tcp:50||||
|x1_GHI|upd:100-140|Comment can be any string|SCTASK0001235||
|x1_JKL|upd:100<br>tcp:200-210<br>tcp:220|Comment can be any string|SCTASK0001236<br>SCTASK0001235||

- ### Group Name
  - **Value Format:** String of lowercase or uppercase letters (a-z), numbers, and these symbols: `-`, `_`  
  - This field is **required**
  - This field can only contain **one value**

  The name of the resource.

- ### Port
  - **Value Format:** Protocol:Port or Protocol:Port-range pair  
    `<protocol>:<port>` | `<protocol>:<port-start>-<port-end>`  
    Supported protocols are `tcp` and `udp`  
    `icmp` is not supported, please use default ICMP services (i.e. 'ICMP ALL' or 'ICMP Echo Request'), instead of creating a custom one!
  - **Examples:** `tcp:100`, `udp:120-130`
  - This field is **required**
  - This field can contain **multiple values**

  The ports / port-ranges of the service.

- ### Comment
- **Value Format:** Any string
  - This field is **optional**
  - This field can only contain **one value**

  A comment or description of the service.
  It will be added to the resource description.

- ### NSX-Servicerequest
  - **Value Format:** String of letters (a-z) followed by a string of numbers  
    Example: `SCTASK0000000`
  - This field is **optional**
  - This field can contain **multiple values**

  Servicerequest IDs associated with the service.
  They will be added to the resource description.

## Rules
**NSX-Resource-name**: _Perimeter FW Rules_

**Layout and Examples:**
| NSX-Index | NSX-Source | NSX-Destination | NSX-Ports | NSX-Description | NSX-Servicerequest | NSX-Customer FW | T0 Internet | T1 Payload | Output |
| --------- | ---------- | --------------- | --------- | --------------- | ------------------ | --------------- | ----------- | ---------- | ------ |
|<center>1</center>|net-ABC-prod|p_Cust-Clients|x-DEF||SKTASK0001245|||||
|<center>2</center>|ip_Cust-Clients|any|any|Should be: A short description|SKTASK0001245|NWS-Part:ID0123||<center>x</center>||
|<center>3</center>|ip_Cust-Clients<br>ip_CBA-servers-all|net-ABC-prod|x1_GHI<br>x1_JKL|Should be: A short description|SCTASK0001245<br>SCTASK0001246|NWS-Part:ID0123|<center>x</center>|<center>x</center>||

- ### NSX-Index
  - **Value Format:** Any number
  - This field is **required**
  - This field can only contain **one value**
  - This field's values should be **unique**

  A cardinal count of the resource.
  It will be added to the resource name.

- ### NSX-Source
  - **Value Format:** String of lowercase or uppercase letters (a-z), numbers, and symbols `-`, `_`  
  - **Special Value:** `any` - apply the rule for any source
  - This field is **required**
  - This field can contain **multiple values**

  Names of server/security groups to use as sources for the rule.

- ### NSX-Destination
  - **Value Format:** String of lowercase or uppercase letters (a-z), numbers, and symbols `-`, `_`  
  - **Special Value:** `any` - apply the rule for any destination
  - This field is **required**
  - This field can contain **multiple values**

  Names of server/security groups to use as destinations for the rule.

- ### NSX-Ports
  - **Value Format:** String of lowercase or uppercase letters (a-z), numbers, and symbols `-`, `_`  
  - **Special Value:** `any` - apply the rule for any ports/services
  - This field is **required**
  - This field can contain **multiple values**

  Names of port groups / services to apply the rule to.

- ### NSX-Description
  - **Value Format:** Any string
  - This field is **optional**
  - This field can only contain **one value**

  Ideally a short description of the rule.
  It will be added to the resource comment.
  It will be added to the resource name, in a sanitized and potentially truncated format.

- ### NSX-Servicerequest
  - **Value Format:** String of letters (a-z) followed by a string of numbers  
    Example: `SCTASK0000000`
  - This field is **required**
  - This field can contain **multiple values**

  Servicerequest IDs associated with the rule.
  They will be added to the resource name.

- ### NSX-Customer FW
  - **Value Format:** Any string
  - This field is **optional**
  - This field can only contain **one value**

- ### T0-Internet and T1-Payload
  - **Value Format:** Empty or 'x'  
    The format of these fields are not checked, any non-empty string is treated as a boolean `true`.  
    However, it is advised to use a consistent format, like a simple cross `x`.
  - These fields are **optional**  
    If neither is specified, `T1-Payload` is set to `true` by default.
  - These fields can only contain **one value**

  The gateway(s) to use.
  T1 Payload is chosen by default, if any of these fields is filled out,
  only the corresponding gateways will be used.
  Selecting both gateways will result in one deployment for each.
