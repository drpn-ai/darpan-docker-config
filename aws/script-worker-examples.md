# Script worker examples (DAR-BE-169)

Fifteen example scripts for proving the script worker on AWS UAT. Every expected outcome below was produced by the real worker image (`script-worker-poc3`, 0.25 CPU, 384 MiB) on 2026-10-31, not written by hand, and then matched again on UAT through Moqui's `run#TenantScript`.

Where to run them: `https://uat-aws.drpn.ai/apps/darpan/Settings/ScriptWorker` (super-admin), tenant **SCRIPT_POC**. The scripts are also saved in that tenant, so they appear under *Saved scripts* on that screen and on the app's Scripts page. Paste a script and its input into the form, or click **Load**, then **Run**.

How to read a result: `ok` true with a `result`, or `ok` false with an error **kind**. `units` is how much work the script did (budget: 100,000 for EXPRESSION, 2,000,000 for SCRIPT).

| Error kind | Meaning |
|---|---|
| `NOT_ALLOWED` | The script asked for something outside the sandbox (Java classes, methods, `new`, changing the input). Refused before it ran: 0 units. |
| `ACCESS` | It read something it may not see. |
| `SYNTAX` | It does not parse. |
| `UNITS` | It used up its work budget (endless loops end here). |
| `MEMORY` | A text passed 65,536 characters or a list/map passed 10,000 entries. |
| `WORKER` | Moqui could not reach the worker, so the script was not run anywhere. |

## Should succeed

### Backordered units

Adds up ordered minus shipped across order lines, only where something is still owed, and writes a log line.

Profile: `SCRIPT`

```jexl
var short = 0;
for (var line : input.lines) {
  var gap = line.ordered - line.shipped;
  if (gap > 0) { short = short + gap; }
}
d:log('lines checked: ' + size(input.lines));
short
```

Input:

```json
{
  "lines": [
    {
      "sku": "MUG-01",
      "ordered": 5,
      "shipped": 3
    },
    {
      "sku": "TEE-02",
      "ordered": 4,
      "shipped": 4
    },
    {
      "sku": "CAP-03",
      "ordered": 7,
      "shipped": 2
    }
  ]
}
```

Expected: **ok**, result `7`, 27 units, log `lines checked: 3`

### Order total matches its lines

One-line check that the lines add up to the order total, to the cent.

Profile: `EXPRESSION`

```jexl
d:money(d:sum(input.lines, 'amount')) == d:money(input.orderTotal)
```

Input:

```json
{
  "orderTotal": 100,
  "lines": [
    {
      "sku": "MUG-01",
      "amount": 19.99
    },
    {
      "sku": "TEE-02",
      "amount": 5.01
    },
    {
      "sku": "CAP-03",
      "amount": 75
    }
  ]
}
```

Expected: **ok**, result `true`, 14 units

### Mismatch summary

Counts a run's differences by type and returns one sentence a person can read.

Profile: `SCRIPT`

```jexl
var byType = d:groupCount(input.differences, 'type');
'OMS only: ' + byType.ONLY_IN_OMS + ', Shopify only: ' + byType.ONLY_IN_SHOPIFY + ', value differs: ' + byType.VALUE_DIFFERS
```

Input:

```json
{
  "differences": [
    {
      "orderId": "1001",
      "type": "ONLY_IN_OMS"
    },
    {
      "orderId": "1002",
      "type": "ONLY_IN_SHOPIFY"
    },
    {
      "orderId": "1003",
      "type": "VALUE_DIFFERS"
    },
    {
      "orderId": "1004",
      "type": "ONLY_IN_OMS"
    }
  ]
}
```

Expected: **ok**, result `"OMS only: 2, Shopify only: 1, value differs: 1"`, 18 units

### Refund total

Picks the refunds out of a payment list and totals them.

Profile: `SCRIPT`

```jexl
var refunds = d:where(input.payments, 'kind', 'REFUND');
d:log('refunds: ' + size(refunds));
d:money(d:sum(refunds, 'amount'))
```

Input:

```json
{
  "payments": [
    {
      "id": "P1",
      "kind": "CAPTURE",
      "amount": 120.5
    },
    {
      "id": "P2",
      "kind": "REFUND",
      "amount": 20.25
    },
    {
      "id": "P3",
      "kind": "REFUND",
      "amount": 10
    }
  ]
}
```

Expected: **ok**, result `30.25`, 14 units, log `refunds: 2`

### Late shipments

Lists orders that shipped more than 2 days after they were placed.

Profile: `SCRIPT`

```jexl
var late = '';
for (var o : input.orders) {
  if (d:daysBetween(o.orderDate, o.shipDate) > 2) { late = late + o.orderId + ' '; }
}
d:trim(late)
```

