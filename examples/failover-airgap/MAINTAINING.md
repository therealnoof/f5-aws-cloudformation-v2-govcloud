# Maintaining `examples/failover-airgap/`

This directory is a **variant** of `examples/failover/`, not an independent solution.
It exists so that the air-gap path (no Elastic IPs, route-based VIP failover) can be
built and validated without touching the working EIP-based path. The price of that is
duplication, and this file is what keeps the two from drifting.

## Validation record

| | |
|---|---|
| **Validated** | 2026-09-08, `us-gov-east-1` |
| **Build** | 3-NIC PAYG, BIG-IP 17.5.1.6-0.0.25, DO 1.47.0, AS3 3.56.0, CFE 2.4.0 |
| **Result** | Deployed end to end; VIP failover verified in **both** directions |
| **Convergence** | 6-10 s each way (in-VPC client, 0.5 s poll, last-good to first-good; runs: 9.58 s / ~6 s / 9.58 s) |
| **Defects found and fixed** | (1) Masked next-hop address broke failover in one direction - see "Rules that are easy to break" below. (2) `cfeS3Bucket` was never passed to `BigIpInstance02`, so its CFE could not reach the state store during onboarding - an upstream bug, also fixed in `examples/failover/failover.yaml`. |

Re-run the [validation checklist](AIRGAP-GUIDE.md#6-validating-the-deployment) and both
failover directions after any change to the CFE declaration, the network module's route
table tagging, or the `externalSelfIp` / `peerExternalSelfIp` instance tags.

## What is shared, what is forked

| Component | Status | Notes |
|---|---|---|
| `modules/network/network.yaml` | **Shared** | Gains two optional parameters, both default-off: `routeTableFailoverTag` (tags every route table `f5_cloud_failover_label=<value>`; this template passes `cfeTag`) and `provisionSsmEndpoints` (adds the `ssm`, `ssmmessages`, `ec2messages` interface endpoints). The endpoint security group's condition widened to "S3 endpoints **or** SSM endpoints". With the defaults the module behaves exactly as before. |
| `modules/access/access.yaml` | **Shared, unchanged** | `solutionType: failover` selects `BigIpHighAvailabilityAccessRole`, which already grants `ec2:ReplaceRoute`, `ec2:CreateRoute` and `ec2:DescribeRouteTables`. The write actions are conditioned on the route table carrying `f5_cloud_failover_label` = `cfeTag`, which is why the network tag above is mandatory. |
| `modules/dag/dag.yaml` | **Shared, unchanged** | Called with `numberPublicExternalIpAddresses=0` and `numberPublicMgmtIpAddresses=0`, which creates no EIP resources at all. |
| `modules/bigip-standalone/bigip-standalone.yaml` | **Shared** | Gains four optional parameters (`disableSourceDestCheck`, `externalVipAddress`, `externalVipCidr`, `bigIpPeerExternalSelfIp`), four instance tags carrying values to runtime-init (`externalVipAddress`, `externalVipCidr`, `peerExternalSelfIp`, and `externalSelfIp` - the last exposing the already-existing bare `externalSelfIp` parameter), and one output (`bigIpExternalInterfaceId`). All default to the previous behaviour. |
| `modules/bastion/bastion.yaml` | **Shared, unchanged** | Fallback only (`provisionBastion`, default `false`). |
| `modules/ssm-jump/ssm-jump.yaml` | **New** | Private Session Manager jump host: IAM role with `AmazonSSMManagedInstanceCore`, egress-only security group, IMDSv2-only launch template, Amazon Linux 2023 via the SSM public AMI parameter. Only this solution uses it so far; nothing about it is air-gap specific, so `examples/failover` could adopt it later. |
| `modules/function`, `modules/application` | **Shared, unchanged** | |
| `failover-airgap.yaml` | **Forked** from `failover/failover.yaml` | See "Parent template differences" below. |
| `bigip-configurations/runtime-init-conf-3nic-payg-instance0{1,2}-airgap.yaml` | **Forked** from `failover/bigip-configurations/runtime-init-conf-3nic-payg-instance0{1,2}-with-app.yaml` | See "Runtime-init differences" below. |

Only the 3-NIC PAYG pair is covered, matching the GovCloud scope of `examples/failover`.

## Parent template differences

Everything not listed here is identical to `failover/failover.yaml` and **should be kept
identical**. Check with:

```bash
diff examples/failover/failover.yaml examples/failover-airgap/failover-airgap.yaml
```

- **Removed parameters:** `provisionPublicIpMgmt`, `provisionPublicIpVip`,
  `provisionPublicIpExternalSelf`, `provisionExternalVip`, `provisionS3Endpoint`,
  `bigIpExternalVip01`, `bigIpExternalVip02`, `cfeVipTag`. Their values are fixed: no
  public IPs anywhere, no secondary private IPs, VPC endpoints always on.
- **Added parameters:** `externalVipAddress`, `externalVipCidr`, `provisionSsmAccess`,
  `provisionBastion` (default `false` here), `ssmJumpInstanceType`, `ssmJumpCustomImageId`.
- **Instances:** `disableSourceDestCheck='true'`, the three VIP/peer parameters, all EIP
  allocation IDs `''`, `numExternalPublicIpAddresses=0`, `numSecondaryPrivateIpAddresses=0`,
  default runtime-init config URLs point at this directory.
- **DAG:** both public-address counts `0`, `cfeVipTag=''`.
- **Network:** `setPublicSubnet1='false'`, `provisionS3Endpoint='true'`,
  `provisionSsmEndpoints` from `provisionSsmAccess`, `routeTableFailoverTag=cfeTag`.
- **New resources:** `SsmJump` nested stack; `VipRoutePublic`, `VipRoutePrivateA`,
  `VipRoutePrivateB` - `AWS::EC2::Route` entries for `externalVipCidr` targeting instance
  A's external ENI.
- **Outputs:** public-IP outputs removed; `vipAddress`, `vipRouteCidr`, `vipRouteTableIds`,
  `bigIpExternalInterfaceId01/02`, `ssmJumpInstanceId`, `ssmPortForwardBigIp01/02` added.

## Runtime-init differences

Each config is the corresponding `-with-app.yaml` file plus:

1. `failoverRoutes` in the CFE declaration (`routeGroupDefinitions`, discovered by
   `f5_cloud_failover_label`, `scopingAddressRanges` = `externalVipCidr`, static next hops =
   both external Self IPs), and `failoverAddresses` set to `enabled: false` - there are no
   EIPs and no secondary private IPs here, so address failover has nothing to relocate and
   only adds empty-result noise to `restnoded.log`. This is the one CFE difference that
   inverts the source file rather than adding to it.
2. One AS3 `Service_Address` on the alien VIP in the default (floating) traffic group,
   instead of two per-AZ addresses with `trafficGroup: none`. Two services (HTTP, HTTPS)
   instead of four.
3. Four tag-sourced `runtime_parameters`: `EXTERNAL_VIP_ADDRESS`, `EXTERNAL_VIP_CIDR`,
   `OWN_SELF_IP_EXTERNAL`, `PEER_SELF_IP_EXTERNAL`.
4. A `Demo_Responder` iRule in `Shared`, attached to both services. It only acts when the
   pool has no active members. Nothing about it is air-gap specific; `examples/failover`
   could adopt it, in which case keep the two copies identical.

**Everything else must be mirrored** when the source files change: extension versions and
hashes, the DO declaration, the WAF policy URL, and the base64 `cluster-heal.sh` blob in
`pre_onboard_enabled`. That blob is the most likely thing to drift silently - after
editing `cluster-heal.sh`, regenerate it in **both** directories.

## Rules that are easy to break

- **The VIP routes drift by design.** CFE calls `ec2:ReplaceRoute` on failover, so the
  live target of `VipRoute*` will not match the template after the first failover. Never
  change a property of those resources in a stack update; CloudFormation would re-point
  the route at instance A whether or not it is active. Change the prefix by redeploying.
- **`externalVipCidr` must equal the route prefix and the CFE scoping range.** CFE's
  prefix matching is exact. The template guarantees this by using the one parameter in
  both places; do not "simplify" one side to a `/32`.
- **The route-table tag is load-bearing twice.** CFE discovers route tables by it, and
  IAM denies `ReplaceRoute` on a table without it. Do not make `routeTableFailoverTag`
  optional in this parent.
- **CFE next-hop addresses must be bare - no `/mask`.** The `failoverRoutes` next-hop
  list is matched against each device's own local addresses to decide which hop is
  "mine". `10.0.0.11/24` never matches `10.0.0.11`, so the device whose address carries
  the mask finds no next hop, performs **zero** route operations, and still reports
  `taskState: SUCCEEDED` / `Failover Complete` - a silent no-op that looks healthy in
  `inspect`. This is why the list uses the tag-sourced `OWN_SELF_IP_EXTERNAL` and not
  `SELF_IP_EXTERNAL`: the latter comes from AWS metadata with a mask because the DO
  `SelfIp` class requires one. Lab-observed 2026-09-08: it broke failover in one
  direction only, because the CFE declaration is config-synced, so both devices shared
  one list and only the device named by the masked entry failed to match.

- **Both instances must receive `cfeS3Bucket`.** Upstream `failover.yaml` passed it only to
  `BigIpInstance01`; `BigIpInstance02` fell back to the module default `''`, so its
  `cfeStorageName` tag rendered as `.s3.<region>.amazonaws.com` and CFE failed every state
  read with `getaddrinfo ENOTFOUND`. Config-sync eventually repairs the declaration from the
  peer, which is why this stayed hidden - but during onboarding, exactly when instance 02 may
  become active first, its CFE is dead. Lab-observed 2026-09-08: a fresh stack reached
  `CREATE_COMPLETE` with the VIP black-holed. Fixed in both parents; keep them symmetric.

- **Source/dest check** is disabled through the ENI resource, so it survives reboots and
  redeploys. Do not replace it with a post-deploy script.
- **Shared-module parameters must keep defaults that preserve existing behaviour.** The
  EIP-based `failover.yaml` must deploy unchanged with the patched modules.

## Converging later

The air-gap path has now proved out (see the validation record above), so the right
long-term shape is probably a mode parameter on `examples/failover/failover.yaml` rather
than two parents. The change set above is what that parameter would have to switch. The
main open question is whether the EIP-based and route-based paths can share one set of
runtime-init configs, or whether the CFE declaration differences (`failoverAddresses` vs
`failoverRoutes`, and the next-hop list) make two files the clearer option even inside a
merged parent.
