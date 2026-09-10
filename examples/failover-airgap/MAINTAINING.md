# Maintaining `examples/failover-airgap/`

This directory is a **variant** of `examples/failover/`, not an independent solution.
It exists so that the air-gap path (no Elastic IPs, route-based VIP failover) can be
built and validated without touching the working EIP-based path. The price of that is
duplication, and this file is what keeps the two from drifting.

## Validation record

| | |
|---|---|
| **Validated** | 2026-09-08 and again 2026-09-10 (first clean build with every fix active at once), `us-gov-east-1` |
| **Build** | 3-NIC PAYG, BIG-IP 17.5.1.6-0.0.25, DO 1.47.0, AS3 3.56.0, CFE 2.4.0 |
| **Default image now** | BIG-IP 17.5.1.9-0.0.12, Best Plus 25Mbps - one patch newer than validated, see note below |
| **Result** | Deployed end to end; VIP failover verified in **both** directions |
| **Convergence** | 6-10 s each way (in-VPC client, 0.5 s poll, last-good to first-good; runs: 9.58 s / ~6 s / 9.58 s) |
| **Defects found and fixed** | (1) Masked next-hop address broke failover in one direction - see "Rules that are easy to break" below. (2) `cfeS3Bucket` was never passed to `BigIpInstance02`, so its CFE could not reach the state store during onboarding - an upstream bug, also fixed in `examples/failover/failover.yaml`. (3) NAT gateways and two Elastic IPs were created in what was documented as a no-public-IP design, giving the private subnets internet egress - now `provisionNatGateways='false'`, with NTP moved to link-local. (4) `/LOCAL_ONLY` was assigned to the sync device group on the owner device, syncing a per-AZ default route to a peer that rejected it and leaving the cluster permanently `Sync Failed`. |

**2026-09-10 build** confirmed, in one deployment, every fix working together: runtime-init
installed from the staged `gpg.key`, DO applied with link-local NTP and DNS, device trust and
`failoverGroup` formed, config-sync `In Sync`, `/LOCAL_ONLY` excluded from the sync group, CFE
carrying bare next-hop addresses, the CFE state bucket named and reachable on both devices, and
the VIP following the active device in both directions. Two further defects were found and
fixed reaching it - see "Vendor installers" below for both.

Note that on a clean build `/LOCAL_ONLY` reports `device-group none` with `traffic-group none`;
only `device-group` matters. The self-heal sets `traffic-group-local-only` when it has to
correct the folder, so either value is healthy.

**Image version changed 2026-09-10, after the validation above.** `bigIpImage` now defaults to
`*17.5.1.9-0.0.12*PAYG-Best Plus 25Mbps*` - the same bundle and throughput as the validated
build, one patch newer.

BIG-IP 17.5.1.6 scopes the admin user created by Declarative Onboarding to the `Common`
partition. `tmsh` lists the AS3-created objects normally, because a root shell does not honour
partition access, but the GUI shows nothing under `Tenant_1` - so a working deployment looks
empty to anyone inspecting it through TMUI.

A larger jump to 21.1.0.2 was considered and rejected. The concern driving it was that 17.5.x
might no longer publish a `Best` PAYG bundle; a marketplace query disproved that - every 17.5.x
build offers `PAYG-Best Plus` at all throughputs. With that gone, a patch bump inside the
validated minor is the far smaller risk: the extension version and `extensionHash` pins, the
`cluster-heal.sh` workaround (which targets a 17.x device-trust bug) and the observed self-heal
timing all stay in known territory.

**Two things are still open on this pin:**

- **Whether 17.5.1.9 carries the partition-access fix is unconfirmed.** If the GUI symptom
  persists, the version-independent fix is `partitionAccess` on the DO User class - see the
  troubleshooting entry in the guide. That is arguably the correct declaration regardless, since
  an admin scoped to `Common` cannot see tenant partitions on any release. It is not applied by
  default only because an unsupported property would fail DO validation and cost a build cycle;
  verify it against the DO schema version in use before adding it.
- **17.5.1.9 has not been through the validation checklist.** Everything recorded above was
  measured on 17.5.1.6.