Input:

```json
{
  "orders": [
    {
      "orderId": "A-1",
      "orderDate": "2026-10-01",
      "shipDate": "2026-10-02"
    },
    {
      "orderId": "A-2",
      "orderDate": "2026-10-01",
      "shipDate": "2026-10-06"
    },
    {
      "orderId": "A-3",
      "orderDate": "2026-10-03",
      "shipDate": "2026-10-09"
    }
  ]
}
```

Expected: **ok**, result `"A-2 A-3"`, 31 units

### Top SKUs

Orders lines by quantity, largest first, and lists the SKUs.

Profile: `SCRIPT`

```jexl
var top = d:sortBy(input.lines, 'qty', 'desc');
d:join(d:pluck(top, 'sku'), ', ')
```

Input:

```json
{
  "lines": [
    {
      "sku": "MUG-01",
      "qty": 3
    },
    {
      "sku": "TEE-02",
      "qty": 9
    },
    {
      "sku": "CAP-03",
      "qty": 5
    }
  ]
}
```

Expected: **ok**, result `"TEE-02, CAP-03, MUG-01"`, 30 units

## Should be refused or stopped

### Escape attempt: Java Runtime

Tries to reach java.lang.Runtime, the classic way to run system commands from a script.

Profile: `SCRIPT`

```jexl
''.class.forName('java.lang.Runtime')
```

Input:

```json
{}
```

Expected: **refused**, `NOT_ALLOWED`: method call error in '.forName(...)' (0 units)

### Escape attempt: open a file

Tries to create a java.io.File pointing at /etc/passwd.

Profile: `SCRIPT`

```jexl
new('java.io.File', '/etc/passwd')
```

Input:

```json
{}
```

Expected: **refused**, `NOT_ALLOWED`: create instance error in 'new(..., ...)' (0 units)

### Calling a Java method

Calls .size() on a list. Method calls on objects are not part of the language Darpan allows.

Profile: `SCRIPT`

```jexl
input.lines.size()
```

Input:

```json
{
  "lines": [
    1,
    2
  ]
}
```

Expected: **refused**, `NOT_ALLOWED`: method call error in '.'size'(...)' (0 units)

### Changing the input

Tries to overwrite a field of the input. The input is read-only.

Profile: `SCRIPT`

```jexl
input.total = 0; input.total
```

Input:

```json
{
  "total": 5
}
```

Expected: **refused**, `NOT_ALLOWED`: global assign/modify error in 'input...' (0 units)

### Reading something that isn't there

Reads a variable called secret. A script sees only its input and its own variables.

Profile: `EXPRESSION`

```jexl
secret + 1
```

Input:

```json
{}
```

Expected: **refused**, `ACCESS`: Unknown name 'secret': a script reads only input (declare your own with var). (0 units)

### Syntax error

A typo: an assignment with nothing after the equals sign.

Profile: `SCRIPT`

```jexl
var total = ;
total
```

Input:

```json
{}
```

Expected: **refused**, `SYNTAX`: parsing error in ';' (0 units)

### Endless loop

while (true) {} never finishes on its own.

Profile: `SCRIPT`

```jexl
while (true) {}
```

Input:

```json
{}
```

Expected: **refused**, `UNITS`: The script used more than 2000000 units of work. (2000001 units)

### Text that doubles forever

Doubles a piece of text until it would fill memory.

Profile: `SCRIPT`

```jexl
var s = 'xxxxxxxxxx';
while (true) { s = s + s; }
```

Input:

```json
{}
```

Expected: **refused**, `MEMORY`: A text value would grow past 65536 characters. (26 units)

### A map that grows forever

Adds entries to a map without end.

Profile: `SCRIPT`

```jexl
var n = 0; var big = {:};
while (true) { big[n] = n; n = n + 1; }
```

Input:

```json
{}
```

Expected: **refused**, `MEMORY`: A list or map grew past 10000 entries. (30002 units)

## Worker-down check

Run any script above while the worker service is scaled to 0. Expected: **refused**, `WORKER`: The script worker did not answer (ConnectException); the script was not run. (0 units). Moqui never runs it itself.

## Saving (verified on UAT, 2026-10-31)

All 15 were saved through `save#TenantScript` into tenant SCRIPT_POC and then run through `run#TenantScript`; every outcome matched this file.

- **Saved (9)**, run by their saved id: the 6 successes (ids 100000-100005) and the 3 that fail only while running: endless loop (100006), text bomb (100007), map bomb (100008).
- **Refused at save (6)**, with the same reason they give when run as a draft: Java Runtime, `new File`, method call, changing the input, unknown variable, syntax error. `save#TenantScript` checks a script before it stores it, so these can never sit in the database waiting to run.
