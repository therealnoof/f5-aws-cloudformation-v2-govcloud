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

> **Status: scaffolded, not yet lab-validated.** The templates lint clean and follow the
> CFE documentation, but the route-based failover path has not been deployed end to end in
> GovCloud yet. Validate in both failover directions before this appears in a customer
> design. See [AIRGAP-GUIDE.md](AIRGAP-GUIDE.md) for the validation procedure.

## What is different from `examples/failover`

| | `examples/failover` | `examples/failover-airgap` |
|---|---|---|
| Elastic IPs | Up to 5 (management, external Self IPs, VIP) | **None** |
| Application VIP | Secondary private IP per AZ + one floating EIP | **One address outside the VPC CIDR** (`externalVipAddress`) |
| What CFE moves on failover | The EIP association (`failoverAddresses`) | **The target ENI of the VIP route** in every route table (`failoverRoutes`) |
| Source/dest check on external ENIs | Enabled (AWS default) | **Disabled** (required for an alien-IP VIP) |
| Route tables | Untagged | Tagged `f5_cloud_failover_label=cfeTag`, one VIP route each |
| VPC endpoints | Optional (`provisionS3Endpoint`) | **Always** (S3, EC2, Secrets Manager, CloudFormation), plus SSM, SSM Messages and EC2 Messages when `provisionSsmAccess=true` |
| Management access | Public EIP (eval) or bastion | **Session Manager** through a private jump host (`provisionSsmAccess`, default); public bastion only as a fallback (`provisionBastion`) |
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

Identical to the GovCloud prerequisites in
[`examples/failover/GOVCLOUD-GUIDE.md`](../failover/GOVCLOUD-GUIDE.md) sections 1-8: an S3
bucket in the deployment Region holding the modules, this directory, the BIG-IP extension
RPMs and the runtime-init installer, all readable by the BIG-IPs; an SSH key pair; an
admin-password secret; a BIG-IP marketplace image available in the Region.

In addition:

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
| `provisionBastion` | No | `false` | Fallback only: deploy the Linux bastion (`modules/bastion`) in the first external subnet **with a public IP** and SSH open to `restrictedSrcAddressMgmt`. |

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

Stage the bucket exactly as in the GovCloud guide, with this directory included:

```bash
aws s3 sync examples/ "s3://${BUCKET}/f5-aws-cloudformation-v2/v3.6.0.0/examples/" --region "${REGION}"
```

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

[AIRGAP-GUIDE.md](AIRGAP-GUIDE.md) has the full procedure. The short form: paste the
`ssmPortForwardBigIp01` output into a terminal, open `https://localhost:8443`, then on the
active device:

```bash
# CFE must list the VIP route - "routes" must NOT be empty
curl -sku admin:"${PW}" https://localhost/mgmt/shared/cloud-failover/inspect | python3 -m json.tool

# Fail over, then watch the route target flip to the peer's ENI
tmsh run sys failover standby
```

## Deleting this Solution

As for `examples/failover`: empty the CFE S3 bucket, then delete the stack. The VIP routes
are stack resources and are removed with it even though CFE has changed their target.

## Maintaining

This directory is derived from `examples/failover`. [MAINTAINING.md](MAINTAINING.md) lists
what is shared, what is forked, and what must be mirrored when either side changes.
