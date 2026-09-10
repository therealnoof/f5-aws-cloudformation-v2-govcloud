# Deploying the BIG-IP VE in AWS GovCloud - Air-gap Failover Cluster (route-based VIP)

## Contents

- [Introduction](#introduction)
- [What is different from `examples/failover`](#what-is-different-from-examplesfailover)
- [Prerequisites](#prerequisites)
- [Template Input Parameters](#template-input-parameters)
- [Template Outputs](#template-outputs)
- [Deploying this Solution](#deploying-this-solution)
- [Validation](#validation)
- [Deleting this Solution](#deleting-this-solution)
- [Maintaining](#maintaining)

## Introduction

This parent template deploys the same BIG-IP active/standby pair as
[`examples/failover`](../failover/README.md) - two 3-NIC PAYG BIG-IP VEs across two
Availability Zones, clustered with Declarative Onboarding and failed over with the
[F5 Cloud Failover Extension (CFE)](https://clouddocs.f5.com/products/extensions/f5-cloud-failover/latest/userguide/aws.html) -
with **no public IP address on any BIG-IP resource** and an application VIP that fails
over across AZs without an Elastic IP.

The VIP is an address **outside the VPC CIDR**. Each route table carries a route for the
VIP prefix that targets the active BIG-IP's external interface, and CFE retargets those
routes (`failoverRoutes`) when the active device changes. Every AWS API call the BIG-IPs
make is served by a VPC endpoint.

> ### ✅ Status: lab-validated
> Deployed and failover-tested end to end in `us-gov-east-1` on **2026-09-08** (3-NIC PAYG,
> BIG-IP 17.5.1.6-0.0.25, CFE 2.4.0). VIP failover was verified in **both** directions and
> converged in **6-10 seconds**, measured from an in-VPC client at a 0.5 s poll interval
> (individual runs: 9.58 s, ~6 s, 9.58 s). Run-to-run variance is real. Quote 10 seconds for
> headroom, and measure in your own environment before committing to an RTO.
>
> **➡️ New here? Start with [AIRGAP-GUIDE.md](AIRGAP-GUIDE.md)** - a complete step-by-step
> deployment walkthrough with architecture diagrams, Session Manager and GUI access, a
> validation checklist and troubleshooting. This README is the parameter and output
> reference.
> **Note the image change.** The default is now **BIG-IP 17.5.1.9-0.0.12, Best Plus 25Mbps** —
> the same bundle and throughput as the validated build, one patch newer. It was moved off
> 17.5.1.6 because a defect in that release scopes the admin user to the `Common` partition:
> `tmsh` lists the AS3-created application objects normally, but the GUI shows nothing under
> `Tenant_1`. **Whether 17.5.1.9 carries the fix is unconfirmed** — see the troubleshooting
> entry for the one-line check and the workaround that applies to any version.

## What is different from `examples/failover`

| | `examples/failover` | `examples/failover-airgap` |
|---|---|---|
| Elastic IPs | Up to 5 (management, external Self IPs, VIP) **plus 2 for NAT gateways** | **None at all** |
| Application VIP | Secondary private IP per AZ + one floating EIP | **One address outside the VPC CIDR** (`externalVipAddress`) |
| What CFE moves on failover | The EIP association (`failoverAddresses`) | **The target ENI of the VIP route** in every route table (`failoverRoutes`) |
| Source/dest check on external ENIs | Enabled (AWS default) | **Disabled** (required for an alien-IP VIP) |
| Route tables | Untagged | Tagged `f5_cloud_failover_label=cfeTag`, one VIP route each |
| VPC endpoints | Optional (`provisionS3Endpoint`) | **Always** (S3, EC2, Secrets Manager, CloudFormation), plus SSM, SSM Messages and EC2 Messages when `provisionSsmAccess=true` |
| Management access | Public EIP (eval) or bastion | **Session Manager** through a private jump host (`provisionSsmAccess`, default); public bastion only as a fallback (`provisionBastion`) |
| NAT gateways | 2 (one per AZ), each with an Elastic IP, giving the private subnets a `0.0.0.0/0` route to the internet | **None** (`provisionNatGateways='false'`). No default route out of the private subnets |
| DNS / NTP | VPC resolver / `pool.ntp.org` (needs egress) | VPC resolver / **Amazon Time Sync `169.254.169.123`** - both link-local, no egress |
| Public-IP toggles | 4 parameters | Removed - fixed to none |

**Demo responder.** With `provisionExampleApp=false` (the default) the VIP's pool has no
members, and an iRule in the AS3 declaration answers HTTP and HTTPS requests itself with
a page naming the BIG-IP that served it and the VIP it arrived on, refreshing every two
seconds. Open it in a browser, trigger a failover, and watch the device name change. With
a real back end deployed the rule steps aside and traffic is load balanced normally.

Why the EIP-based template cannot do this: a secondary private IP belongs to its subnet's
CIDR and cannot be reassigned to an ENI in another subnet. Across two AZs the only thing
`failoverAddresses` can move is an EIP association, so with no EIP there is nothing to
fail over. Route-based failover sidesteps addressing entirely.

## Prerequisites

An S3 bucket in the deployment Region holding the modules, this directory, the BIG-IP
extension RPMs, the runtime-init installer and its `gpg.key`, all readable by the BIG-IPs;
an SSH key pair; an admin-password secret; and a BIG-IP marketplace image available in the
Region.

> `gpg.key` is easy to miss and its absence is fatal. The runtime-init installer verifies
> its own RPM against a key it fetches from `f5-cft.s3.amazonaws.com` - a **commercial**
> partition bucket, unreachable from an air-gapped GovCloud VPC. This template therefore
> passes `--key <your bucket>/gpg.key` to the installer, so you must stage the key
> alongside the `.gz.run`. Without it the BIG-IPs never onboard, the admin password is
> never set, and the stack times out after ~50 minutes. See
> [AIRGAP-GUIDE.md section 4.4](AIRGAP-GUIDE.md#44-stage-the-s3-bucket).

**[AIRGAP-GUIDE.md sections 3 and 4](AIRGAP-GUIDE.md#3-before-you-start) walk through every
one of those with commands** - it is self-contained, so you do not need any other document
to get a working stack.

Points specific to this solution:

- **Choose the VIP prefix carefully.** `externalVipCidr` (default `10.99.0.0/24`) must not
  overlap the VPC CIDR or anything reachable from the VPC - including on-premises ranges
  arriving over Direct Connect, VPN or Transit Gateway.
- **Off-VPC clients need the prefix propagated.** The template routes the VIP prefix inside
  the VPC only. Clients on other networks need `externalVipCidr` routed into this VPC in
  *their* route tables (Transit Gateway route, VPN static route, and so on).
- **For Session Manager access**, the operator's workstation needs the AWS CLI with the
  [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  installed, and an IAM identity allowed `ssm:StartSession` on the jump instance and on
  the `AWS-StartPortForwardingSessionToRemoteHost` document. No key pair, no public IP
  and no inbound security group rule are involved.

## Template Input Parameters

The parameters are those of `failover.yaml` **minus** the public-IP toggles
(`provisionPublicIpMgmt`, `provisionPublicIpVip`, `provisionPublicIpExternalSelf`,
`provisionExternalVip`, `provisionS3Endpoint`, `bigIpExternalVip01/02`, `cfeVipTag`)
**plus**:

| Parameter | Required | Default | Description |
|---|---|---|---|
| `externalVipAddress` | No | `10.99.0.100` | The application VIP. Must be outside the VPC CIDR and inside `externalVipCidr`. Bound to the AS3 virtual servers on both devices. |
| `externalVipCidr` | No | `10.99.0.0/24` | Prefix routed to the active BIG-IP. One `AWS::EC2::Route` for exactly this prefix is created per route table, and the CFE declaration manages routes for exactly this prefix. |
| `provisionSsmAccess` | No | `true` | Deploy a private jump host managed by Systems Manager Session Manager (`modules/ssm-jump`) in the BIG-IP management subnet, plus the SSM interface endpoints. No public IP, no inbound rules, no SSH key. |
| `ssmJumpInstanceType` | No | `t3.micro` | Instance type for the jump host. It only terminates SSM sessions and forwards ports, so the smallest type in the Region is normally enough. |
| `ssmJumpCustomImageId` | No | `''` | AMI for the jump host, overriding the Amazon Linux 2023 lookup. Leave empty for the normal case. Set it if the AWS-published SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` is not available in your Region, or if a hardened base image is required. Any image works provided the SSM Agent is installed and starts at boot. |
| `bigIpRuntimeInitGpgKeyUrl` | No | `''` | **Leave blank.** Blank auto-derives `<s3BucketName>.s3.<s3BucketRegion>.amazonaws.com/<artifactLocation>gpg.key`. Set it only to serve the key from elsewhere. This is the GPG public key the runtime-init installer verifies its own RPM against - a separate download from the installer package that F5 hard-codes to a **commercial-partition** bucket, unreachable from an air-gapped GovCloud VPC and fatal when it fails. Either way `gpg.key` must be staged in the bucket and anonymously readable; `s3 sync` does not copy it. |
| `provisionBastion` | No | `false` | Fallback only: deploy the Linux bastion (`modules/bastion`) in the first external subnet **with a public IP** and SSH open to `restrictedSrcAddressMgmt`. |

> There is no parent parameter for the installer flags themselves. The parent assembles
> `--skip-toolchain-metadata-sync --key <the URL above>` and passes it to each BIG-IP as the
> `bigIpRuntimeInitInstallerFlags` parameter of `modules/bigip-standalone`. That module
> parameter defaults to `''`, so `examples/failover` and the other examples are unaffected.

See `failover-airgap-parameters.json` for a complete example parameter set.

## Template Outputs

| Output | Description |
|---|---|
| `vipAddress` | The application VIP (never public). |
| `vipRouteCidr` | The prefix CFE manages. |
| `vipRouteTableIds` | The route tables carrying the VIP route. |
| `bigIpExternalInterfaceId01` / `02` | External ENIs; `01` is the initial route target. |
| `bigIpInstanceMgmtPrivateIp01` / `02` | Management addresses (reach them through the jump host). |
| `ssmJumpInstanceId` | The Session Manager target. |
| `ssmPortForwardBigIp01` / `02` | Ready-to-paste `aws ssm start-session` commands that forward `localhost:8443` / `:8444` to each BIG-IP's management GUI. |
| `bastionPublicIp`, `bastionHostInstanceId` | Only when `provisionBastion=true`. |
| `cfeS3Bucket`, `bigIpSecretArn`, `bigIpKeyPairName`, `amiId` | As in `failover.yaml`. |

## Deploying this Solution

**For a full walkthrough - prerequisites, the Session Manager plugin, staging the bucket,
pre-flight checks, GUI access and validation - see
[AIRGAP-GUIDE.md](AIRGAP-GUIDE.md#4-step-by-step-deployment).** The condensed form follows.

Stage the bucket exactly as in the GovCloud guide, with this directory included. Note that
the air-gap solution also depends on the shared `modules/network`, `modules/bigip-standalone`
and `modules/ssm-jump` templates, so sync the whole `examples/` tree, not just this
directory:

```bash
aws s3 sync examples/ "s3://${BUCKET}/f5-aws-cloudformation-v2/v3.6.0.0/examples/" --region "${REGION}"
```

> Never add `--delete` - the runtime-init installer, its `gpg.key` and the three extension
> RPMs live only in the bucket, not in this repo, and would be removed.

Then:

```bash
aws cloudformation create-stack --region "${REGION}" \
  --stack-name failover-airgap \
  --template-url "https://${BUCKET}.s3.${REGION}.amazonaws.com/f5-aws-cloudformation-v2/v3.6.0.0/examples/failover-airgap/failover-airgap.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters file://examples/failover-airgap/failover-airgap-parameters.json
```

Set `s3BucketName`, `s3BucketRegion`, `sshKey`, `bigIpSecretArn`, `restrictedSrcAddressMgmt`
and `restrictedSrcAddressApp` in the parameters file first.

## Validation

[AIRGAP-GUIDE.md](AIRGAP-GUIDE.md#6-validating-the-deployment) has the full checklist. The
short form - paste the `ssmPortForwardBigIp01` output into a terminal, open
`https://localhost:8443`, then:

```bash
# CFE must list the VIP route - "routes" must NOT be empty.
# "addresses" being empty is correct: this design has no EIPs to move.
curl -sku admin:"${PW}" https://localhost:8443/mgmt/shared/cloud-failover/inspect | python3 -m json.tool

# Every next-hop item MUST be a bare address - a "/24" here breaks failover in one
# direction while still reporting success. See AIRGAP-GUIDE.md troubleshooting.
curl -sku admin:"${PW}" https://localhost:8443/mgmt/shared/cloud-failover/declare \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["declaration"]["failoverRoutes"]["routeGroupDefinitions"][0]["defaultNextHopAddresses"]["items"])'

# Then fail over from the ACTIVE device and watch the route target flip to the peer's ENI.
# Test BOTH directions - a fault can exist in only one.
tmsh run sys failover standby
```

> **Monitoring note.** CFE reports `taskState: SUCCEEDED` / `Failover Complete` even when
> it performs zero route operations, and `inspect` still looks healthy. Production health
> checks must compare the **actual route target** against the **actual active device**,
> not CFE's own status.

## Deleting this Solution

Empty the CFE state bucket first - CloudFormation cannot delete a bucket that still has
objects in it, and the delete fails partway if you skip this. The VIP routes are stack
resources and are removed with the stack even though CFE has changed their target.

```bash
CFEB=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='cfeS3Bucket'].OutputValue" --output text)
aws s3 rm "s3://$CFEB" --recursive
aws cloudformation delete-stack --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --stack-name "$STACK"
```

Full procedure, including what to check for stranded resources and what to do when the
delete fails, is in
[AIRGAP-GUIDE.md section 10](AIRGAP-GUIDE.md#10-tearing-the-stack-down).

## Maintaining

This directory is derived from `examples/failover`. [MAINTAINING.md](MAINTAINING.md) lists
what is shared, what is forked, and what must be mirrored when either side changes.