Re-run the [validation checklist](AIRGAP-GUIDE.md#6-validating-the-deployment) and both
failover directions after any change to the CFE declaration, the network module's route
table tagging, or the `externalSelfIp` / `peerExternalSelfIp` instance tags.

## What is shared, what is forked

| Component | Status | Notes |
|---|---|---|
| `modules/network/network.yaml` | **Shared** | Gains two optional parameters, both default-off: `routeTableFailoverTag` (tags every route table `f5_cloud_failover_label=<value>`; this template passes `cfeTag`) `provisionSsmEndpoints` (adds the `ssm`, `ssmmessages`, `ec2messages` interface endpoints), and `provisionNatGateways` (default `true` = historical behaviour; `false` removes the NAT gateways, their Elastic IPs and the `0.0.0.0/0` route from the private route tables, leaving the route tables themselves - and therefore the VPC endpoint associations and VIP routes - intact). The endpoint security group's condition widened to "S3 endpoints **or** SSM endpoints". With the defaults the module behaves exactly as before. |
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
  `provisionSsmEndpoints` from `provisionSsmAccess`, `routeTableFailoverTag=cfeTag`,
  `provisionNatGateways='false'` (no NAT gateways, no Elastic IPs, no egress).
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
4. NTP set to the Amazon Time Sync Service (`169.254.169.123`) instead of `pool.ntp.org`.
   With `provisionNatGateways='false'` there is no route to the internet, so public NTP
   would silently fail - and clock skew breaks device trust, config-sync and SigV4 request
   signing. DNS was already the link-local VPC resolver (`169.254.169.253`), so it needed
   no change.
5. A `Demo_Responder` iRule in `Shared`, attached to both services. It only acts when the
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

- **`/LOCAL_ONLY` must never belong to the sync device group.** It holds the default route,
  whose gateway is the device's own subnet gateway and therefore differs per AZ. Assigned to
  `failoverGroup`, that route syncs and the peer rejects it
  (`01070330:3: Static route gateway ... is not directly connected`), leaving the cluster
  permanently `Sync Failed` while failover itself keeps working - so it is easy to miss.
  Creating the device group out of band, which `cluster-heal.sh` must do, can leave the
  folder stamped with it; the script now corrects this on every device. Lab-observed
  2026-09-08 on the owner device only, its peer being correct - consistent with the group
  being created on the owner. The correct state is `device-group none` and
  `traffic-group traffic-group-local-only`. **Root cause confirmed 2026-09-09:** with the
  folder corrected on both devices, the only remaining occurrence of the offending gateway
  was `/config/partitions/LOCAL_ONLY/bigip.conf`, which is not syncable - and one
  `force-full-load-push` from the source device cleared the status to In Sync. Note that
  BIG-IP caches the last failure, so the status stays red until a successful load; fixing
  the folder alone looks like it changed nothing.

- **Nothing in the private subnets may need internet egress.** `provisionNatGateways='false'`
  removes the default route entirely. Everything the solution needs is reachable without it:
  S3 artifacts via the gateway endpoint, AWS APIs via interface endpoints, DNS and NTP via
  link-local addresses. Anything added later that expects egress - notably
  `provisionExampleApp='true'`, which pulls a container image - will fail. Re-enable NAT
  deliberately if that is required, and accept that it reintroduces two Elastic IPs.

- **Vendor installers have egress dependencies that reading our templates will not reveal.**
  Found the hard way on 2026-09-09, the first clean build after NAT was removed. Serving
  `f5-bigip-runtime-init-2.0.3-1.gz.run` from the bucket is not sufficient: `install_rpm.sh`
  *inside* the self-extracting archive independently fetches
  `https://f5-cft.s3.amazonaws.com/f5-bigip-runtime-init/gpg.key` to verify the RPM
  signature, and separately syncs an automation-toolchain metadata index. The GPG fetch is
  **fatal and retries indefinitely**; NAT had been silently covering for it. Symptom: BIG-IP
  prompt still reads `ip-10-0-1-11` (default hostname) after 20+ minutes, no
  `/var/log/f5-bigip-runtime-init.log`, admin password rejected, stack times out. The error
  is only in `/var/log/cloud/startup-script.log`.

  Handled by `bigIpRuntimeInitInstallerFlags` on `modules/bigip-standalone`, which the
  air-gap parent sets to `--skip-toolchain-metadata-sync --key <bucket>/gpg.key`. The
  parameter defaults to `''` and the flags are appended **unquoted** after the existing
  single-quoted argument, so an empty value expands to no argument at all and the userdata
  for every other example is byte-identical to before. Verified by rendering the `Fn::Join`
  for all three NIC variants with and without flags and diffing.

  To inspect the installer yourself: `bash <the>.gz.run --noexec --target /var/tmp/rti`
  extracts it without running it. Worth repeating whenever the pinned runtime-init version
  changes - a new release could add or move a bootstrap fetch.

- **Flags for the runtime-init installer must go INSIDE the single argument, not after it.**
  The invocation in `modules/bigip-standalone` userdata is:

  ```
  bash "...gz.run" -- "--cloud aws --telemetry-params ...${INSTALLER_FLAGS:+ ${INSTALLER_FLAGS}}"
  ```

  The first attempt appended the flags as separate shell words *after* the quoted argument.
  That renders correctly, passes `bash -n`, and does not work. Proven on a live instance:
  the userdata contained a correct `--key https://<bucket>/gpg.key` and `install_rpm.sh`
  still reported its default commercial-partition key location and looped on the
  unreachable fetch.

  The reason shows up in the argv shape. Appended outside the quotes the words land in
  `argv[3..5]`; makeself forwards the first argument after `--` to the embedded setup
  script, so nothing past `argv[2]` is ever seen. Every flag that does work today -
  `--cloud`, `--telemetry-params` - is inside that one argument.

  `${VAR:+ $VAR}` supplies the joining space only when the value is non-empty, so an empty
  value reproduces the original argument byte-for-byte and the other examples are
  unaffected.

  **The lesson generalises:** rendering the right text is not evidence that an argument is
  received. When adding a flag here, prove the argv shape rather than reading the line -
  a stub is enough:

  ```bash
  cat > /tmp/fakerun <<'EOF'
  #!/bin/bash
  i=0; for a in "$@"; do i=$((i+1)); printf 'argv[%d]=[%s]\n' "$i" "$a"; done
  EOF
  chmod +x /tmp/fakerun
  # then run the emitted command with /tmp/fakerun substituted for the .gz.run
  ```

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
