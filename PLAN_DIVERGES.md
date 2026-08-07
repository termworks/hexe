# PLAN.md divergences

This file records deliberate implementation differences from `PLAN.md`. The original plan stays
unchanged so parallel work can compare its assumptions with the implemented protocol.

## Phase 3: DECXCPR response

`PLAN.md` specifies the response to `CSI ? 6 n` as:

```text
CSI ? <row> ; <column> ; 1 R
```

Hexe implements the official xterm form:

```text
CSI ? <row> ; <column> R
```

The xterm control-sequence specification states that DECXCPR assumes the default page, page 1;
it does not include a third page parameter. See `CSI ? Ps n`, `Ps = 6` in
[XTerm Control Sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.pdf).

### Oslo/rush impact

The shell-side capability probe must accept the standard two-coordinate DECXCPR reply. It should
treat the omitted page as page 1 and must not require a third parameter.

## Phase 7: OSC 1337 user variables

Hexe does not add `OSC 1337;SetUserVar`. No current terminal or shell feature consumes those
variables. The existing Oslo integration already passes command status, duration, job count,
language, vi mode, command text, and working directory directly to `hexe shp`, so adding a second
base64 state channel would have no concrete consumer.

### Oslo/rush impact

Continue using the existing `hexe shp` arguments. If a future feature needs state that channel
cannot express, document the consumer before adding `SetUserVar` support.

## Phase 7: device attributes ownership

DA1 and DA2 remain forwarded to the host terminal. Hexe cannot yet replace them with an accurate
description of its own feature set, and the required live compatibility matrix across three host
terminals has not been run. This follows the plan's stop condition rather than inventing a reply.

### Oslo/rush impact

Do not interpret the forwarded DA response as a Hexe capability declaration. Use the dedicated
Kitty keyboard, DECRQM, DSR, and XTVERSION probes for the capabilities Hexe answers locally.
