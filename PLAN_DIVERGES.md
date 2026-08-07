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
